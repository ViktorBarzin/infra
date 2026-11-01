package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

const testSecret = "test-proxy-secret-0123456789abcdef"

func TestMain(m *testing.M) {
	proxySecret = testSecret
	os.Exit(m.Run())
}

// twoUsers serves wizard on host t3 and emo on host t3-emo, each instance
// answering with its owner's name so a test can see where a request landed.
func twoUsers(t *testing.T) (wizard, emo *httptest.Server) {
	t.Helper()
	inst := func(name string) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/api/auth/session" {
				_, _ = w.Write([]byte(`{"authenticated":true}`))
				return
			}
			if r.Header.Get(secretHeader) != "" {
				_, _ = w.Write([]byte("LEAKED"))
				return
			}
			_, _ = w.Write([]byte(name))
		}))
	}
	wizard, emo = inst("WIZARD"), inst("EMO")
	mu.Lock()
	table = map[string]entry{
		"vbarzin":     {OsUser: "wizard", Port: portOf(t, wizard), Host: "t3"},
		"emil.barzin": {OsUser: "emo", Port: portOf(t, emo), Host: "t3-emo"},
		"nohost":      {OsUser: "nohost", Port: portOf(t, emo)},
	}
	mu.Unlock()
	return wizard, emo
}

func request(host, user, secret string) *http.Request {
	r := httptest.NewRequest("GET", "/api/x", nil)
	r.Host = host
	if user != "" {
		r.Header.Set("X-authentik-username", user)
	}
	if secret != "" {
		r.Header.Set(secretHeader, secret)
	}
	r.AddCookie(&http.Cookie{Name: cookieName, Value: "good"})
	return r
}

func serve(r *http.Request) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	handler(w, r)
	return w
}

func TestHandlerRoutesEachHostToItsOwner(t *testing.T) {
	wizard, emo := twoUsers(t)
	defer wizard.Close()
	defer emo.Close()
	for _, c := range []struct{ host, user, want string }{
		{"t3.viktorbarzin.me", "vbarzin@gmail.com", "WIZARD"},
		{"t3-emo.viktorbarzin.me", "emil.barzin", "EMO"},
		{"T3-EMO.viktorbarzin.me:443", "emil.barzin@gmail.com", "EMO"},
	} {
		w := serve(request(c.host, c.user, testSecret))
		if w.Code != http.StatusOK || w.Body.String() != c.want {
			t.Errorf("%s as %s: want 200 %s, got %d %q", c.host, c.user, c.want, w.Code, w.Body.String())
		}
	}
}

// Every devvm user is in Home Server Admins, so Authentik alone is not what
// keeps one user off another's host; the dispatch checks the owner itself.
func TestHandlerRefusesAUserOnAnotherUsersHost(t *testing.T) {
	wizard, emo := twoUsers(t)
	defer wizard.Close()
	defer emo.Close()
	for _, c := range []struct{ host, user string }{
		{"t3.viktorbarzin.me", "emil.barzin"},
		{"t3-emo.viktorbarzin.me", "vbarzin@gmail.com"},
		{"t3-emo.viktorbarzin.me", ""},
		{"t3-emo.viktorbarzin.me", "nobody"},
	} {
		if w := serve(request(c.host, c.user, testSecret)); w.Code != http.StatusForbidden {
			t.Errorf("%s as %q: want 403, got %d %q", c.host, c.user, w.Code, w.Body.String())
		}
	}
}

func TestHandlerRefusesAHostNobodyOwns(t *testing.T) {
	wizard, emo := twoUsers(t)
	defer wizard.Close()
	defer emo.Close()
	// "nohost" has an instance but no host: it must not be reachable through
	// an empty or unknown host label.
	for _, host := range []string{"t3-nobody.viktorbarzin.me", "", "10.0.10.10:3780", "127.0.0.1"} {
		if w := serve(request(host, "nohost", testSecret)); w.Code != http.StatusForbidden {
			t.Errorf("host %q: want 403, got %d %q", host, w.Code, w.Body.String())
		}
	}
}

// Without the secret, anyone who reaches the port could name any user in
// X-authentik-username. No mint may happen for such a request.
func TestHandlerRefusesRequestsWithoutTheProxySecret(t *testing.T) {
	wizard, emo := twoUsers(t)
	defer wizard.Close()
	defer emo.Close()
	minted := 0
	orig := mintToken
	mintToken = func(string) ([]byte, error) { minted++; return []byte(`{"credential":"tok"}`), nil }
	defer func() { mintToken = orig }()
	for _, secret := range []string{"", "wrong", testSecret + "x"} {
		r := request("t3.viktorbarzin.me", "vbarzin", secret)
		r.Header.Del("Cookie") // would auto-pair if admitted
		if w := serve(r); w.Code != http.StatusForbidden {
			t.Errorf("secret %q: want 403, got %d %q", secret, w.Code, w.Body.String())
		}
	}
	if minted != 0 {
		t.Fatalf("minted %d pairing codes for unauthenticated requests", minted)
	}
}

func TestCheckSecretFailsClosedWhenUnset(t *testing.T) {
	proxySecret = ""
	defer func() { proxySecret = testSecret }()
	r := httptest.NewRequest("GET", "/", nil)
	if checkSecret(r) {
		t.Fatal("an unset secret must refuse every request, not admit them")
	}
}

// The user's own t3 serve must never see the lobby's proxy secret: with it, a
// user could speak to the lobby services as anyone.
func TestHandlerStripsTheProxySecretBeforeProxying(t *testing.T) {
	wizard, emo := twoUsers(t)
	defer wizard.Close()
	defer emo.Close()
	w := serve(request("t3.viktorbarzin.me", "vbarzin", testSecret))
	if w.Body.String() != "WIZARD" {
		t.Fatalf("upstream saw the proxy secret or was not reached: %d %q", w.Code, w.Body.String())
	}
}

func TestHostLabel(t *testing.T) {
	for in, want := range map[string]string{
		"t3.viktorbarzin.me":         "t3",
		"T3-EMO.viktorbarzin.me:443": "t3-emo",
		"t3":                         "t3",
		"":                           "",
		"10.0.10.10:3780":            "10",
		"[::1]:3780":                 "",
	} {
		if got := hostLabel(in); got != want {
			t.Errorf("hostLabel(%q) = %q, want %q", in, got, want)
		}
	}
}
