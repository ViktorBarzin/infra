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

func TestBuildPortForwardArgs(t *testing.T) {
	got := buildPortForwardArgs(18080)
	want := []string{"-n", "chrome-service", "port-forward", "svc/chrome-service", "18080:9222"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("buildPortForwardArgs =\n %v\nwant\n %v", got, want)
	}
}

func TestBrowserClientPackageJSONPinsVersion(t *testing.T) {
	pj := browserClientPackageJSON()
	if !strings.Contains(pj, `"playwright-core": "`+playwrightVersion+`"`) {
		t.Fatalf("package.json must pin playwright-core to %s; got:\n%s", playwrightVersion, pj)
	}
}

func TestPlaywrightVersionPinnedToServerMinor(t *testing.T) {
	// chrome-service runs mcr.microsoft.com/playwright:v1.48.0-noble; the CDP
	// client minor MUST match (protocol changes between minors).
	if !strings.HasPrefix(playwrightVersion, "1.48.") {
		t.Fatalf("playwrightVersion = %q, must be 1.48.x to match the chrome-service image", playwrightVersion)
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
