package crowdsec_bouncer_plugin

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// per-origin dry run (CAPI rollout, 2026-10-02)
// ---------------------------------------------------------------------------

func capiBan(ip string) decision {
	return decision{Origin: "CAPI", Type: "ban", Scope: "Ip", Value: ip, Scenario: "http:scan"}
}

func localBan(ip string) decision {
	return decision{Origin: "crowdsec", Type: "ban", Scope: "Ip", Value: ip, Scenario: "crowdsecurity/http-probing"}
}

func TestDryRunOriginDecisionMatchesButDoesNotEnforce(t *testing.T) {
	set := parseDecisionsDryRun([]decision{capiBan("1.2.3.4"), localBan("5.6.7.8")},
		nil, originSet([]string{"CAPI"}))
	found, enforce, origin := set.match(parseIP("1.2.3.4"))
	if !found || enforce || origin != "CAPI" {
		t.Errorf("CAPI ban: found=%v enforce=%v origin=%q, want found, not enforced, CAPI", found, enforce, origin)
	}
	found, enforce, origin = set.match(parseIP("5.6.7.8"))
	if !found || !enforce || origin != "crowdsec" {
		t.Errorf("local ban: found=%v enforce=%v origin=%q, want enforced crowdsec", found, enforce, origin)
	}
	if found, _, _ := set.match(parseIP("9.9.9.9")); found {
		t.Errorf("unlisted IP matched")
	}
}

func TestEnforcingOriginWinsOverDryRunForTheSameIP(t *testing.T) {
	// Order must not matter: a local ban for an IP that CAPI also lists blocks.
	for _, decs := range [][]decision{
		{capiBan("1.2.3.4"), localBan("1.2.3.4")},
		{localBan("1.2.3.4"), capiBan("1.2.3.4")},
	} {
		set := parseDecisionsDryRun(decs, nil, originSet([]string{"CAPI"}))
		if found, enforce, _ := set.match(parseIP("1.2.3.4")); !found || !enforce {
			t.Errorf("decisions %v: found=%v enforce=%v, want enforced", decs, found, enforce)
		}
	}
}

func TestDryRunRangeDecision(t *testing.T) {
	set := parseDecisionsDryRun([]decision{
		{Origin: "CAPI", Type: "ban", Scope: "Range", Value: "10.20.30.0/24"},
	}, nil, originSet([]string{"CAPI"}))
	found, enforce, origin := set.match(parseIP("10.20.30.44"))
	if !found || enforce || origin != "CAPI" {
		t.Errorf("range: found=%v enforce=%v origin=%q", found, enforce, origin)
	}
}

func TestNoDryRunOriginsEnforcesEverything(t *testing.T) {
	set := parseDecisionsDryRun([]decision{capiBan("1.2.3.4")}, nil, nil)
	if found, enforce, _ := set.match(parseIP("1.2.3.4")); !found || !enforce {
		t.Errorf("with no dry-run origins a CAPI ban must enforce: found=%v enforce=%v", found, enforce)
	}
}

func TestDryRunOriginRequestIsLoggedAndServed(t *testing.T) {
	cfg := enforcing()
	cfg.Origins = []string{"crowdsec", "CAPI"}
	cfg.DryRunOrigins = []string{"CAPI"}
	hit := false
	b, err := newBouncer(cfg, okNext(&hit), "test")
	if err != nil {
		t.Fatal(err)
	}
	b.store = &store{}
	b.store.publish(parseDecisionsDryRun([]decision{capiBan("1.2.3.4")}, originSet(cfg.Origins), b.dryRunOrigins))
	lines := capture(b)
	rec := do(b, "1.2.3.4:5555", "app.viktorbarzin.me", nil)
	if !hit || rec.Code != http.StatusOK {
		t.Fatalf("dry-run origin must be served: hit=%v code=%d", hit, rec.Code)
	}
	if len(*lines) != 1 || !strings.Contains((*lines)[0], "action=dry-run-block") || !strings.Contains((*lines)[0], "origin=CAPI") {
		t.Errorf("log = %q, want one dry-run-block line naming origin=CAPI", *lines)
	}
}

func TestEnforcedBanLogNamesTheOrigin(t *testing.T) {
	cfg := enforcing()
	b := testBouncer(t, cfg, banned("1.2.3.4"), okNext(new(bool)))
	lines := capture(b)
	do(b, "1.2.3.4:5555", "app.viktorbarzin.me", nil)
	if len(*lines) != 1 || !strings.Contains((*lines)[0], "action=block") || !strings.Contains((*lines)[0], "origin=cscli") {
		t.Errorf("log = %q, want action=block with origin=cscli", *lines)
	}
}

func TestDryRunOriginsDefaultEmpty(t *testing.T) {
	if len(CreateConfig().DryRunOrigins) != 0 {
		t.Errorf("DryRunOrigins must default to empty")
	}
}

// ---------------------------------------------------------------------------
// CRS routing: a second AppSec listener for hosts without Authentik
// ---------------------------------------------------------------------------

