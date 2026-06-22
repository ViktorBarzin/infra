package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// playwrightVersion pins the node CDP client to the chrome-service image minor
// (mcr.microsoft.com/playwright:v1.48.0-noble → Chromium 130). connect_over_cdp
// speaks the browser's CDP, so the client minor must track the server minor;
// see docs/architecture/chrome-service.md "Image pin".
const playwrightVersion = "1.48.2"

// defaultBrowserTimeout is how long (seconds) to wait for the port-forwarded CDP
// endpoint to become ready before giving up.
const defaultBrowserTimeout = 60

const (
	chromeServiceNamespace = "chrome-service"
	chromeServiceName      = "chrome-service"
	chromeServiceCDPPort   = 9222
)

// stealthJS is vendored verbatim from stacks/chrome-service/files/stealth.js (the
// source of truth the in-cluster callers use). TestStealthJSEmbeddedMatchesCanonical
// guards against drift.
//
//go:embed browser_stealth.js
var stealthJS string

// runnerJS is the node wrapper that connects to the port-forwarded CDP endpoint,
// installs the stealth init script, and runs the user's Playwright script.
//
//go:embed browser_runner.js
var runnerJS string

// browserOpts is the parsed form of `homelab browser run|open` arguments.
type browserOpts struct {
	mode      string // "run" | "open"
	script    string // path to the user Playwright script (run mode)
	url       string // initial URL (run: optional; open: required positional)
	sharedCtx bool   // use the warmed persistent profile instead of a fresh context
	keepOpen  bool   // leave the created context/pages open on exit
	port      int    // explicit local port for the forward (0 = auto)
	timeout   int    // CDP readiness timeout, seconds
	help      bool
}

// parseBrowserArgs parses the args after `browser run` / `browser open`.
func parseBrowserArgs(mode string, args []string) (browserOpts, error) {
	o := browserOpts{mode: mode, timeout: defaultBrowserTimeout}
	var positionals []string
	atoi := func(s, flag string) (int, error) {
		n, err := strconv.Atoi(s)
		if err != nil {
			return 0, fmt.Errorf("%s expects an integer, got %q", flag, s)
		}
		return n, nil
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-h" || a == "--help":
			o.help = true
		case a == "--shared-context":
			o.sharedCtx = true
		case a == "--keep-open":
			o.keepOpen = true
		case a == "--url":
			if i+1 < len(args) {
				o.url = args[i+1]
				i++
			}
		case strings.HasPrefix(a, "--url="):
			o.url = strings.TrimPrefix(a, "--url=")
		case a == "--port":
			if i+1 < len(args) {
				n, err := atoi(args[i+1], "--port")
				if err != nil {
					return o, err
				}
				o.port = n
				i++
			}
		case strings.HasPrefix(a, "--port="):
			n, err := atoi(strings.TrimPrefix(a, "--port="), "--port")
			if err != nil {
				return o, err
			}
			o.port = n
		case a == "--timeout":
			if i+1 < len(args) {
				n, err := atoi(args[i+1], "--timeout")
				if err != nil {
					return o, err
				}
				o.timeout = n
				i++
			}
		case strings.HasPrefix(a, "--timeout="):
			n, err := atoi(strings.TrimPrefix(a, "--timeout="), "--timeout")
			if err != nil {
				return o, err
			}
			o.timeout = n
		case strings.HasPrefix(a, "-"):
			return o, fmt.Errorf("unknown flag %q (try: homelab browser --help)", a)
		default:
			positionals = append(positionals, a)
		}
	}
	if o.help {
		return o, nil
	}
	switch mode {
	case "run":
		if len(positionals) == 0 {
			return o, fmt.Errorf("usage: homelab browser run <script.js> [--url URL] [--shared-context] [--keep-open] [--port N] [--timeout S]")
		}
		o.script = positionals[0]
	case "open":
		if len(positionals) == 0 {
			return o, fmt.Errorf("usage: homelab browser open <url> [--shared-context] [--timeout S]")
		}
		o.url = positionals[0]
	}
	return o, nil
}

