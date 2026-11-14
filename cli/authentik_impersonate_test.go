package main

import (
	"encoding/base32"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// RFC 6238 appendix B, SHA1 secret "12345678901234567890". The RFC lists
// 8-digit codes; the last six digits are the 6-digit code.
// rfcSecret is the RFC 6238 test key "12345678901234567890" in base32.
var rfcSecret = base32.StdEncoding.EncodeToString([]byte("12345678901234567890"))

func TestTOTPCodeRFC6238(t *testing.T) {
	secret := rfcSecret
	cases := map[int64]string{
		59:         "287082",
		1111111109: "081804",
		1234567890: "005924",
		2000000000: "279037",
	}
	for unix, want := range cases {
		got, err := totpCode(secret, time.Unix(unix, 0))
		if err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Errorf("totpCode(t=%d) = %s, want %s", unix, got, want)
		}
	}
}

func TestTOTPCodeAcceptsLowercaseAndPadding(t *testing.T) {
	a, err := totpCode(strings.ToLower(rfcSecret), time.Unix(59, 0))
	if err != nil || a != "287082" {
		t.Fatalf("got %q, %v", a, err)
	}
	if _, err := totpCode("not base32!", time.Unix(59, 0)); err == nil {
		t.Fatal("want an error for a bad secret")
	}
}

// fakeAuthentik is the slice of the Authentik API that impersonation uses:
// the authentication flow (identification with an embedded password, then
// TOTP validation), the user list, impersonate, users/me and the logout flow.
type fakeAuthentik struct {
	mu          sync.Mutex
	password    string
	code        string // the only TOTP code accepted
	rejectCodes int    // reject this many correct codes first, like a reused step
	stage       map[string]string
	user        map[string]string // session -> signed-in username
	imp         map[string]string // session -> impersonated username
	reasons     []string
	nextSession int
}

var fakeUsers = map[string]int{"svc-agent": 280, "alice@example.com": 7}

func newFakeAuthentik(password, code string) *fakeAuthentik {
	return &fakeAuthentik{password: password, code: code,
		stage: map[string]string{}, user: map[string]string{}, imp: map[string]string{}}
}

func (f *fakeAuthentik) session(w http.ResponseWriter, r *http.Request) string {
	if c, err := r.Cookie("authentik_session"); err == nil && c.Value != "" {
		return c.Value
	}
	f.nextSession++
	s := "sess" + string(rune('0'+f.nextSession))
	http.SetCookie(w, &http.Cookie{Name: "authentik_session", Value: s, Path: "/", HttpOnly: true})
	http.SetCookie(w, &http.Cookie{Name: "authentik_csrf", Value: "csrf-" + s, Path: "/"})
	return s
}

