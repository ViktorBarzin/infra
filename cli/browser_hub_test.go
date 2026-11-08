package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func writeHubJSON(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "hub.json")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadHubConfig(t *testing.T) {
	cases := []struct {
		name    string
		body    *string // nil = file absent
		want    *hubConfig
		wantErr string
	}{
		{name: "absent file means no hub", body: nil, want: nil},
		{
			name: "wizard hub",
			body: strPtr(`{"user":"wizard","namespace":"chrome-service","broker_url":"https://chrome-fleet-api.viktorbarzin.me/","read_token":"r","write_token":"w","snapshot_url":"https://x/api/snapshot"}`),
			want: &hubConfig{User: "wizard", Namespace: "chrome-service", BrokerURL: "https://chrome-fleet-api.viktorbarzin.me", ReadToken: "r"},
		},
		{
			name: "loopback http allowed (tests, local tunnels)",
			body: strPtr(`{"namespace":"chrome-emo","broker_url":"http://127.0.0.1:8080","read_token":"r"}`),
			want: &hubConfig{Namespace: "chrome-emo", BrokerURL: "http://127.0.0.1:8080", ReadToken: "r"},
		},
		{name: "malformed json", body: strPtr(`{not json`), wantErr: "parse"},
		{name: "missing broker_url", body: strPtr(`{"namespace":"chrome-emo","read_token":"r"}`), wantErr: "broker_url"},
		{name: "missing read_token", body: strPtr(`{"namespace":"chrome-emo","broker_url":"https://b"}`), wantErr: "read_token"},
		{name: "missing namespace", body: strPtr(`{"broker_url":"https://b","read_token":"r"}`), wantErr: "namespace"},
		{name: "plain http to a remote host refused (bearer would travel in clear)", body: strPtr(`{"namespace":"chrome-emo","broker_url":"http://chrome-fleet-api.viktorbarzin.me","read_token":"r"}`), wantErr: "https"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := filepath.Join(t.TempDir(), "hub.json")
			if tc.body != nil {
				p = writeHubJSON(t, *tc.body)
			}
			got, err := loadHubConfig(p)
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("err = %v, want it to mention %q", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected err: %v", err)
			}
			if (got == nil) != (tc.want == nil) || (got != nil && *got != *tc.want) {
				t.Fatalf("loadHubConfig = %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestHubConfigPathEnvOverride(t *testing.T) {
	t.Setenv(hubConfigEnv, "/tmp/elsewhere/hub.json")
	if got := hubConfigPath(); got != "/tmp/elsewhere/hub.json" {
		t.Fatalf("hubConfigPath with %s set = %q", hubConfigEnv, got)
	}
	t.Setenv(hubConfigEnv, "")
	t.Setenv("HOME", "/home/someone")
	if got := hubConfigPath(); got != "/home/someone/.config/chrome-hub/hub.json" {
		t.Fatalf("hubConfigPath default = %q", got)
	}
}

func TestHubTarget(t *testing.T) {
	cases := []struct {
		name        string
		hub         *hubConfig
		wantNS      string
		wantSvc     string
		wantHeadful bool
	}{
		{"no hub: today's master", nil, "chrome-service", "chrome-service", true},
		{"wizard's hub is the master", &hubConfig{Namespace: "chrome-service"}, "chrome-service", "chrome-service", true},
		{"emo's hub", &hubConfig{Namespace: "chrome-emo"}, "chrome-emo", "chrome-hub", false},
		{"any other user's hub", &hubConfig{Namespace: "chrome-alice"}, "chrome-alice", "chrome-hub", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := hubTarget(tc.hub)
			if got.namespace != tc.wantNS || got.service != tc.wantSvc || got.requireHeadful != tc.wantHeadful {
				t.Fatalf("hubTarget = %+v, want ns=%s svc=%s headful=%t", got, tc.wantNS, tc.wantSvc, tc.wantHeadful)
			}
		})
	}
}

func TestWorkerNamespace(t *testing.T) {
	cases := []struct {
		name        string
		fromAcquire string
		hub         *hubConfig
		want        string
	}{
		{"acquire response wins", "chrome-emo", &hubConfig{Namespace: "chrome-service"}, "chrome-emo"},
		{"absent: hub.json namespace", "", &hubConfig{Namespace: "chrome-emo"}, "chrome-emo"},
		{"absent and no hub: chrome-service", "", nil, "chrome-service"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := workerNamespace(tc.fromAcquire, tc.hub); got != tc.want {
				t.Fatalf("workerNamespace = %q, want %q", got, tc.want)
			}
		})
	}
}

// fakeBroker records the Authorization header of every request and answers
// the four broker endpoints the CLI uses.
type fakeBroker struct {
	mu     sync.Mutex
	auth   map[string]string // path -> Authorization header seen
	status int               // forced status for every request (0 = normal)
}

func (f *fakeBroker) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.auth[r.URL.Path] = r.Header.Get("Authorization")
		forced := f.status
		f.mu.Unlock()
		if forced != 0 {
			w.WriteHeader(forced)
			_, _ = w.Write([]byte(`{"error":"nope"}`))
			return
		}
		switch r.URL.Path {
		case "/acquire":
			_, _ = w.Write([]byte(`{"pod":"chrome-worker-q1","cdpPort":9222,"session":"q1","namespace":"chrome-emo"}`))
		case "/release", "/heartbeat":
			_, _ = w.Write([]byte(`{"ok":true}`))
		case "/seed":
			_, _ = w.Write([]byte(`{"cookies":[],"origins":[]}`))
		case "/sessions":
			_, _ = w.Write([]byte(`{"sessions":[{"owner":"emo","purpose":"run a.js","session":"q1","name":"chrome-worker-q1","ready":true},{"name":"chrome-worker-warm","ready":true}]}`))
		default:
			http.NotFound(w, r)
		}
	})
}

