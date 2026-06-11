// t3-dispatch: per-user dispatch + auto-pair for t3code.
// Sits behind Traefik+Authentik (which injects X-authentik-username) and routes
// each authenticated user to their own `t3 serve` instance. On a user's first
// visit (no t3 session cookie) it mints a pairing token for that user's instance
// and exchanges it for the session cookie, which it injects into the browser —
// so an Authentik login lands straight in the user's workspace.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type entry struct {
	OsUser string `json:"os_user"`
	Port   int    `json:"port"`
}

const (
	cookieName   = "t3_session" // discovered: apps/server/src/auth/utils.ts (web mode)
	listenAddr   = ":3780"
	dispatchFile = "/etc/t3-serve/dispatch.json"
)

var (
	mu    sync.RWMutex
	table map[string]entry
)

func loadTable() error {
	b, err := os.ReadFile(dispatchFile)
	if err != nil {
		return err
	}
	m := map[string]entry{}
	if err := json.Unmarshal(b, &m); err != nil {
		return err
	}
	mu.Lock()
	table = m
	mu.Unlock()
	return nil
}

func lookup(ak string) (entry, bool) {
	mu.RLock()
	defer mu.RUnlock()
	e, ok := table[ak]
	return e, ok
}

// mintToken mints a one-time pairing token for osUser via the scoped sudoers
// entry (the dispatch service can invoke nothing else). Indirected through a var
// so tests can stub the privileged exec.
var mintToken = func(osUser string) ([]byte, error) {
	return exec.Command("sudo", "-n", "/usr/local/bin/t3-mint", osUser).Output()
}

var sessionClient = &http.Client{Timeout: 5 * time.Second}

// sessionValid asks the user's instance whether the presented t3_session cookie
// is still valid. Server-side sessions can be wiped/expired independently of the
// 30-day cookie (e.g. an auth-schema rollback drops every session row), leaving
// the browser with a live-looking but dead cookie. Fails OPEN: any error/non-200/
// parse failure returns true so the request still proxies — a re-pair is forced
// only on a definitive authenticated:false.
func sessionValid(e entry, c *http.Cookie) bool {
	req, err := http.NewRequest(http.MethodGet,
		fmt.Sprintf("http://127.0.0.1:%d/api/auth/session", e.Port), nil)
	if err != nil {
		return true
	}
	req.AddCookie(c)
	resp, err := sessionClient.Do(req)
	if err != nil {
		return true
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return true
	}
	var s struct {
		Authenticated bool `json:"authenticated"`
	}
	if json.NewDecoder(resp.Body).Decode(&s) != nil {
		return true
	}
	return s.Authenticated
}

// isDocumentNav reports whether r is a top-level browser document navigation, as
// opposed to an XHR/fetch/asset/WebSocket sub-request. Only such requests are
// safe to answer with a re-pair 302 — redirecting a sub-resource would corrupt
// the SPA's fetch/WebSocket contract. Trust Sec-Fetch-Dest when present (all
// modern browsers send it); fall back to the Accept header otherwise.
func isDocumentNav(r *http.Request) bool {
	if r.Method != http.MethodGet {
		return false
	}
	if dest := r.Header.Get("Sec-Fetch-Dest"); dest != "" {
		return dest == "document"
	}
	return strings.Contains(r.Header.Get("Accept"), "text/html")
}

// pairEndpoints are the instance's session-bootstrap paths in preference order.
// t3 renamed /api/auth/bootstrap -> /api/auth/browser-session in 0.0.25; trying the
// new name first and falling back to the old lets ONE dispatch binary pair against
// either version — so the t3 pin can move forward (and survive a rolling-restart
// skew where some instances are already on the new version) without a 502 storm.
var pairEndpoints = []string{"/api/auth/browser-session", "/api/auth/bootstrap"}

