package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func startTestImpersonation(t *testing.T, fa *fakeAuthentik, srvURL, target string) *impersonation {
	t.Helper()
	im, err := startImpersonation(impersonationConfig{
		BaseURL: srvURL, Creds: testCreds(), Target: target, Reason: "r",
		Now: fixedNow, Sleep: func(time.Duration) {},
	})
	if err != nil {
		t.Fatal(err)
	}
	return im
}

func TestSavedSessionRoundTripAndEnd(t *testing.T) {
	fa := newFakeAuthentik("pw", "287082")
	srv := httptest.NewServer(fa)
	defer srv.Close()
	dir := filepath.Join(t.TempDir(), "impersonation")

	im := startTestImpersonation(t, fa, srv.URL, "alice@example.com")
	path, err := saveSession(dir, im, "alice@example.com")
	if err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("session file %v mode %v, want 0600", err, fi.Mode().Perm())
	}
	if fi, err := os.Stat(dir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("session dir mode %v, want 0700", fi.Mode().Perm())
	}

	got, err := findSessions(dir, "alice@example.com")
	if err != nil || len(got) != 1 {
		t.Fatalf("find by requested name: %v %v", got, err)
	}
	if got, _ := findSessions(dir, ""); len(got) != 1 {
		t.Fatalf("find all: %v", got)
	}
	if got, _ := findSessions(dir, "bob"); len(got) != 0 {
		t.Fatalf("find bob: %v", got)
	}

	loaded, err := loadSession(got[0])
	if err != nil {
		t.Fatal(err)
	}
	if loaded.TargetUsername != "alice@example.com" || loaded.TargetPK != 7 {
		t.Fatalf("loaded %q %d", loaded.TargetUsername, loaded.TargetPK)
	}
	if err := loaded.End(); err != nil {
		t.Fatal(err)
	}
	if len(fa.user) != 0 {
		t.Fatalf("still signed in after End of the loaded session: %v", fa.user)
	}
}

func TestPlaywrightSnippetClearsOurCookiesThenAdds(t *testing.T) {
	cookies := []pwCookie{{Name: "authentik_session", Value: "abc", Domain: "authentik.viktorbarzin.me", Path: "/", Expires: -1, HTTPOnly: true, Secure: true, SameSite: "Lax"}}
	s := playwrightSnippet("https://authentik.viktorbarzin.me", cookies, "alice", "svc-agent")
	for _, want := range []string{
		"async (page) =>",
		`clearCookies({ domain: /(^|\.)viktorbarzin\.me$/ })`,
		`addCookies([{"name":"authentik_session","value":"abc"`,
		`"https://authentik.viktorbarzin.me/api/v3/core/users/me/"`,
		`"alice"`, `"svc-agent"`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("snippet lacks %s:\n%s", want, s)
		}
	}
	if strings.Index(s, "clearCookies") > strings.Index(s, "addCookies") {
		t.Error("clearCookies must run before addCookies")
	}
}

func TestT3SnippetSetsDocumentCookies(t *testing.T) {
	cookies := []pwCookie{
		{Name: "authentik_session", Value: "abc", Secure: true},
		{Name: "authentik_csrf", Value: `q"x`, Secure: true},
	}
	s := t3Snippet("https://authentik.viktorbarzin.me", cookies, "alice", "svc-agent")
	for _, want := range []string{
		`location.origin !== "https://authentik.viktorbarzin.me"`,
		`document.cookie = "authentik_session=" + "abc" + "; path=/; secure; samesite=lax"`,
		`document.cookie = "authentik_csrf=" + "q\"x" + "; path=/; secure; samesite=lax"`,
		`fetch("/api/v3/core/users/me/"`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("snippet lacks %s:\n%s", want, s)
		}
	}
}

func TestParseBrowserAsArgs(t *testing.T) {
	o, err := parseBrowserAsArgs([]string{"alice", "--reason", "look", "--format=t3"})
	if err != nil || o.user != "alice" || o.reason != "look" || o.format != "t3" {
		t.Fatalf("%+v %v", o, err)
	}
	if o, err := parseBrowserAsArgs([]string{"alice", "--reason=x"}); err != nil || o.format != "json" {
		t.Fatalf("default format: %+v %v", o, err)
	}
	if o, err := parseBrowserAsArgs([]string{"--end"}); err != nil || !o.end || o.user != "" {
		t.Fatalf("--end: %+v %v", o, err)
	}
	if o, err := parseBrowserAsArgs([]string{"--end", "alice"}); err != nil || !o.end || o.user != "alice" {
		t.Fatalf("--end alice: %+v %v", o, err)
	}
	for _, bad := range [][]string{
		{"alice"},         // no reason
		{"--reason", "x"}, // no user
		{"alice", "--reason", "x", "--format", "pdf"}, // bad format
		{"alice", "bob", "--reason", "x"},             // two users
	} {
		if _, err := parseBrowserAsArgs(bad); err == nil {
			t.Errorf("%v: want an error", bad)
		}
	}
}

func TestSnippetCookieJSONIsPlaywrightShaped(t *testing.T) {
	b, _ := json.Marshal(pwCookie{Name: "n", Value: "v", Domain: "d", Path: "/", Expires: -1})
	for _, k := range []string{`"name"`, `"value"`, `"domain"`, `"path"`, `"expires"`, `"httpOnly"`, `"secure"`, `"sameSite"`} {
		if !strings.Contains(string(b), k) {
			t.Errorf("cookie JSON lacks %s: %s", k, b)
		}
	}
}
