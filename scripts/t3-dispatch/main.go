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

// autoPair mints a one-time pairing token for the user's instance (as that OS
// user, via the scoped sudoers entry) and exchanges it at the instance's
// /api/auth/bootstrap, relaying the returned t3_session Set-Cookie to the browser.
func autoPair(e entry, w http.ResponseWriter, r *http.Request) {
	// t3-mint (root, via scoped sudoers) validates the OS user is in
	// /etc/ttyd-user-map, then mints as that user. The dispatch service itself
	// runs unprivileged and can invoke nothing else.
	out, err := exec.Command("sudo", "-n", "/usr/local/bin/t3-mint", e.OsUser).Output()
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
	body, _ := json.Marshal(map[string]string{"credential": pc.Credential})
	resp, err := http.Post(fmt.Sprintf("http://127.0.0.1:%d/api/auth/bootstrap", e.Port),
		"application/json", bytes.NewReader(body))
	if err != nil {
		http.Error(w, "bootstrap request failed", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		log.Printf("bootstrap for %s returned %d", e.OsUser, resp.StatusCode)
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
	e, ok := lookup(ak)
	if !ok {
		http.Error(w, "no t3 instance provisioned for this user", http.StatusForbidden)
		return
	}
	if _, err := r.Cookie(cookieName); err != nil {
		autoPair(e, w, r)
		return
	}
	// Steady state: reverse-proxy (incl. WebSocket upgrade) to the user's instance.
	target, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", e.Port))
	httputil.NewSingleHostReverseProxy(target).ServeHTTP(w, r)
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
	mux.HandleFunc("/", handler)
	log.Printf("t3-dispatch listening on %s", listenAddr)
	log.Fatal(http.ListenAndServe(listenAddr, mux))
}
