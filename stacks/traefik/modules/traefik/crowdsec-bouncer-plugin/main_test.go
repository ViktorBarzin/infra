package crowdsec_bouncer_plugin

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// okNext records that the request reached the backend.
func okNext(hit *bool) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		*hit = true
		rw.WriteHeader(http.StatusOK)
	})
}

// testBouncer builds a middleware with no background poller, with the ban set
// pre-loaded from the given decisions — the request path under test.
func testBouncer(t *testing.T, cfg *Config, decisions []decision, next http.Handler) *Bouncer {
	t.Helper()
	b, err := newBouncer(cfg, next, "test")
	if err != nil {
		t.Fatalf("newBouncer: %v", err)
	}
	b.store = &store{}
	b.store.publish(parseDecisions(decisions, originSet(cfg.Origins)))
	b.logf = func(string) {}
	return b
}

// capture redirects the middleware's decision log into a slice the test owns.
func capture(b *Bouncer) *[]string {
	var lines []string
	b.logf = func(line string) { lines = append(lines, line) }
	return &lines
}

func do(b *Bouncer, remoteAddr, host string, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "http://"+host+"/some/path", nil)
	req.RemoteAddr = remoteAddr
	req.Host = host
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	b.ServeHTTP(rec, req)
	return rec
}

// enforcing is CreateConfig with dry run turned off. Enforcement tests opt in
// explicitly, because shipping dry-run-by-default is itself a tested property.
func enforcing() *Config {
	cfg := CreateConfig()
	cfg.DryRun = false
	return cfg
}

func banned(ip string) []decision {
	return []decision{{Origin: "cscli", Type: "ban", Scope: "Ip", Value: ip, Scenario: "manual"}}
}

// ---------------------------------------------------------------------------
// decision parsing
// ---------------------------------------------------------------------------

func TestParseDecisionsKeepsOnlyBans(t *testing.T) {
	set := parseDecisions([]decision{
		{Origin: "cscli", Type: "ban", Scope: "Ip", Value: "1.2.3.4"},
		{Origin: "cscli", Type: "captcha", Scope: "Ip", Value: "5.6.7.8"},
		{Origin: "cscli", Type: "throttle", Scope: "Ip", Value: "9.9.9.9"},
	}, nil)

	if !set.contains(parseIP("1.2.3.4")) {
		t.Error("ban decision was not loaded")
	}
	// A captcha decision must never block: the captcha_remediation profile
	// diverts four FP-prone scenarios to a captcha that is enforced nowhere.
	if set.contains(parseIP("5.6.7.8")) {
		t.Error("captcha decision must be ignored, not enforced as a ban")
	}
	if set.contains(parseIP("9.9.9.9")) {
		t.Error("throttle decision must be ignored")
	}
}

func TestParseDecisionsIsCaseInsensitive(t *testing.T) {
	// LAPI returns scope "Ip" (capitalised); tolerate any casing on both fields.
	set := parseDecisions([]decision{
		{Origin: "cscli", Type: "BAN", Scope: "ip", Value: "1.2.3.4"},
	}, nil)
	if !set.contains(parseIP("1.2.3.4")) {
		t.Error("uppercase type / lowercase scope should still parse as a ban")
	}
}

func TestParseDecisionsHandlesRangeScope(t *testing.T) {
	// default_range_remediation can emit scope=Range; the old python sync only
	// ever handled scope=="ip" and would have silently dropped these.
	set := parseDecisions([]decision{
		{Origin: "cscli", Type: "ban", Scope: "Range", Value: "10.20.30.0/24"},
	}, nil)

	if !set.contains(parseIP("10.20.30.44")) {
		t.Error("IP inside a banned range should be blocked")
	}
	if set.contains(parseIP("10.20.31.44")) {
		t.Error("IP outside a banned range must not be blocked")
	}
}

func TestParseDecisionsIgnoresUnsupportedScopes(t *testing.T) {
	set := parseDecisions([]decision{
		{Origin: "cscli", Type: "ban", Scope: "Country", Value: "RU"},
		{Origin: "cscli", Type: "ban", Scope: "AS", Value: "12345"},
		{Origin: "cscli", Type: "ban", Scope: "Username", Value: "bob"},
	}, nil)
	if set.size() != 0 {
		t.Errorf("non-IP scopes must be ignored, got %d entries", set.size())
	}
}