func (f *fakeAuthentik) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	s := f.session(w, r)
	writeJSON := func(v any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(v)
	}
	switch {
	case r.URL.Path == "/api/v3/flows/executor/default-authentication-flow/":
		if r.Method == http.MethodPost {
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			switch f.stage[s] {
			case "":
				if body["uid_field"] == "svc-agent" && body["password"] == f.password {
					f.stage[s] = "validate"
				}
			case "validate":
				if body["code"] == f.code {
					if f.rejectCodes > 0 {
						f.rejectCodes--
					} else {
						f.stage[s] = "done"
						f.user[s] = "svc-agent"
					}
				}
			}
			http.Redirect(w, r, r.URL.String(), http.StatusFound)
			return
		}
		switch f.stage[s] {
		case "":
			writeJSON(map[string]any{"component": "ak-stage-identification"})
		case "validate":
			writeJSON(map[string]any{"component": "ak-stage-authenticator-validate",
				"device_challenges": []map[string]string{{"device_class": "totp", "device_uid": "67"}}})
		default:
			writeJSON(map[string]any{"component": "xak-flow-redirect", "to": "/"})
		}
	case r.URL.Path == "/api/v3/flows/executor/default-invalidation-flow/":
		delete(f.user, s)
		delete(f.imp, s)
		writeJSON(map[string]any{"component": "xak-flow-redirect", "to": "/"})
	case r.URL.Path == "/api/v3/core/users/me/":
		u, ok := f.user[s]
		if !ok {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		if t, ok := f.imp[s]; ok {
			writeJSON(map[string]any{"user": map[string]any{"username": t}, "original": map[string]any{"username": u}})
			return
		}
		writeJSON(map[string]any{"user": map[string]any{"username": u}, "original": nil})
	case r.URL.Path == "/api/v3/core/users/":
		if _, ok := f.user[s]; !ok {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		var results []map[string]any
		for name, pk := range fakeUsers {
			if r.URL.Query().Get("username") == name || r.URL.Query().Get("email") == name {
				results = append(results, map[string]any{"pk": pk, "username": name})
			}
		}
		writeJSON(map[string]any{"results": results})
	case strings.HasPrefix(r.URL.Path, "/api/v3/core/users/") && strings.HasSuffix(r.URL.Path, "/impersonate/"):
		if r.Method != http.MethodPost || r.Header.Get("X-authentik-CSRF") != "csrf-"+s || f.user[s] != "svc-agent" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["reason"] == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		for name, pk := range fakeUsers {
			if r.URL.Path == "/api/v3/core/users/"+itoa(pk)+"/impersonate/" {
				f.imp[s] = name
				f.reasons = append(f.reasons, body["reason"])
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}
		w.WriteHeader(http.StatusNotFound)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

func testCreds() agentCreds {
	return agentCreds{Username: "svc-agent", Password: "pw", TOTPSecret: rfcSecret}
}

func fixedNow() time.Time { return time.Unix(59, 0) } // code 287082

func TestImpersonationStartsWritesStateAndEnds(t *testing.T) {
	fa := newFakeAuthentik("pw", "287082")
	srv := httptest.NewServer(fa)
	defer srv.Close()

	im, err := startImpersonation(impersonationConfig{
		BaseURL: srv.URL, Creds: testCreds(), Target: "alice@example.com",
		Reason: "check the dashboard", Now: fixedNow, Sleep: func(time.Duration) {},
	})
	if err != nil {
		t.Fatal(err)
	}
	if im.TargetPK != 7 || im.TargetUsername != "alice@example.com" {
		t.Fatalf("target = %d %q", im.TargetPK, im.TargetUsername)
	}
	if len(fa.reasons) != 1 || fa.reasons[0] != "check the dashboard" {
		t.Fatalf("reasons = %v", fa.reasons)
	}

	p := filepath.Join(t.TempDir(), "state.json")
	if err := im.WriteStorageState(p); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("state file mode %v, want 0600", fi.Mode().Perm())
	}
	raw, _ := os.ReadFile(p)
	var st struct {
		Cookies []struct {
			Name, Value, Domain, Path string
			HTTPOnly                  bool `json:"httpOnly"`
		} `json:"cookies"`
		Origins []any `json:"origins"`
	}
	if err := json.Unmarshal(raw, &st); err != nil {
		t.Fatal(err)
	}
	names := map[string]string{}
	for _, c := range st.Cookies {
		names[c.Name] = c.Domain
		if c.Path != "/" {
			t.Errorf("cookie %s path %q", c.Name, c.Path)
		}
	}
	if names["authentik_session"] != "127.0.0.1" || names["authentik_csrf"] != "127.0.0.1" {
		t.Fatalf("cookies = %v", names)
	}
	if st.Origins == nil {
		t.Fatal("origins must be an empty list, not null, for Playwright")
	}

	if err := im.End(); err != nil {
		t.Fatal(err)
	}
	if len(fa.user) != 0 {
		t.Fatalf("session still signed in after End: %v", fa.user)
	}
}

func TestImpersonationRetriesOnceOnRejectedCode(t *testing.T) {
	// The second login inside one 30 s step reuses a code Authentik already
	// accepted, and Authentik refuses it. The next step's code must work.
	fa := newFakeAuthentik("pw", "287082")
	fa.rejectCodes = 1
	srv := httptest.NewServer(fa)
	defer srv.Close()

	var slept time.Duration
	_, err := startImpersonation(impersonationConfig{
		BaseURL: srv.URL, Creds: testCreds(), Target: "alice@example.com", Reason: "r",
		Now: fixedNow, Sleep: func(d time.Duration) { slept += d },
	})
	if err != nil {
		t.Fatal(err)
	}
	if slept <= 0 || slept > 31*time.Second {
		t.Fatalf("slept %v, want a wait to the next 30 s step", slept)
	}
}

func TestImpersonationWrongPasswordFails(t *testing.T) {
	srv := httptest.NewServer(newFakeAuthentik("other", "287082"))
	defer srv.Close()
	_, err := startImpersonation(impersonationConfig{
		BaseURL: srv.URL, Creds: testCreds(), Target: "alice@example.com", Reason: "r",
		Now: fixedNow, Sleep: func(time.Duration) {},
	})
	if err == nil || !strings.Contains(err.Error(), "password") {
		t.Fatalf("err = %v, want a password error", err)
	}
}

func TestImpersonationUnknownUserFails(t *testing.T) {
	srv := httptest.NewServer(newFakeAuthentik("pw", "287082"))
	defer srv.Close()
	_, err := startImpersonation(impersonationConfig{
		BaseURL: srv.URL, Creds: testCreds(), Target: "nobody", Reason: "r",
		Now: fixedNow, Sleep: func(time.Duration) {},
	})
	if err == nil || !strings.Contains(err.Error(), "nobody") {
		t.Fatalf("err = %v", err)
	}
}

func TestImpersonationRequiresReason(t *testing.T) {
	_, err := startImpersonation(impersonationConfig{BaseURL: "http://unused", Creds: testCreds(), Target: "x"})
	if err == nil || !strings.Contains(err.Error(), "--reason") {
		t.Fatalf("err = %v", err)
	}
}

func TestParseBrowserArgsAs(t *testing.T) {
	o, err := parseBrowserArgs("open", []string{"https://x", "--as", "alice@example.com", "--reason=look at it"})
	if err != nil {
		t.Fatal(err)
	}
	if o.asUser != "alice@example.com" || o.asReason != "look at it" {
		t.Fatalf("as=%q reason=%q", o.asUser, o.asReason)
	}
	if _, err := parseBrowserArgs("open", []string{"https://x", "--as", "a"}); err == nil {
		t.Fatal("--as without --reason must fail")
	}
	if _, err := parseBrowserArgs("run", []string{"s.js", "--as", "a", "--reason", "r", "--shared-context"}); err == nil {
		t.Fatal("--as with --shared-context must fail")
	}
}