func newFakeBroker(t *testing.T) (*fakeBroker, *httptest.Server) {
	f := &fakeBroker{auth: map[string]string{}}
	srv := httptest.NewServer(f.handler())
	t.Cleanup(srv.Close)
	return f, srv
}

func TestBrokerClientBearer(t *testing.T) {
	cases := []struct {
		name     string
		token    string
		wantAuth string
	}{
		{"hub: bearer on every call", "tok-123", "Bearer tok-123"},
		{"no hub (port-forward): no Authorization header", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f, srv := newFakeBroker(t)
			b := brokerClient{base: srv.URL, token: tc.token, remote: tc.token != ""}

			acq, err := b.acquire("emo", "run a.js")
			if err != nil {
				t.Fatalf("acquire: %v", err)
			}
			if acq.Pod != "chrome-worker-q1" || acq.Session != "q1" || acq.Namespace != "chrome-emo" {
				t.Fatalf("acquire = %+v", acq)
			}
			stop := b.startHeartbeat(acq.Session)
			stop()
			seed := filepath.Join(t.TempDir(), "seed.json")
			if err := b.fetchSeed(seed); err != nil {
				t.Fatalf("fetchSeed: %v", err)
			}
			if fi, err := os.Stat(seed); err != nil || fi.Mode().Perm() != 0o600 {
				t.Fatalf("seed file: %v mode %v, want 0600", err, fi)
			}
			if _, err := b.sessions(); err != nil {
				t.Fatalf("sessions: %v", err)
			}
			b.release(acq.Session)

			f.mu.Lock()
			defer f.mu.Unlock()
			for _, p := range []string{"/acquire", "/heartbeat", "/seed", "/sessions", "/release"} {
				got, ok := f.auth[p]
				if !ok {
					t.Errorf("%s was never called", p)
					continue
				}
				if got != tc.wantAuth {
					t.Errorf("%s Authorization = %q, want %q", p, got, tc.wantAuth)
				}
			}
		})
	}
}