func TestParseDecisionsExcludesDisallowedOrigins(t *testing.T) {
	allowed := originSet([]string{"crowdsec", "cscli", "cscli-import", "lists", "console"})
	set := parseDecisions([]decision{
		{Origin: "CAPI", Type: "ban", Scope: "Ip", Value: "1.2.3.4"},
		{Origin: "cscli", Type: "ban", Scope: "Ip", Value: "5.6.7.8"},
	}, allowed)

	// CAPI is ~22.7k bans that have never been enforced on proxied hosts;
	// carrier/CGNAT false positives there would surface as user-visible 403s.
	if set.contains(parseIP("1.2.3.4")) {
		t.Error("CAPI decision must be excluded while CAPI is not in allowedOrigins")
	}
	if !set.contains(parseIP("5.6.7.8")) {
		t.Error("local cscli decision must be kept")
	}
}

func TestParseDecisionsEmptyOriginSetAllowsEverything(t *testing.T) {
	set := parseDecisions([]decision{
		{Origin: "CAPI", Type: "ban", Scope: "Ip", Value: "1.2.3.4"},
	}, nil)
	if !set.contains(parseIP("1.2.3.4")) {
		t.Error("an empty allowedOrigins means enforce every origin, CAPI included")
	}
}

func TestParseDecisionsNormalisesIPv6(t *testing.T) {
	set := parseDecisions([]decision{
		{Origin: "cscli", Type: "ban", Scope: "Ip", Value: "2001:0db8:0000:0000:0000:0000:0000:0001"},
	}, nil)
	if !set.contains(parseIP("2001:db8::1")) {
		t.Error("IPv6 lookup must be canonical-form independent")
	}
}

func TestParseDecisionsSkipsGarbage(t *testing.T) {
	set := parseDecisions([]decision{
		{Origin: "cscli", Type: "ban", Scope: "Ip", Value: "not-an-ip"},
		{Origin: "cscli", Type: "ban", Scope: "Ip", Value: ""},
		{Origin: "cscli", Type: "ban", Scope: "Range", Value: "10.0.0.0/nope"},
	}, nil)
	if set.size() != 0 {
		t.Errorf("unparseable values must be skipped, got %d", set.size())
	}
}

// ---------------------------------------------------------------------------
// client-IP extraction (peer trust)
// ---------------------------------------------------------------------------

func TestSpoofedHeadersFromUntrustedPeerAreIgnored(t *testing.T) {
	// The attack this defends against: a banned client connects DIRECTLY to
	// Traefik (WAN :443 NATs straight to it, bypassing Cloudflare) and claims
	// to be someone else. Traefik's forwardedheaders does not manage
	// Cf-Connecting-Ip, so only the TCP peer can be trusted.
	var hit bool
	b := testBouncer(t, enforcing(), banned("9.9.9.9"), okNext(&hit))

	rec := do(b, "9.9.9.9:44321", "app.viktorbarzin.me", map[string]string{
		"Cf-Connecting-Ip": "8.8.8.8",
		"X-Forwarded-For":  "8.8.8.8",
	})

	if hit {
		t.Error("banned peer slipped through by spoofing Cf-Connecting-Ip/X-Forwarded-For")
	}
	if rec.Code != http.StatusForbidden {
		t.Errorf("want 403 for spoofing banned peer, got %d", rec.Code)
	}
}

func TestUntrustedPeerIsNotBannedByAnotherIPsHeaders(t *testing.T) {
	// Mirror image: a legitimate client must not be blocked because it happens
	// to forward a header naming a banned IP.
	var hit bool
	b := testBouncer(t, enforcing(), banned("8.8.8.8"), okNext(&hit))

	rec := do(b, "9.9.9.9:44321", "app.viktorbarzin.me", map[string]string{
		"Cf-Connecting-Ip": "8.8.8.8",
	})

	if !hit {
		t.Error("clean peer was blocked on the strength of a header it supplied")
	}
	if rec.Code != http.StatusOK {
		t.Errorf("want 200, got %d", rec.Code)
	}
}

func TestTrustedProxyPeerUsesCfConnectingIP(t *testing.T) {
	// cloudflared runs in-cluster: the peer is a pod IP, and the real client is
	// the one it names in Cf-Connecting-Ip.
	var hit bool
	b := testBouncer(t, enforcing(), banned("8.8.8.8"), okNext(&hit))

	rec := do(b, "10.10.4.7:33333", "app.viktorbarzin.me", map[string]string{
		"Cf-Connecting-Ip": "8.8.8.8",
	})

	if hit {
		t.Error("banned client behind the cloudflared tunnel was not blocked")
	}
	if rec.Code != http.StatusForbidden {
		t.Errorf("want 403, got %d", rec.Code)
	}
}