// cdpHealthy parses a CDP /json/version body and reports whether the endpoint is
// a real (non-headless) Chrome — the entire reason chrome-service exists.
func cdpHealthy(jsonBody []byte) (browser string, healthy bool, err error) {
	var v struct {
		Browser   string `json:"Browser"`
		UserAgent string `json:"User-Agent"`
	}
	if e := json.Unmarshal(jsonBody, &v); e != nil {
		return "", false, fmt.Errorf("parse /json/version: %w", e)
	}
	if v.Browser == "" {
		return "", false, fmt.Errorf("/json/version had no Browser field")
	}
	healthy = strings.HasPrefix(v.Browser, "Chrome/") &&
		!strings.Contains(v.Browser, "Headless") &&
		!strings.Contains(v.UserAgent, "Headless")
	return v.Browser, healthy, nil
}

// buildPortForwardArgs is the kubectl invocation that exposes chrome-service's
// CDP locally. port-forward tunnels API-server→pod, so it bypasses the :9222
// NetworkPolicy that gates in-cluster callers.
func buildPortForwardArgs(localPort int) []string {
	return []string{"-n", chromeServiceNamespace, "port-forward",
		"svc/" + chromeServiceName, fmt.Sprintf("%d:%d", localPort, chromeServiceCDPPort)}
}

// browserClientPackageJSON is the auto-managed manifest for the pinned node CDP
// client kept under the user cache dir.
func browserClientPackageJSON() string {
	return fmt.Sprintf(`{
  "name": "homelab-browser-client",
  "private": true,
  "description": "Pinned CDP client for 'homelab browser' — auto-managed, do not edit.",
  "dependencies": {
    "playwright-core": "%s"
  }
}
`, playwrightVersion)
}

// freePort asks the kernel for an unused ephemeral TCP port.
func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// browserClientDir is where the pinned node client + managed runner files live.
func browserClientDir() (string, error) {
	cache, err := os.UserCacheDir()
	if err != nil || cache == "" {
		home, herr := os.UserHomeDir()
		if herr != nil {
			return "", fmt.Errorf("locate cache dir: %v / %v", err, herr)
		}
		cache = filepath.Join(home, ".cache")
	}
	return filepath.Join(cache, "homelab", "browser-client"), nil
}

// installedPlaywrightVersion reads the version of the playwright-core already
// installed in dir, or "" if absent/unreadable.
func installedPlaywrightVersion(dir string) string {
	b, err := os.ReadFile(filepath.Join(dir, "node_modules", "playwright-core", "package.json"))
	if err != nil {
		return ""
	}
	var v struct {
		Version string `json:"version"`
	}
	if json.Unmarshal(b, &v) != nil {
		return ""
	}
	return v.Version
}

// ensureBrowserClient writes the managed runner/stealth/package files into dir
// and lazily installs the pinned playwright-core (only when missing/mismatched),
// so no per-user setup is needed and the client tracks the binary version.
func ensureBrowserClient(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	files := map[string]string{
		"package.json":      browserClientPackageJSON(),
		"browser_runner.js": runnerJS,
		"stealth.js":        stealthJS,
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			return err
		}
	}
	if installedPlaywrightVersion(dir) == playwrightVersion {
		return nil
	}
	fmt.Fprintf(os.Stderr, "homelab browser: installing pinned playwright-core@%s (one-time, ~a few seconds)…\n", playwrightVersion)
	cmd := exec.Command("npm", "install", "--no-audit", "--no-fund", "--silent")
	cmd.Dir = dir
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("npm install playwright-core@%s in %s: %w (is node/npm installed?)", playwrightVersion, dir, err)
	}
	if got := installedPlaywrightVersion(dir); got != playwrightVersion {
		return fmt.Errorf("playwright-core install mismatch in %s: want %s, got %q", dir, playwrightVersion, got)
	}
	return nil
}

