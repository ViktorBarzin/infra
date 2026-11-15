package analytics_inject_plugin

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const wantIDTag = `<script src="/_t/id.js" defer></script>`

func identifyInjectCfg() *Config {
	c := defaultCfg()
	c.IdentifySrc = "/_t/id.js"
	c.IdentifyCookie = "authentik_proxy_abc"
	return c
}

func serveHTML(t *testing.T, cfg *Config, req *http.Request) string {
	t.Helper()
	page := []byte("<html><head><title>x</title></head><body></body></html>")
	h := newPlugin(t, cfg, backend(200, map[string]string{"Content-Type": "text/html"}, page))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Body.String()
}

func TestIdentifyTagNeedsTheSessionCookie(t *testing.T) {
	cases := []struct {
		name   string
		cookie *http.Cookie
		want   string
	}{
		{"session cookie present", &http.Cookie{Name: "authentik_proxy_abc", Value: "v"}, wantIDTag + wantTag + "</head>"},
		{"no cookie", nil, "<title>x</title>" + wantTag + "</head>"},
		{"another proxy cookie", &http.Cookie{Name: "authentik_proxy_other", Value: "v"}, "<title>x</title>" + wantTag + "</head>"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := htmlNav("GET")
			if tc.cookie != nil {
				req.AddCookie(tc.cookie)
			}
			got := serveHTML(t, identifyInjectCfg(), req)
			if !strings.Contains(got, tc.want) {
				t.Fatalf("body %q does not contain %q", got, tc.want)
			}
			if tc.cookie == nil || tc.cookie.Name != "authentik_proxy_abc" {
				if strings.Contains(got, "/_t/id.js") {
					t.Fatalf("identify tag injected without the session cookie: %q", got)
				}
			}
		})
	}
}

func TestIdentifyTagOffByDefault(t *testing.T) {
	req := htmlNav("GET")
	req.AddCookie(&http.Cookie{Name: "authentik_proxy_abc", Value: "v"})
	if got := serveHTML(t, defaultCfg(), req); strings.Contains(got, "id.js") {
		t.Fatalf("identify tag injected with no identify config: %q", got)
	}
}

func identifyModeCfg() *Config {
	c := CreateConfig()
	c.Mode = "identify"
	return c
}

func TestIdentifyMode(t *testing.T) {
	uid := "5e9a0647161c18dc66dbbb3d9a876eced545f27cca7a24e8cf54c11beaaf6480"
	cases := []struct {
		name    string
		method  string
		uid     string
		status  int
		wantSet bool
	}{
		{"signed in", "GET", uid, 200, true},
		{"HEAD", "HEAD", uid, 200, false},
		{"no user header (break-glass fallback)", "GET", "", 200, false},
		{"unsafe characters", "GET", `x");alert(1);//`, 200, false},
		{"too long", "GET", strings.Repeat("a", 129), 200, false},
		{"POST", "POST", uid, http.StatusMethodNotAllowed, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			called := false
			next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true })
			h := newPlugin(t, identifyModeCfg(), next)
			req := httptest.NewRequest(tc.method, "http://app.example/_t/id.js", nil)
			if tc.uid != "" {
				req.Header.Set("X-Authentik-Uid", tc.uid)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			res := rec.Result()
			body, _ := io.ReadAll(res.Body)
			if called {
				t.Fatal("identify mode passed the request to the backend")
			}
			if res.StatusCode != tc.status {
				t.Fatalf("status %d, want %d", res.StatusCode, tc.status)
			}
			if tc.status != 200 {
				return
			}
			if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/javascript") {
				t.Fatalf("Content-Type %q", ct)
			}
			if cc := res.Header.Get("Cache-Control"); cc != "no-store, private" {
				t.Fatalf("Cache-Control %q", cc)
			}
			if res.Header.Get("X-Content-Type-Options") != "nosniff" {
				t.Fatal("missing nosniff")
			}
			want := `localStorage.setItem("rybbit-user-id","` + uid + `")`
			if got := strings.Contains(string(body), want); got != tc.wantSet {
				t.Fatalf("body %q: contains setItem = %v, want %v", body, got, tc.wantSet)
			}
			if !tc.wantSet && strings.Contains(string(body), "setItem") {
				t.Fatalf("body %q sets an id", body)
			}
		})
	}
}

func TestIdentifyConfig(t *testing.T) {
	next := http.NotFoundHandler()
	bad := []struct {
		name string
		cfg  func() *Config
	}{
		{"identifySrc without identifyCookie", func() *Config { c := defaultCfg(); c.IdentifySrc = "/_t/id.js"; return c }},
		{"identifyCookie without identifySrc", func() *Config { c := defaultCfg(); c.IdentifyCookie = "a"; return c }},
		{"relative identifySrc", func() *Config { c := identifyInjectCfg(); c.IdentifySrc = "id.js"; return c }},
		{"protocol-relative identifySrc", func() *Config { c := identifyInjectCfg(); c.IdentifySrc = "//evil.example/id.js"; return c }},
		{"unknown mode", func() *Config { c := defaultCfg(); c.Mode = "other"; return c }},
		{"bad storage key", func() *Config { c := identifyModeCfg(); c.IdentifyStorageKey = `a"b`; return c }},
	}
	for _, tc := range bad {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := New(nil, next, tc.cfg(), "test"); err == nil {
				t.Fatal("New accepted the config")
			}
		})
	}
	if _, err := New(nil, next, identifyModeCfg(), "test"); err != nil {
		t.Fatalf("identify mode without siteId: %v", err)
	}
}