func TestTrustedProxyPeerFallsBackToForwardedFor(t *testing.T) {
	var hit bool
	b := testBouncer(t, enforcing(), banned("8.8.8.8"), okNext(&hit))

	// No Cf-Connecting-Ip: first PUBLIC XFF entry wins (private hops skipped).
	rec := do(b, "10.10.4.7:33333", "app.viktorbarzin.me", map[string]string{
		"X-Forwarded-For": "10.10.0.9, 8.8.8.8, 1.1.1.1",
	})

	if hit {
		t.Error("banned client in X-Forwarded-For was not blocked")
	}
	if rec.Code != http.StatusForbidden {
		t.Errorf("want 403, got %d", rec.Code)
	}
}

func TestTrustedProxyPeerWithNoHeadersFallsBackToPeer(t *testing.T) {
	var hit bool
	b := testBouncer(t, enforcing(), banned("10.10.4.7"), okNext(&hit))

	rec := do(b, "10.10.4.7:33333", "app.viktorbarzin.me", nil)

	if hit {
		t.Error("trusted peer with no forwarding headers should be judged on the peer itself")
	}
	if rec.Code != http.StatusForbidden {
		t.Errorf("want 403, got %d", rec.Code)
	}
}

func TestIPv6PeerIsMatched(t *testing.T) {
	// pfSense rewrites RemoteAddr via PROXY-v2 for IPv6 clients.
	var hit bool
	b := testBouncer(t, enforcing(), banned("2001:db8::1"), okNext(&hit))

	rec := do(b, "[2001:db8::1]:44321", "app.viktorbarzin.me", nil)

	if hit {
		t.Error("banned IPv6 peer was not blocked")
	}
	if rec.Code != http.StatusForbidden {
		t.Errorf("want 403, got %d", rec.Code)
	}
}

func TestUnparseablePeerAllows(t *testing.T) {
	var hit bool
	b := testBouncer(t, enforcing(), banned("1.2.3.4"), okNext(&hit))

	rec := do(b, "not-an-address", "app.viktorbarzin.me", nil)

	if !hit {
		t.Error("an unparseable peer must fail open, not block")
	}
	if rec.Code != http.StatusOK {
		t.Errorf("want 200, got %d", rec.Code)
	}
}

// ---------------------------------------------------------------------------
// ban / allow
// ---------------------------------------------------------------------------

func TestBanMiss(t *testing.T) {
	var hit bool
	b := testBouncer(t, enforcing(), banned("1.2.3.4"), okNext(&hit))

	rec := do(b, "5.6.7.8:1234", "app.viktorbarzin.me", nil)

	if !hit {
		t.Error("unbanned client was blocked")
	}
	if rec.Code != http.StatusOK {
		t.Errorf("want 200, got %d", rec.Code)
	}
}