func TestCrsHostsGoToTheCrsListener(t *testing.T) {
	def := newFakeAppsec(t, http.StatusOK)
	crs := newFakeAppsec(t, http.StatusForbidden)
	cfg := appsecConfig(def.srv.URL)
	cfg.AppsecCrsURL = crs.srv.URL
	cfg.AppsecCrsHosts = []string{"Vault.viktorbarzin.me"}
	hit := false
	b := appsecBouncer(t, cfg, okNext(&hit))

	rec := do(b, "203.0.113.9:4444", "vault.viktorbarzin.me:443", nil)
	if hit || rec.Code != http.StatusForbidden || crs.callCount() != 1 || def.callCount() != 0 {
		t.Fatalf("CRS host: hit=%v code=%d crs=%d default=%d", hit, rec.Code, crs.callCount(), def.callCount())
	}
	hit = false
	rec = do(b, "203.0.113.9:4444", "ha-london.viktorbarzin.me", nil)
	if !hit || rec.Code != http.StatusOK || def.callCount() != 1 || crs.callCount() != 1 {
		t.Fatalf("non-CRS host: hit=%v code=%d crs=%d default=%d", hit, rec.Code, crs.callCount(), def.callCount())
	}
}

func TestCrsHostsWithoutCrsURLUseTheDefaultListener(t *testing.T) {
	def := newFakeAppsec(t, http.StatusOK)
	cfg := appsecConfig(def.srv.URL)
	cfg.AppsecCrsHosts = []string{"vault.viktorbarzin.me"}
	b := appsecBouncer(t, cfg, okNext(new(bool)))
	do(b, "203.0.113.9:4444", "vault.viktorbarzin.me", nil)
	if def.callCount() != 1 {
		t.Errorf("with no CRS URL the default listener must be used, calls=%d", def.callCount())
	}
}

func TestBadCrsURLFallsBackToDefaultInsteadOfFailing(t *testing.T) {
	def := newFakeAppsec(t, http.StatusOK)
	cfg := appsecConfig(def.srv.URL)
	cfg.AppsecCrsURL = "::bad"
	cfg.AppsecCrsHosts = []string{"vault.viktorbarzin.me"}
	b, err := newBouncer(cfg, okNext(new(bool)), "test")
	if err != nil {
		t.Fatalf("a bad CRS URL must not fail New: %v", err)
	}
	if b.appsecCrsURL != "" {
		t.Errorf("bad CRS URL must be dropped, got %q", b.appsecCrsURL)
	}
}

func TestSkipHostBeatsCrsHost(t *testing.T) {
	def := newFakeAppsec(t, http.StatusForbidden)
	crs := newFakeAppsec(t, http.StatusForbidden)
	cfg := appsecConfig(def.srv.URL)
	cfg.AppsecCrsURL = crs.srv.URL
	cfg.AppsecCrsHosts = []string{"immich.viktorbarzin.me"}
	cfg.AppsecSkipHosts = []string{"immich.viktorbarzin.me"}
	hit := false
	b := appsecBouncer(t, cfg, okNext(&hit))
	rec := do(b, "203.0.113.9:4444", "immich.viktorbarzin.me", nil)
	if !hit || rec.Code != http.StatusOK || crs.callCount()+def.callCount() != 0 {
		t.Fatalf("skipped host must not reach any listener: hit=%v code=%d", hit, rec.Code)
	}
}

func TestCrsBlockLogNamesTheListener(t *testing.T) {
	def := newFakeAppsec(t, http.StatusOK)
	crs := newFakeAppsec(t, http.StatusForbidden)
	cfg := appsecConfig(def.srv.URL)
	cfg.AppsecCrsURL = crs.srv.URL
	cfg.AppsecCrsHosts = []string{"vault.viktorbarzin.me"}
	b := appsecBouncer(t, cfg, okNext(new(bool)))
	lines := capture(b)
	do(b, "203.0.113.9:4444", "vault.viktorbarzin.me", nil)
	if len(*lines) != 1 || !strings.Contains((*lines)[0], "action=appsec-block") || !strings.Contains((*lines)[0], "ruleset=crs") {
		t.Errorf("log = %q, want appsec-block with ruleset=crs", *lines)
	}
}

func TestFailingCrsListenerDoesNotOpenTheDefaultBreaker(t *testing.T) {
	def := newFakeAppsec(t, http.StatusOK)
	crs := newFakeAppsec(t, http.StatusInternalServerError)
	cfg := appsecConfig(def.srv.URL)
	cfg.AppsecCrsURL = crs.srv.URL
	cfg.AppsecCrsHosts = []string{"vault.viktorbarzin.me"}
	b := appsecBouncer(t, cfg, okNext(new(bool)))
	for i := 0; i < breakerWindow+5; i++ {
		do(b, "203.0.113.9:4444", "vault.viktorbarzin.me", nil)
	}
	before := def.callCount()
	do(b, "203.0.113.9:4444", "ha-london.viktorbarzin.me", nil)
	if def.callCount() != before+1 {
		t.Errorf("default listener stopped being called after CRS failures: the breakers are not separate")
	}
}

func TestHttptestImportUsed(t *testing.T) { _ = httptest.NewRecorder() }
