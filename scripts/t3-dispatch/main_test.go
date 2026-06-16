package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
)

func portOf(t *testing.T, ts *httptest.Server) int {
	t.Helper()
	u, err := url.Parse(ts.URL)
	if err != nil {
		t.Fatalf("parse %s: %v", ts.URL, err)
	}
	p, err := strconv.Atoi(u.Port())
	if err != nil {
		t.Fatalf("port %s: %v", u.Port(), err)
	}
	return p
}

func TestIsDocumentNav(t *testing.T) {
	cases := []struct {
		name    string
		method  string
		headers map[string]string
		want    bool
	}{
		{"GET sec-fetch-dest document", "GET", map[string]string{"Sec-Fetch-Dest": "document"}, true},
		{"GET accept html (no sec-fetch)", "GET", map[string]string{"Accept": "text/html,application/xhtml+xml"}, true},
		{"GET xhr empty dest beats accept", "GET", map[string]string{"Sec-Fetch-Dest": "empty", "Accept": "text/html"}, false},
		{"GET json", "GET", map[string]string{"Accept": "application/json"}, false},
		{"POST html", "POST", map[string]string{"Accept": "text/html"}, false},
		{"GET no headers", "GET", map[string]string{}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r, _ := http.NewRequest(c.method, "/", nil)
			for k, v := range c.headers {
				r.Header.Set(k, v)
			}
			if got := isDocumentNav(r); got != c.want {
				t.Errorf("isDocumentNav = %v, want %v", got, c.want)
			}
		})
	}
}

func sessionServer(status int, body string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/auth/session" {
			http.NotFound(w, r)
			return
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
}

func TestSessionValid(t *testing.T) {
	ck := &http.Cookie{Name: cookieName, Value: "x"}

	t.Run("authenticated true -> valid", func(t *testing.T) {
		ts := sessionServer(200, `{"authenticated":true}`)
		defer ts.Close()
		if !sessionValid(entry{Port: portOf(t, ts)}, ck) {
			t.Fatal("want valid (true) for authenticated:true")
		}
	})
	t.Run("authenticated false -> invalid", func(t *testing.T) {
		ts := sessionServer(200, `{"authenticated":false}`)
		defer ts.Close()
		if sessionValid(entry{Port: portOf(t, ts)}, ck) {
			t.Fatal("want invalid (false) for authenticated:false")
		}
	})
	t.Run("500 -> fail-open valid", func(t *testing.T) {
		ts := sessionServer(500, `boom`)
		defer ts.Close()
		if !sessionValid(entry{Port: portOf(t, ts)}, ck) {
			t.Fatal("want fail-open true on 500")
		}
	})
	t.Run("malformed json -> fail-open valid", func(t *testing.T) {
		ts := sessionServer(200, `not json`)
		defer ts.Close()
		if !sessionValid(entry{Port: portOf(t, ts)}, ck) {
			t.Fatal("want fail-open true on unparseable body")
		}
	})
	t.Run("unreachable -> fail-open valid", func(t *testing.T) {
		ts := sessionServer(200, `{"authenticated":false}`)
		p := portOf(t, ts)
		ts.Close() // nothing listening now
		if !sessionValid(entry{Port: p}, ck) {
			t.Fatal("want fail-open true on connection refused")
		}
	})
}

// fakeInstance serves the three endpoints the dispatcher touches: the session
// check, the bootstrap exchange, and a catch-all standing in for the proxied app.
func fakeInstance(authenticated bool, bootstrapCalled *bool) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/auth/session":
			if authenticated {
				_, _ = w.Write([]byte(`{"authenticated":true}`))
			} else {
				_, _ = w.Write([]byte(`{"authenticated":false}`))
			}
		case "/api/auth/bootstrap":
			if bootstrapCalled != nil {
				*bootstrapCalled = true
			}
			http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "fresh", Path: "/"})
			_, _ = w.Write([]byte(`{"authenticated":true}`))
		case "/api/auth/browser-session":
			http.NotFound(w, r) // models a 0.0.24 instance: the 0.0.25 endpoint is absent
		default:
			_, _ = w.Write([]byte("APP"))
		}
	}))
}

func setTable(port int) {
	mu.Lock()
	table = map[string]entry{"vbarzin": {OsUser: "wizard", Port: port}}
	mu.Unlock()
}