func TestBrokerClientStatusErrors(t *testing.T) {
	cases := []struct {
		name     string
		status   int
		wantErr  error
		wantText string
	}{
		{"401: token wrong or rotated", http.StatusUnauthorized, errBrokerUnauthorized, "provisioning"},
		{"403: refused, LAN-only allowlist", http.StatusForbidden, errBrokerForbidden, "LAN-only"},
	}
	calls := map[string]func(b brokerClient) error{
		"acquire":  func(b brokerClient) error { _, err := b.acquire("emo", "x"); return err },
		"seed":     func(b brokerClient) error { return b.fetchSeed(filepath.Join(t.TempDir(), "s.json")) },
		"sessions": func(b brokerClient) error { _, err := b.sessions(); return err },
	}
	for _, tc := range cases {
		for call, fn := range calls {
			t.Run(tc.name+"/"+call, func(t *testing.T) {
				f, srv := newFakeBroker(t)
				f.status = tc.status
				err := fn(brokerClient{base: srv.URL, token: "stale", remote: true})
				if !errors.Is(err, tc.wantErr) {
					t.Fatalf("err = %v, want errors.Is %v", err, tc.wantErr)
				}
				if !strings.Contains(err.Error(), tc.wantText) {
					t.Fatalf("err %q should mention %q", err, tc.wantText)
				}
			})
		}
	}
}

func TestBrokerClientUnreachable(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	base := srv.URL
	srv.Close() // nothing listens there now

	b := brokerClient{base: base, token: "t", remote: true}
	_, err := b.acquire("emo", "x")
	if !errors.Is(err, errBrokerUnreachable) {
		t.Fatalf("err = %v, want errBrokerUnreachable", err)
	}
	if !strings.Contains(err.Error(), "LAN-only") || !strings.Contains(err.Error(), base) {
		t.Fatalf("unreachable error %q should name the host and say it is LAN-only", err)
	}

	// The port-forward path is local: no LAN-only wording there.
	local := brokerClient{base: base}
	_, err = local.acquire("emo", "x")
	if err == nil || strings.Contains(err.Error(), "LAN-only") {
		t.Fatalf("local broker error = %v; must error without the LAN-only hint", err)
	}
}

func TestBrokerAcquireCapacityError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"error":"pool at capacity (6); retry shortly"}`))
	}))
	defer srv.Close()
	_, err := brokerClient{base: srv.URL, token: "t", remote: true}.acquire("emo", "x")
	if err == nil || !strings.Contains(err.Error(), "pool at capacity") {
		t.Fatalf("err = %v, want the broker's capacity message", err)
	}
}

func TestPrintSessions(t *testing.T) {
	_, srv := newFakeBroker(t)
	list, err := brokerClient{base: srv.URL, token: "t", remote: true}.sessions()
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	printSessions(&buf, list)
	out := buf.String()
	if !strings.Contains(out, "emo") || !strings.Contains(out, "chrome-worker-q1") {
		t.Fatalf("session table missing the claimed session:\n%s", out)
	}
	if strings.Contains(out, "chrome-worker-warm") {
		t.Fatalf("idle warm worker should not be listed:\n%s", out)
	}

	buf.Reset()
	printSessions(&buf, nil)
	if !strings.Contains(buf.String(), "no active pool sessions") {
		t.Fatalf("empty table = %q", buf.String())
	}
}

// The acquire request body keeps today's contract: owner + purpose.
func TestBrokerAcquireBody(t *testing.T) {
	var got map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(`{"pod":"p","session":"s"}`))
	}))
	defer srv.Close()
	if _, err := (brokerClient{base: srv.URL}).acquire("wizard", "open https://x"); err != nil {
		t.Fatal(err)
	}
	if got["owner"] != "wizard" || got["purpose"] != "open https://x" {
		t.Fatalf("acquire body = %v", got)
	}
}