// waitForCDP polls the local CDP endpoint until it answers as a healthy
// (non-headless) Chrome, or the timeout elapses.
func waitForCDP(cdpURL string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	client := &http.Client{Timeout: 3 * time.Second}
	var lastErr error
	for time.Now().Before(deadline) {
		resp, err := client.Get(cdpURL + "/json/version")
		if err != nil {
			lastErr = err
			time.Sleep(300 * time.Millisecond)
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		browser, healthy, herr := cdpHealthy(body)
		if herr != nil {
			lastErr = herr
			time.Sleep(300 * time.Millisecond)
			continue
		}
		if !healthy {
			return browser, fmt.Errorf("CDP reports %q — expected a non-headless Chrome (wrong target?)", browser)
		}
		return browser, nil
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("timed out after %s", timeout)
	}
	return "", lastErr
}

// runBrowser is the orchestration: pick a port, ensure the pinned client, start
// (and ALWAYS tear down) a CDP port-forward, wait for readiness, then run node.
func runBrowser(o browserOpts) error {
	port := o.port
	if port == 0 {
		p, err := freePort()
		if err != nil {
			return fmt.Errorf("pick local port: %w", err)
		}
		port = p
	}

	dir, err := browserClientDir()
	if err != nil {
		return err
	}
	if err := ensureBrowserClient(dir); err != nil {
		return err
	}

	// Start the forward in its own process group so the whole tree dies on cleanup.
	pf := exec.Command("kubectl", buildPortForwardArgs(port)...)
	pf.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var pfLog strings.Builder
	pf.Stdout = &pfLog
	pf.Stderr = &pfLog
	if err := pf.Start(); err != nil {
		return fmt.Errorf("start kubectl port-forward (kubeconfig set?): %w", err)
	}

	var once sync.Once
	teardown := func() {
		once.Do(func() {
			if pf.Process != nil {
				_ = syscall.Kill(-pf.Process.Pid, syscall.SIGKILL)
			}
			_ = pf.Wait()
		})
	}
	defer teardown()

	// Tear down on Ctrl-C / SIGTERM too, then exit non-zero.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sigCh)
	go func() {
		if _, ok := <-sigCh; ok {
			teardown()
			os.Exit(130)
		}
	}()

	cdpURL := fmt.Sprintf("http://127.0.0.1:%d", port)
	browser, err := waitForCDP(cdpURL, time.Duration(o.timeout)*time.Second)
	if err != nil {
		return fmt.Errorf("chrome-service CDP not ready on %s: %w\n--- port-forward log ---\n%s", cdpURL, err, pfLog.String())
	}
	fmt.Fprintf(os.Stderr, "homelab browser: connected to %s via %s\n", browser, cdpURL)

	return runBrowserNode(dir, cdpURL, o)
}

// runBrowserNode invokes the managed node runner with inputs passed via env.
func runBrowserNode(dir, cdpURL string, o browserOpts) error {
	env := append(os.Environ(),
		"HOMELAB_CDP_URL="+cdpURL,
		"HOMELAB_BROWSER_MODE="+o.mode,
		"HOMELAB_STEALTH_PATH="+filepath.Join(dir, "stealth.js"),
		"NODE_PATH="+filepath.Join(dir, "node_modules"),
	)
	if o.url != "" {
		env = append(env, "HOMELAB_BROWSER_URL="+o.url)
	}
	if o.script != "" {
		abs, err := filepath.Abs(o.script)
		if err != nil {
			return err
		}
		if _, err := os.Stat(abs); err != nil {
			return fmt.Errorf("script %s: %w", o.script, err)
		}
		env = append(env, "HOMELAB_BROWSER_SCRIPT="+abs)
	}
	if o.sharedCtx {
		env = append(env, "HOMELAB_BROWSER_SHARED=1")
	}
	if o.keepOpen {
		env = append(env, "HOMELAB_BROWSER_KEEP_OPEN=1")
	}
	if o.mode == "open" {
		shot := filepath.Join(os.TempDir(), fmt.Sprintf("homelab-browser-%d.png", os.Getpid()))
		env = append(env, "HOMELAB_BROWSER_SCREENSHOT="+shot)
	}
	cmd := exec.Command("node", filepath.Join(dir, "browser_runner.js"))
	cmd.Env = env
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	return cmd.Run()
}