func TestHandlerRepairsOnInvalidCookieDocNav(t *testing.T) {
	called := false
	ts := fakeInstance(false, &called)
	defer ts.Close()
	setTable(portOf(t, ts))

	orig := mintToken
	mintToken = func(string) ([]byte, error) { return []byte(`{"credential":"tok"}`), nil }
	defer func() { mintToken = orig }()

	r := httptest.NewRequest("GET", "/", nil)
	r.Header.Set("X-authentik-username", "vbarzin@gmail.com")
	r.Header.Set("Sec-Fetch-Dest", "document")
	r.AddCookie(&http.Cookie{Name: cookieName, Value: "stale"})
	w := httptest.NewRecorder()

	handler(w, r)

	if w.Code != http.StatusFound {
		t.Fatalf("stale cookie on doc-nav should re-pair (302), got %d body=%q", w.Code, w.Body.String())
	}
	if !called {
		t.Fatal("expected bootstrap to be called during re-pair")
	}
	cookies := w.Result().Cookies()
	if len(cookies) == 0 || cookies[0].Value != "fresh" {
		t.Fatalf("expected fresh t3_session relayed, got %+v", cookies)
	}
}

func TestHandlerProxiesOnValidCookie(t *testing.T) {
	ts := fakeInstance(true, nil)
	defer ts.Close()
	setTable(portOf(t, ts))

	r := httptest.NewRequest("GET", "/", nil)
	r.Header.Set("X-authentik-username", "vbarzin@gmail.com")
	r.Header.Set("Sec-Fetch-Dest", "document")
	r.AddCookie(&http.Cookie{Name: cookieName, Value: "good"})
	w := httptest.NewRecorder()

	handler(w, r)

	if w.Code != http.StatusOK || w.Body.String() != "APP" {
		t.Fatalf("valid cookie should proxy (200 APP), got %d %q", w.Code, w.Body.String())
	}
}

func TestHandlerProxiesXHREvenIfCookieInvalid(t *testing.T) {
	called := false
	ts := fakeInstance(false, &called) // session would say invalid, but XHR must NOT be re-paired
	defer ts.Close()
	setTable(portOf(t, ts))

	r := httptest.NewRequest("GET", "/api/threads", nil)
	r.Header.Set("X-authentik-username", "vbarzin@gmail.com")
	r.Header.Set("Sec-Fetch-Dest", "empty") // XHR/fetch, not a document nav
	r.AddCookie(&http.Cookie{Name: cookieName, Value: "stale"})
	w := httptest.NewRecorder()

	handler(w, r)

	if called {
		t.Fatal("must NOT re-pair (302) a non-document sub-request — would corrupt the SPA fetch contract")
	}
	if w.Code != http.StatusOK || w.Body.String() != "APP" {
		t.Fatalf("XHR should proxy through, got %d %q", w.Code, w.Body.String())
	}
}

// pairInstance simulates a t3 instance that exposes pairing at exactly one path
// (200 + t3_session) and 404s the other known path — modeling the 0.0.25 rename of
// /api/auth/bootstrap -> /api/auth/browser-session. records which path was hit.
func pairInstance(pairPath string, hit *string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/auth/browser-session", "/api/auth/bootstrap":
			if r.URL.Path != pairPath {
				http.NotFound(w, r) // endpoint absent in this t3 version
				return
			}
			if hit != nil {
				*hit = r.URL.Path
			}
			http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "fresh", Path: "/"})
			_, _ = w.Write([]byte(`{"authenticated":true}`))
		default:
			http.NotFound(w, r)
		}
	}))
}

// TestAutoPairAcrossVersions: one dispatch binary must pair against BOTH the
// 0.0.24 endpoint (/api/auth/bootstrap) and the 0.0.25 one (/api/auth/browser-session),
// so the pin can move forward (and survive rolling-restart skew) without a 502 storm.
func TestAutoPairAcrossVersions(t *testing.T) {
	orig := mintToken
	mintToken = func(string) ([]byte, error) { return []byte(`{"credential":"tok"}`), nil }
	defer func() { mintToken = orig }()

	for _, tc := range []struct{ name, pairPath string }{
		{"0.0.25 browser-session", "/api/auth/browser-session"},
		{"0.0.24 bootstrap", "/api/auth/bootstrap"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var hit string
			ts := pairInstance(tc.pairPath, &hit)
			defer ts.Close()
			setTable(portOf(t, ts))

			r := httptest.NewRequest("GET", "/", nil)
			r.Header.Set("X-authentik-username", "vbarzin@gmail.com") // no cookie -> autoPair
			w := httptest.NewRecorder()
			handler(w, r)

			if w.Code != http.StatusFound {
				t.Fatalf("want 302 re-pair, got %d body=%q", w.Code, w.Body.String())
			}
			if hit != tc.pairPath {
				t.Fatalf("want pairing via %s, hit=%q", tc.pairPath, hit)
			}
			if cs := w.Result().Cookies(); len(cs) == 0 || cs[0].Value != "fresh" {
				t.Fatalf("want fresh t3_session relayed, got %+v", cs)
			}
		})
	}
}