// exchangeCredential POSTs the pairing credential to the user's instance, trying
// each pairEndpoint in turn. A 404 means "absent in this t3 version" -> try the
// next; any other status is that endpoint's verdict, returned as-is. Caller owns
// resp.Body.
func exchangeCredential(port int, credential string) (*http.Response, error) {
	body, _ := json.Marshal(map[string]string{"credential": credential})
	var lastErr error
	for _, ep := range pairEndpoints {
		resp, err := http.Post(fmt.Sprintf("http://127.0.0.1:%d%s", port, ep),
			"application/json", bytes.NewReader(body))
		if err != nil {
			lastErr = err
			continue
		}
		if resp.StatusCode == http.StatusNotFound {
			resp.Body.Close() // endpoint absent in this t3 version — try the next
			continue
		}
		return resp, nil
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return nil, fmt.Errorf("no pairing endpoint accepted the request (all returned 404)")
}

// autoPair mints a one-time pairing token for the user's instance (as that OS
// user, via the scoped sudoers entry) and exchanges it at the instance's pairing
// endpoint, relaying the returned t3_session Set-Cookie to the browser.
func autoPair(e entry, w http.ResponseWriter, r *http.Request) {
	// t3-mint (root, via scoped sudoers) validates the OS user is in
	// /etc/ttyd-user-map, then mints as that user. The dispatch service itself
	// runs unprivileged and can invoke nothing else.
	out, err := mintToken(e.OsUser)
	if err != nil {
		log.Printf("mint for %s failed: %v", e.OsUser, err)
		http.Error(w, "pairing mint failed", http.StatusInternalServerError)
		return
	}
	var pc struct {
		Credential string `json:"credential"` // CLI returns the token under "credential"
	}
	if err := json.Unmarshal(out, &pc); err != nil || pc.Credential == "" {
		http.Error(w, "unparseable pairing output", http.StatusInternalServerError)
		return
	}
	resp, err := exchangeCredential(e.Port, pc.Credential)
	if err != nil {
		log.Printf("pairing exchange for %s failed: %v", e.OsUser, err)
		http.Error(w, "bootstrap request failed", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		log.Printf("pairing for %s returned %d", e.OsUser, resp.StatusCode)
		http.Error(w, "bootstrap rejected", http.StatusBadGateway)
		return
	}
	for _, c := range resp.Cookies() {
		http.SetCookie(w, c) // relays t3_session (HttpOnly; Path=/; SameSite=Lax)
	}
	http.Redirect(w, r, "/", http.StatusFound)
}

func handler(w http.ResponseWriter, r *http.Request) {
	ak := r.Header.Get("X-authentik-username")
	// Authentik injects the full email (e.g. vbarzin@gmail.com); /etc/ttyd-user-map
	// (and thus dispatch.json) keys on the local part. Strip @domain, matching the
	// terminal stack's tmux-attach.sh (`${auth_user%%@*}`).
	if i := strings.IndexByte(ak, '@'); i >= 0 {
		ak = ak[:i]
	}
	e, ok := lookup(ak)
	if !ok {
		http.Error(w, "no t3 instance provisioned for this user", http.StatusForbidden)
		return
	}
	c, err := r.Cookie(cookieName)
	if err != nil {
		autoPair(e, w, r)
		return
	}
	// A present cookie can still be server-side-invalid (sessions wiped/expired
	// while the 30-day cookie lingers). On a top-level navigation, verify it and
	// re-pair if dead — otherwise the instance just renders its pair page. Gated
	// to document navs so we never 302 an XHR/asset/WebSocket sub-request.
	if isDocumentNav(r) && !sessionValid(e, c) {
		autoPair(e, w, r)
		return
	}
	// Steady state: reverse-proxy (incl. WebSocket upgrade) to the user's instance.
	target, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", e.Port))
	proxy := httputil.NewSingleHostReverseProxy(target)

	// WebSocket connection logging: t3 drops manifest as the client's 20s
	// heartbeat watchdog reconnecting, so a flood of short-lived /ws connections
	// IS the symptom. Log each WS open + close (duration + which side hung up) so
	// a drop is attributable from logs alone — graceful closes otherwise leave no
	// trace (the default ReverseProxy only logs on error). cause stays "graceful"
	// unless ErrorHandler fires; ErrorHandler runs within ServeHTTP, so reading
	// cause after ServeHTTP returns needs no synchronisation.
	if isWebSocket(r) {
		start := time.Now()
		ip := clientIP(r)
		cause := "graceful"
		proxy.ErrorHandler = func(rw http.ResponseWriter, _ *http.Request, err error) {
			cause = classifyClose(err)
		}
		log.Printf("ws open user=%s ip=%s", e.OsUser, ip)
		proxy.ServeHTTP(w, r)
		log.Printf("ws close user=%s ip=%s dur_ms=%d cause=%s",
			e.OsUser, ip, time.Since(start).Milliseconds(), cause)
		return
	}
	proxy.ServeHTTP(w, r)
}

// isWebSocket reports whether r is a WebSocket upgrade request.
func isWebSocket(r *http.Request) bool {
	return strings.EqualFold(r.Header.Get("Upgrade"), "websocket") &&
		strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade")
}

// clientIP returns the forwarded client chain (X-Forwarded-For, set by
// Traefik/CF) when present, else the immediate peer — for correlating a drop
// to a specific client/edge.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		return xff
	}
	return r.RemoteAddr
}

// classifyClose maps a reverse-proxy copy error to which side ended the socket:
// downstream (client/CF/Traefik went away) vs upstream (the user's t3 serve
// closed/reset). Distinguishes a last-mile/client drop from a t3-serve stall.
func classifyClose(err error) string {
	if err == nil {
		return "graceful"
	}
	s := err.Error()
	switch {
	case strings.Contains(s, "context canceled"):
		return "downstream_closed" // client / CF / Traefik tore down
	case strings.Contains(s, "reset by peer"), strings.Contains(s, "broken pipe"),
		strings.Contains(s, "EOF"), strings.Contains(s, "connection refused"):
		return "upstream_closed" // t3 serve closed / unreachable
	default:
		return s
	}
}

func main() {
	if err := loadTable(); err != nil {
		log.Fatalf("load %s: %v", dispatchFile, err)
	}
	go func() {
		for range time.Tick(60 * time.Second) {
			if err := loadTable(); err != nil {
				log.Printf("reload %s: %v", dispatchFile, err)
			}
		}
	}()
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	registerProbe(mux)
	mux.HandleFunc("/", handler)
	log.Printf("t3-dispatch listening on %s", listenAddr)
	log.Fatal(http.ListenAndServe(listenAddr, mux))
}
