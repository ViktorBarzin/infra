package main

import (
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestParseBrowserArgsRun(t *testing.T) {
	got, err := parseBrowserArgs("run", []string{
		"flow.js", "--url", "https://example.com", "--shared-context",
		"--port", "19999", "--timeout", "45", "--keep-open",
	})
	if err != nil {
		t.Fatalf("parseBrowserArgs run: unexpected err: %v", err)
	}
	want := browserOpts{
		mode: "run", script: "flow.js", url: "https://example.com",
		sharedCtx: true, keepOpen: true, port: 19999, timeout: 45,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseBrowserArgs run =\n %+v\nwant\n %+v", got, want)
	}
}

func TestParseBrowserArgsRunDefaults(t *testing.T) {
	got, err := parseBrowserArgs("run", []string{"flow.js"})
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got.script != "flow.js" || got.sharedCtx || got.keepOpen || got.port != 0 {
		t.Fatalf("defaults wrong: %+v", got)
	}
	if got.timeout != defaultBrowserTimeout {
		t.Fatalf("timeout default = %d, want %d", got.timeout, defaultBrowserTimeout)
	}
}

func TestParseBrowserArgsRunRequiresScript(t *testing.T) {
	if _, err := parseBrowserArgs("run", []string{"--url", "https://x"}); err == nil {
		t.Fatalf("run without a script path should error")
	}
}

func TestParseBrowserArgsOpenRequiresURL(t *testing.T) {
	got, err := parseBrowserArgs("open", []string{"https://example.com"})
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got.url != "https://example.com" || got.mode != "open" {
		t.Fatalf("open parse wrong: %+v", got)
	}
	if _, err := parseBrowserArgs("open", []string{}); err == nil {
		t.Fatalf("open without a URL should error")
	}
}

func TestParseBrowserArgsHelp(t *testing.T) {
	for _, a := range [][]string{{"--help"}, {"-h"}, {"flow.js", "--help"}} {
		got, err := parseBrowserArgs("run", a)
		if err != nil {
			t.Fatalf("help parse %v: %v", a, err)
		}
		if !got.help {
			t.Fatalf("args %v should set help", a)
		}
	}
}

func TestParseBrowserArgsEqualsForm(t *testing.T) {
	got, err := parseBrowserArgs("run", []string{"flow.js", "--url=https://x", "--port=8123", "--timeout=10"})
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got.url != "https://x" || got.port != 8123 || got.timeout != 10 {
		t.Fatalf("--flag=value form not parsed: %+v", got)
	}
}

func TestCDPHealthy(t *testing.T) {
	real := []byte(`{"Browser":"Chrome/130.0.6723.31","User-Agent":"Mozilla/5.0 (X11; Linux x86_64) Chrome/130.0.0.0 Safari/537.36","webSocketDebuggerUrl":"ws://127.0.0.1/devtools/browser/x"}`)
	browser, ok, err := cdpHealthy(real)
	if err != nil || !ok {
		t.Fatalf("real Chrome should be healthy: ok=%v err=%v", ok, err)
	}
	if !strings.HasPrefix(browser, "Chrome/") {
		t.Fatalf("browser = %q, want Chrome/ prefix", browser)
	}

	headless := []byte(`{"Browser":"HeadlessChrome/130.0.6723.31","User-Agent":"Mozilla/5.0 HeadlessChrome/130.0.0.0"}`)
	if _, ok, _ := cdpHealthy(headless); ok {
		t.Fatalf("HeadlessChrome must be reported unhealthy (the whole point of chrome-service)")
	}

	if _, _, err := cdpHealthy([]byte("not json")); err == nil {
		t.Fatalf("malformed /json/version body should error")
	}
}

func TestBuildPortForwardArgsMaster(t *testing.T) {
	got := buildPortForwardArgs("svc/chrome-service", 18080, 9222)
	want := []string{"-n", "chrome-service", "port-forward", "svc/chrome-service", "18080:9222"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("buildPortForwardArgs(master) =\n %v\nwant\n %v", got, want)
	}
}

func TestBuildPortForwardArgsWorkerPodTarget(t *testing.T) {
	// The pool path forwards to a NAMED worker pod, not the Service (which would
	// load-balance to a random pool pod). Covered by the existing namespace-wide
	// pods/portforward grant.
	got := buildPortForwardArgs("pod/chrome-worker-abc123", 12345, 9222)
	want := []string{"-n", "chrome-service", "port-forward", "pod/chrome-worker-abc123", "12345:9222"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("buildPortForwardArgs(worker) =\n %v\nwant\n %v", got, want)
	}
}

func TestParseAcquire(t *testing.T) {
	pod, port, session, err := parseAcquire([]byte(`{"pod":"chrome-worker-abc123","cdpPort":9222,"session":"abc123","reused":false}`))
	if err != nil {
		t.Fatalf("parseAcquire: %v", err)
	}
	if pod != "chrome-worker-abc123" || port != 9222 || session != "abc123" {
		t.Fatalf("parseAcquire = %q %d %q", pod, port, session)
	}
	// an error body (broker at capacity) must surface as an error, not empty success
	if _, _, _, err := parseAcquire([]byte(`{"error":"pool at capacity (6); retry shortly"}`)); err == nil {
		t.Fatalf("parseAcquire must error on an {\"error\":...} broker response")
	}
	if _, _, _, err := parseAcquire([]byte(`not json`)); err == nil {
		t.Fatalf("parseAcquire must error on malformed JSON")
	}
}

func TestResolveViewport(t *testing.T) {
	// --tall wins; explicit --viewport next; default empty (runner defaults to 1920x1080)
	if v := resolveViewport(browserOpts{tall: true}); v != "1280,2000" {
		t.Fatalf("--tall viewport = %q, want 1280,2000", v)
	}
	if v := resolveViewport(browserOpts{viewport: "2560,1440"}); v != "2560,1440" {
		t.Fatalf("--viewport passthrough = %q", v)
	}
	if v := resolveViewport(browserOpts{}); v != "" {
		t.Fatalf("no viewport flag should yield empty (runner default), got %q", v)
	}
}

func TestBrowserClientPackageJSONPinsVersion(t *testing.T) {
	pj := browserClientPackageJSON()
	if !strings.Contains(pj, `"`+clientPackage+`": "`+clientVersion+`"`) {
		t.Fatalf("package.json must pin %s to %s; got:\n%s", clientPackage, clientVersion, pj)
	}
}

func TestClientIsPatchright(t *testing.T) {
	// The CDP client is patchright-core (a playwright-core drop-in that avoids the
	// Runtime.enable leak Cloudflare/DataDome watch for). connect_over_cdp is
	// version-tolerant, and the chrome-service browser is real Chrome (newer than
	// the old 1.48 pin), so tracking a current patchright is correct.
	if clientPackage != "patchright-core" {
		t.Fatalf("clientPackage = %q, want patchright-core (closes the Runtime.enable CDP leak)", clientPackage)
	}
}

func TestBrowserHelpHasDiagnosticCheatSheet(t *testing.T) {
	h := browserHelp()
	for _, want := range []string{
		"homelab browser run",
		"ERR_FILE_NOT_FOUND",
		"ERR_CONNECTION_REFUSED",
		"network panel",
		"headless",
		"--shared-context",
	} {
		if !strings.Contains(h, want) {
			t.Errorf("browser --help is missing %q (the discoverability/self-correction payload)", want)
		}
	}
}

func TestBrowserHelpIsTiered(t *testing.T) {
	// --help must frame this as the ESCALATION path (default to headless first),
	// matching ~/code/CLAUDE.md and chrome-service.md — non-conflicting agent
	// instructions. Guard against a regression to "co-equal choice" wording.
	h := browserHelp()
	for _, want := range []string{"Default to the", "escalation"} {
		if !strings.Contains(h, want) {
			t.Errorf("browser --help must carry the tiered/default-headless framing; missing %q", want)
		}
	}
}

func TestStealthJSEmbeddedMatchesCanonical(t *testing.T) {
	// The embedded copy must never drift from the source of truth that the
	// in-cluster callers use, else the CLI's stealth and the cluster's diverge.
	canonical, err := os.ReadFile("../stacks/chrome-service/files/stealth.js")
	if err != nil {
		t.Fatalf("read canonical stealth.js: %v", err)
	}
	if stealthJS != string(canonical) {
		t.Fatalf("cli/browser_stealth.js has drifted from stacks/chrome-service/files/stealth.js — re-copy it")
	}
}

func TestFreePortReturnsUsablePort(t *testing.T) {
	p, err := freePort()
	if err != nil {
		t.Fatalf("freePort: %v", err)
	}
	if p <= 1024 || p > 65535 {
		t.Fatalf("freePort returned %d, want an ephemeral port", p)
	}
}