// TestExchangeCredentialReportsEndpoint: exchangeCredential must report WHICH
// pairing endpoint accepted the credential, so the dispatch can log it and we
// can alert on the browser-session -> bootstrap fallback rate (a non-zero rate
// means the running t3 build moved/renamed the pairing API — contract drift, the
// 2026-06-09 failure class). fallback = endpoint is not the first-preference one.
func TestExchangeCredentialReportsEndpoint(t *testing.T) {
	for _, tc := range []struct {
		name, pairPath, wantEP string
		wantFallback           bool
	}{
		{"0.0.25 browser-session (primary)", "/api/auth/browser-session", "/api/auth/browser-session", false},
		{"0.0.24 bootstrap (fallback)", "/api/auth/bootstrap", "/api/auth/bootstrap", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var hit string
			ts := pairInstance(tc.pairPath, &hit)
			defer ts.Close()

			resp, ep, err := exchangeCredential(portOf(t, ts), "tok")
			if err != nil {
				t.Fatalf("exchangeCredential: %v", err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				t.Fatalf("status = %d, want 200", resp.StatusCode)
			}
			if ep != tc.wantEP {
				t.Fatalf("endpoint = %q, want %q", ep, tc.wantEP)
			}
			if gotFallback := ep != pairEndpoints[0]; gotFallback != tc.wantFallback {
				t.Fatalf("fallback = %v, want %v", gotFallback, tc.wantFallback)
			}
		})
	}
}

func TestProbeHealthz(t *testing.T) {
	mux := http.NewServeMux()
	registerProbe(mux)
	ts := httptest.NewServer(mux)
	defer ts.Close()
	resp, err := http.Get(ts.URL + "/probe/healthz")
	if err != nil {
		t.Fatalf("GET /probe/healthz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
}

func TestProbeWSEcho(t *testing.T) {
	mux := http.NewServeMux()
	registerProbe(mux)
	ts := httptest.NewServer(mux)
	defer ts.Close()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/probe/ws"
	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", wsURL, err)
	}
	defer c.Close()
	for _, msg := range []string{"ping 1718000000", "ping 1718000010"} {
		if err := c.WriteMessage(websocket.TextMessage, []byte(msg)); err != nil {
			t.Fatalf("write: %v", err)
		}
		_, got, err := c.ReadMessage()
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		if string(got) != msg {
			t.Errorf("echo = %q, want %q", got, msg)
		}
	}
}

func TestIsWebSocket(t *testing.T) {
	cases := []struct {
		up, conn string
		want     bool
	}{
		{"websocket", "Upgrade", true},
		{"websocket", "keep-alive, Upgrade", true},
		{"WebSocket", "upgrade", true},
		{"", "keep-alive", false},
		{"h2c", "Upgrade", false},
		{"websocket", "keep-alive", false},
	}
	for _, c := range cases {
		r, _ := http.NewRequest("GET", "/ws", nil)
		if c.up != "" {
			r.Header.Set("Upgrade", c.up)
		}
		r.Header.Set("Connection", c.conn)
		if got := isWebSocket(r); got != c.want {
			t.Errorf("isWebSocket(up=%q conn=%q)=%v want %v", c.up, c.conn, got, c.want)
		}
	}
}

func TestClassifyClose(t *testing.T) {
	cases := []struct {
		in   error
		want string
	}{
		{nil, "graceful"},
		{errTest("context canceled"), "downstream_closed"},
		{errTest("read tcp 127.0.0.1:60664->127.0.0.1:3773: read: connection reset by peer"), "upstream_closed"},
		{errTest("write: broken pipe"), "upstream_closed"},
		{errTest("unexpected EOF"), "upstream_closed"},
		{errTest("dial tcp 127.0.0.1:3773: connect: connection refused"), "upstream_closed"},
		{errTest("some novel error"), "some novel error"},
	}
	for _, c := range cases {
		if got := classifyClose(c.in); got != c.want {
			t.Errorf("classifyClose(%v)=%q want %q", c.in, got, c.want)
		}
	}
}

type errTest string

func (e errTest) Error() string { return string(e) }

func TestClientIP(t *testing.T) {
	r, _ := http.NewRequest("GET", "/ws", nil)
	r.RemoteAddr = "10.0.0.5:1234"
	if got := clientIP(r); got != "10.0.0.5:1234" {
		t.Errorf("clientIP no-xff = %q", got)
	}
	r.Header.Set("X-Forwarded-For", "1.2.3.4, 10.10.1.1")
	if got := clientIP(r); got != "1.2.3.4, 10.10.1.1" {
		t.Errorf("clientIP xff = %q", got)
	}
}