func TestBanResponseUsesConfiguredStatusAndBody(t *testing.T) {
	cfg := CreateConfig()
	cfg.DryRun = false
	cfg.BanStatusCode = 429
	cfg.BanMessage = "go away"
	var hit bool
	b := testBouncer(t, cfg, banned("1.2.3.4"), okNext(&hit))

	rec := do(b, "1.2.3.4:1234", "app.viktorbarzin.me", nil)

	if rec.Code != 429 {
		t.Errorf("want 429, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "go away") {
		t.Errorf("want configured body, got %q", rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// auth-host carve-out
// ---------------------------------------------------------------------------

func TestAuthHostsAreSkipped(t *testing.T) {
	// A false-positive ban must never be able to wall someone out of the login
	// / WebAuthn flow they would need to fix anything.
	for _, host := range []string{
		"authentik.viktorbarzin.me",
		"public-auth.viktorbarzin.me",
		"AUTHENTIK.viktorbarzin.me",     // case-insensitive
		"authentik.viktorbarzin.me.",    // trailing dot
		"authentik.viktorbarzin.me:443", // explicit port
	} {
		var hit bool
		b := testBouncer(t, enforcing(), banned("1.2.3.4"), okNext(&hit))

		rec := do(b, "1.2.3.4:1234", host, nil)

		if !hit {
			t.Errorf("%s: banned client must still reach the auth host", host)
		}
		if rec.Code != http.StatusOK {
			t.Errorf("%s: want 200, got %d", host, rec.Code)
		}
	}
}

func TestNonAuthHostIsStillEnforced(t *testing.T) {
	var hit bool
	b := testBouncer(t, enforcing(), banned("1.2.3.4"), okNext(&hit))

	rec := do(b, "1.2.3.4:1234", "notauthentik.viktorbarzin.me", nil)

	if hit {
		t.Error("carve-out must match the host exactly, not by substring")
	}
	if rec.Code != http.StatusForbidden {
		t.Errorf("want 403, got %d", rec.Code)
	}
}

// ---------------------------------------------------------------------------
// dry run
// ---------------------------------------------------------------------------

func TestDryRunLogsButDoesNotBlock(t *testing.T) {
	cfg := CreateConfig()
	cfg.DryRun = true
	var hit bool
	b := testBouncer(t, cfg, banned("1.2.3.4"), okNext(&hit))
	logged := capture(b)

	rec := do(b, "1.2.3.4:1234", "app.viktorbarzin.me", nil)

	if !hit {
		t.Error("dry run must not block")
	}
	if rec.Code != http.StatusOK {
		t.Errorf("want 200 in dry run, got %d", rec.Code)
	}
	if len(*logged) != 1 || !strings.Contains((*logged)[0], "action=dry-run-block") {
		t.Errorf("dry run must log a would-block decision, got %v", *logged)
	}
}

func TestEnforcingLogsBlock(t *testing.T) {
	cfg := CreateConfig()
	cfg.DryRun = false
	var hit bool
	b := testBouncer(t, cfg, banned("1.2.3.4"), okNext(&hit))
	logged := capture(b)

	do(b, "1.2.3.4:1234", "app.viktorbarzin.me", nil)

	if len(*logged) != 1 || !strings.Contains((*logged)[0], "action=block") {
		t.Errorf("a block must be logged for the Loki alert, got %v", *logged)
	}
}

func TestAllowedRequestIsNotLogged(t *testing.T) {
	var hit bool
	b := testBouncer(t, enforcing(), banned("1.2.3.4"), okNext(&hit))
	logged := capture(b)

	do(b, "5.6.7.8:1234", "app.viktorbarzin.me", nil)

	if len(*logged) != 0 {
		t.Errorf("allowed requests must not log (10 req/s steady state), got %v", *logged)
	}
}

// ---------------------------------------------------------------------------
// fail open
// ---------------------------------------------------------------------------

func TestNeverLoadedAllows(t *testing.T) {
	var hit bool
	b, err := newBouncer(enforcing(), okNext(&hit), "test")
	if err != nil {
		t.Fatalf("newBouncer: %v", err)
	}
	b.store = &store{} // no successful poll yet
	b.logf = func(string) {}

	rec := do(b, "1.2.3.4:1234", "app.viktorbarzin.me", nil)

	if !hit {
		t.Error("a bouncer that has never loaded decisions must allow everything")
	}
	if rec.Code != http.StatusOK {
		t.Errorf("want 200, got %d", rec.Code)
	}
}

func TestLapiDownServesLastKnownSet(t *testing.T) {
	// Fail open means "last known good", not "wipe the set": a LAPI outage must
	// not un-ban everyone, and must not block everyone either.
	s := &store{}
	s.publish(parseDecisions(banned("1.2.3.4"), nil))

	lapi := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		rw.WriteHeader(http.StatusInternalServerError)
	}))
	defer lapi.Close()

	err := s.refresh(http.DefaultClient, lapi.URL, "key", nil, func(string) {})
	if err == nil {
		t.Fatal("want an error from a 500 LAPI")
	}
	if !s.snapshot().contains(parseIP("1.2.3.4")) {
		t.Error("a failed refresh must keep the previous decision set")
	}
}

func TestLapiUnreachableKeepsSet(t *testing.T) {
	s := &store{}
	s.publish(parseDecisions(banned("1.2.3.4"), nil))

	// Port 1 on loopback: connection refused, immediately.
	err := s.refresh(&http.Client{Timeout: 2 * time.Second}, "http://127.0.0.1:1", "key", nil,
		func(string) {})
	if err == nil {
		t.Fatal("want a transport error")
	}
	if !s.snapshot().contains(parseIP("1.2.3.4")) {
		t.Error("an unreachable LAPI must keep the previous decision set")
	}
}

// ---------------------------------------------------------------------------
// polling
// ---------------------------------------------------------------------------

func TestRefreshLoadsDecisionsAndSendsAuthAndOriginFilter(t *testing.T) {
	var gotKey, gotOrigins, gotPath, gotUA string
	lapi := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		gotKey = req.Header.Get("X-Api-Key")
		gotUA = req.Header.Get("User-Agent")
		gotPath = req.URL.Path
		gotOrigins = req.URL.Query().Get("origins")
		rw.Header().Set("Content-Type", "application/json")
		json.NewEncoder(rw).Encode(banned("1.2.3.4"))
	}))
	defer lapi.Close()

	s := &store{}
	origins := []string{"cscli", "lists"}
	if err := s.refresh(http.DefaultClient, lapi.URL, "secret-key", origins,
		func(string) {}); err != nil {
		t.Fatalf("refresh: %v", err)
	}

	if gotKey != "secret-key" {
		t.Errorf("want the bouncer key in X-Api-Key, got %q", gotKey)
	}
	if gotPath != "/v1/decisions" {
		t.Errorf("want the full-snapshot endpoint, got %q", gotPath)
	}
	// Server-side filtering is what keeps the payload at a few KB instead of
	// the ~3 MB the full CAPI set weighs.
	if gotOrigins != "cscli,lists" {
		t.Errorf("want origins pushed to LAPI, got %q", gotOrigins)
	}
	if !strings.Contains(gotUA, "crowdsec") {
		t.Errorf("want an identifiable User-Agent so cscli bouncers list is readable, got %q", gotUA)
	}
	if !s.snapshot().contains(parseIP("1.2.3.4")) {
		t.Error("decision was not loaded")
	}
}

func TestRefreshWithNoOriginsOmitsTheFilter(t *testing.T) {
	var raw string
	lapi := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		raw = req.URL.RawQuery
		rw.Write([]byte("null"))
	}))
	defer lapi.Close()

	s := &store{}
	if err := s.refresh(http.DefaultClient, lapi.URL, "k", nil, func(string) {}); err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if raw != "" {
		t.Errorf("no configured origins means no filter at all, got %q", raw)
	}
}

func TestRefreshHandlesNullBody(t *testing.T) {
	// LAPI answers a filter that matches nothing with literal `null`, not `[]`.
	lapi := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		rw.Write([]byte("null"))
	}))
	defer lapi.Close()

	s := &store{}
	s.publish(parseDecisions(banned("1.2.3.4"), nil))

	if err := s.refresh(http.DefaultClient, lapi.URL, "k", nil, func(string) {}); err != nil {
		t.Fatalf("refresh: %v", err)
	}
	// An empty LAPI is a real state (every decision expired) — it must clear
	// the set, otherwise bans would never lift.
	if s.snapshot().contains(parseIP("1.2.3.4")) {
		t.Error("an empty LAPI response must clear the ban set")
	}
	if !s.snapshot().loaded {
		t.Error("an empty-but-successful refresh still counts as loaded")
	}
}

func TestRefreshRejectsMalformedJSON(t *testing.T) {
	lapi := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		rw.Write([]byte("{not json"))
	}))
	defer lapi.Close()

	s := &store{}
	s.publish(parseDecisions(banned("1.2.3.4"), nil))

	if err := s.refresh(http.DefaultClient, lapi.URL, "k", nil, func(string) {}); err == nil {
		t.Fatal("want an error on malformed JSON")
	}
	if !s.snapshot().contains(parseIP("1.2.3.4")) {
		t.Error("malformed JSON must not wipe the set")
	}
}

func TestNewPollsInBackground(t *testing.T) {
	var mu sync.Mutex
	calls := 0
	lapi := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		mu.Lock()
		calls++
		mu.Unlock()
		json.NewEncoder(rw).Encode(banned("1.2.3.4"))
	}))
	defer lapi.Close()

	resetRegistry()
	defer resetRegistry()

	cfg := CreateConfig()
	cfg.LapiURL = lapi.URL
	cfg.LapiKey = "k"
	cfg.PollSeconds = 1
	cfg.DryRun = false

	var hit bool
	h, err := New(context.Background(), okNext(&hit), cfg, "crowdsec")
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	// The first load happens synchronously in New so the very first request is
	// already enforced rather than failing open for one poll interval.
	req := httptest.NewRequest(http.MethodGet, "http://app.viktorbarzin.me/", nil)
	req.RemoteAddr = "1.2.3.4:1234"
	req.Host = "app.viktorbarzin.me"
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("want the first request already enforced, got %d", rec.Code)
	}

	// ... and it keeps polling.
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		n := calls
		mu.Unlock()
		if n >= 2 {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Error("background poller did not poll a second time")
}

func TestNewSharesOnePollerPerConfig(t *testing.T) {
	// Traefik calls New again on every dynamic-config reload. Without a shared
	// store each reload would leak a goroutine and add LAPI load forever.
	lapi := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		rw.Write([]byte("null"))
	}))
	defer lapi.Close()

	resetRegistry()
	defer resetRegistry()

	cfg := CreateConfig()
	cfg.LapiURL = lapi.URL
	cfg.LapiKey = "k"

	var hit bool
	first, err := New(context.Background(), okNext(&hit), cfg, "crowdsec")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	second, err := New(context.Background(), okNext(&hit), cfg, "crowdsec")
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	if registrySize() != 1 {
		t.Errorf("want one shared poller, got %d", registrySize())
	}
	if first.(*Bouncer).store != second.(*Bouncer).store {
		t.Error("both instances must share the same decision store")
	}
}

func TestNewSupersedesAPollerWhenPollConfigChanges(t *testing.T) {
	lapi := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		rw.Write([]byte("null"))
	}))
	defer lapi.Close()

	resetRegistry()
	defer resetRegistry()

	cfg := CreateConfig()
	cfg.LapiURL = lapi.URL
	cfg.LapiKey = "k"

	var hit bool
	if _, err := New(context.Background(), okNext(&hit), cfg, "crowdsec"); err != nil {
		t.Fatalf("New: %v", err)
	}

	changed := CreateConfig()
	changed.LapiURL = lapi.URL
	changed.LapiKey = "k"
	changed.PollSeconds = 60
	if _, err := New(context.Background(), okNext(&hit), changed, "crowdsec"); err != nil {
		t.Fatalf("New: %v", err)
	}

	if registrySize() != 1 {
		t.Errorf("a changed poll config must supersede the old poller, not add one: %d", registrySize())
	}
}

// ---------------------------------------------------------------------------
// config
// ---------------------------------------------------------------------------

func TestCreateConfigDefaultsAreSafe(t *testing.T) {
	cfg := CreateConfig()

	if !cfg.DryRun {
		t.Error("the shipped default must be dry run — enforcement is opted into")
	}
	if cfg.PollSeconds != 30 {
		t.Errorf("want a 30s poll, got %d", cfg.PollSeconds)
	}
	if cfg.BanStatusCode != http.StatusForbidden {
		t.Errorf("want 403, got %d", cfg.BanStatusCode)
	}
	if len(cfg.TrustedProxyCIDRs) == 0 {
		t.Error("trusted proxy CIDRs must default to the pod CIDR, never to empty")
	}
	for _, want := range []string{"authentik.viktorbarzin.me", "public-auth.viktorbarzin.me"} {
		found := false
		for _, h := range cfg.SkipHosts {
			if h == want {
				found = true
			}
		}
		if !found {
			t.Errorf("%s must be carved out by default", want)
		}
	}
	for _, o := range cfg.Origins {
		if strings.EqualFold(o, "CAPI") {
			t.Error("CAPI must not be enforced by default")
		}
	}
	if len(cfg.Origins) == 0 {
		t.Error("an empty default Origins would silently enforce all 22.7k CAPI bans")
	}
}

func TestNewRejectsMalformedCIDR(t *testing.T) {
	cfg := CreateConfig()
	cfg.TrustedProxyCIDRs = []string{"not-a-cidr"}
	var hit bool
	if _, err := newBouncer(cfg, okNext(&hit), "test"); err == nil {
		t.Error("a malformed CIDR must fail loudly, not silently widen or narrow trust")
	}
}

func TestNewRejectsEmptyLapiKey(t *testing.T) {
	cfg := CreateConfig()
	cfg.LapiKey = ""
	var hit bool
	if _, err := New(context.Background(), okNext(&hit), cfg, "crowdsec"); err == nil {
		t.Error("an unauthenticated bouncer would silently enforce nothing")
	}
}

func TestEmptyTrustedCIDRsFallsBackToPodCIDR(t *testing.T) {
	cfg := CreateConfig()
	cfg.TrustedProxyCIDRs = []string{"  "}
	var hit bool
	b, err := newBouncer(cfg, okNext(&hit), "test")
	if err != nil {
		t.Fatalf("newBouncer: %v", err)
	}
	if len(b.trustedNets) == 0 {
		t.Error("must never degrade to trust-nothing/trust-everything on empty input")
	}
}
