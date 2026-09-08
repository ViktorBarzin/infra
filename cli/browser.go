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
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The node CDP client is patchright-core — a playwright-core drop-in that avoids
// the Runtime.enable leak Cloudflare/DataDome fingerprint (design D10). connect
// _over_cdp is version-tolerant and the chrome-service browser is real Chrome
// (newer than the old 1.48 Chromium pin), so tracking a current patchright is
// correct; see docs/architecture/chrome-service.md.
const (
	clientPackage = "patchright-core"
	clientVersion = "1.61.1"
)

// defaultBrowserTimeout is how long (seconds) to wait for the port-forwarded CDP
// endpoint to become ready before giving up.
const defaultBrowserTimeout = 60

const (
	chromeServiceNamespace = "chrome-service"
	chromeServiceName      = "chrome-service" // the always-on MASTER (identity browser)
	chromeServiceCDPPort   = 9222
	brokerServiceName      = "chrome-fleet" // the pool broker Service
	brokerAPIPort          = 8080
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
	sharedCtx bool   // use the warmed persistent profile on the MASTER (bypasses the pool)
	keepOpen  bool   // leave the created context/pages open on exit
	port      int    // explicit local port for the forward (0 = auto)
	timeout   int    // CDP readiness timeout, seconds
	viewport  string // explicit "W,H" viewport override (default: runner's 1920,1080)
	tall      bool   // tall snapshot viewport (1280x2000) for lazy-loaded/virtualized DOM
	noSeed    bool   // pool: do NOT seed the master's cookies (pure clean context)
	seedPath  string // runtime: path to the fetched seed file (set by the pool path)
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
		case a == "--tall":
			o.tall = true
		case a == "--no-seed":
			o.noSeed = true
		case a == "--viewport":
			if i+1 < len(args) {
				o.viewport = args[i+1]
				i++
			}
		case strings.HasPrefix(a, "--viewport="):
			o.viewport = strings.TrimPrefix(a, "--viewport=")
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

// buildPortForwardArgs is the kubectl invocation that exposes a chrome-service
// target locally. target is "svc/chrome-service" (master CDP), "svc/chrome-fleet"
// (broker API), or "pod/<worker>" (a specific pool worker's CDP). port-forward
// tunnels API-server→pod, so it bypasses the NetworkPolicy that gates in-cluster
// callers and works for a named pod under the existing pods/portforward grant.
func buildPortForwardArgs(target string, localPort, remotePort int) []string {
	return []string{"-n", chromeServiceNamespace, "port-forward",
		target, fmt.Sprintf("%d:%d", localPort, remotePort)}
}

// browserClientPackageJSON is the auto-managed manifest for the pinned node CDP
// client kept under the user cache dir.
func browserClientPackageJSON() string {
	return fmt.Sprintf(`{
  "name": "homelab-browser-client",
  "private": true,
  "description": "Pinned CDP client for 'homelab browser' — auto-managed, do not edit.",
  "dependencies": {
    "%s": "%s"
  }
}
`, clientPackage, clientVersion)
}

// resolveViewport picks the effective "W,H" for a fresh context: --tall wins,
// then an explicit --viewport, else "" (the runner defaults to 1920x1080).
func resolveViewport(o browserOpts) string {
	if o.tall {
		return "1280,2000"
	}
	return o.viewport
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
	b, err := os.ReadFile(filepath.Join(dir, "node_modules", clientPackage, "package.json"))
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
	if installedPlaywrightVersion(dir) == clientVersion {
		return nil
	}
	fmt.Fprintf(os.Stderr, "homelab browser: installing pinned %s@%s (one-time, ~a few seconds)…\n", clientPackage, clientVersion)
	cmd := exec.Command("npm", "install", "--no-audit", "--no-fund", "--silent")
	cmd.Dir = dir
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("npm install %s@%s in %s: %w (is node/npm installed?)", clientPackage, clientVersion, dir, err)
	}
	if got := installedPlaywrightVersion(dir); got != clientVersion {
		return fmt.Errorf("%s install mismatch in %s: want %s, got %q", clientPackage, dir, clientVersion, got)
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

// startForward starts a kubectl port-forward to target's remotePort on a fresh
// local port, in its own process group so the whole tree dies on teardown. It
// does NOT wait for readiness — the caller polls the specific endpoint.
func startForward(target string, remotePort int) (localPort int, teardown func(), logbuf *strings.Builder, err error) {
	localPort, err = freePort()
	if err != nil {
		return 0, nil, nil, fmt.Errorf("pick local port: %w", err)
	}
	pf := exec.Command("kubectl", buildPortForwardArgs(target, localPort, remotePort)...)
	pf.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	logbuf = &strings.Builder{}
	pf.Stdout = logbuf
	pf.Stderr = logbuf
	if err = pf.Start(); err != nil {
		return 0, nil, logbuf, fmt.Errorf("start kubectl port-forward %s (kubeconfig set?): %w", target, err)
	}
	var once sync.Once
	teardown = func() {
		once.Do(func() {
			if pf.Process != nil {
				_ = syscall.Kill(-pf.Process.Pid, syscall.SIGKILL)
			}
			_ = pf.Wait()
		})
	}
	return localPort, teardown, logbuf, nil
}

// runBrowser is the orchestration: ensure the pinned client, acquire a session
// (pool worker by default; the MASTER for --shared-context or if the broker is
// down), then run the node runner against its CDP. All port-forwards + the pool
// session are ALWAYS torn down.
func runBrowser(o browserOpts) error {
	dir, err := browserClientDir()
	if err != nil {
		return err
	}
	if err := ensureBrowserClient(dir); err != nil {
		return err
	}

	var teardowns []func()
	var tdMu sync.Mutex
	addTeardown := func(f func()) { tdMu.Lock(); teardowns = append(teardowns, f); tdMu.Unlock() }
	cleanup := func() {
		tdMu.Lock()
		defer tdMu.Unlock()
		for i := len(teardowns) - 1; i >= 0; i-- {
			teardowns[i]()
		}
	}
	defer cleanup()

	// Tear down every forward + release on Ctrl-C / SIGTERM too.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(sigCh)
	go func() {
		if _, ok := <-sigCh; ok {
			cleanup()
			os.Exit(130)
		}
	}()

	var cdpURL string
	usePool := !o.sharedCtx
	if usePool {
		url, err := setupPoolSession(&o, addTeardown)
		if err != nil {
			fmt.Fprintf(os.Stderr, "homelab browser: pool unavailable (%v); falling back to the master browser\n", err)
			usePool = false
		} else {
			cdpURL = url
		}
	}
	if !usePool {
		port, td, logbuf, err := startForward("svc/"+chromeServiceName, chromeServiceCDPPort)
		if err != nil {
			return err
		}
		addTeardown(td)
		cdpURL = fmt.Sprintf("http://127.0.0.1:%d", port)
		browser, err := waitForCDP(cdpURL, time.Duration(o.timeout)*time.Second)
		if err != nil {
			return fmt.Errorf("chrome-service CDP not ready on %s: %w\n--- port-forward log ---\n%s", cdpURL, err, logbuf.String())
		}
		fmt.Fprintf(os.Stderr, "homelab browser: connected to %s via %s (master)\n", browser, cdpURL)
	}

	return runBrowserNode(dir, cdpURL, o)
}

// setupPoolSession port-forwards the broker, acquires a worker, seeds it from the
// master (unless --no-seed), port-forwards that worker's CDP, and returns its
// local CDP URL. It registers teardowns (forwards + release) via addTeardown and
// mutates o.seedPath with the fetched seed file. Any error means "fall back to
// the master" — the caller handles that.
func setupPoolSession(o *browserOpts, addTeardown func(func())) (string, error) {
	bport, btd, blog, err := startForward("svc/"+brokerServiceName, brokerAPIPort)
	if err != nil {
		return "", err
	}
	addTeardown(btd)
	brokerBase := fmt.Sprintf("http://127.0.0.1:%d", bport)
	if err := waitHTTP(brokerBase+"/healthz", 20*time.Second); err != nil {
		return "", fmt.Errorf("broker not reachable: %w\n--- port-forward log ---\n%s", err, blog.String())
	}
	pod, session, err := acquireSession(brokerBase, sessionOwner(), sessionPurpose(*o))
	if err != nil {
		return "", err
	}
	fmt.Fprintf(os.Stderr, "homelab browser: acquired pool session %s (pod %s)\n", session, pod)
	// release the session when the run ends (or on signal) — best-effort.
	addTeardown(func() { releaseSession(brokerBase, session) })

	if !o.noSeed {
		seedFile := filepath.Join(os.TempDir(), fmt.Sprintf("homelab-browser-seed-%d.json", os.Getpid()))
		if err := fetchSeed(brokerBase, seedFile); err != nil {
			fmt.Fprintf(os.Stderr, "homelab browser: seed fetch failed (%v); continuing with a clean context\n", err)
		} else {
			o.seedPath = seedFile
			addTeardown(func() { _ = os.Remove(seedFile) })
		}
	}

	wport, wtd, wlog, err := startForward("pod/"+pod, chromeServiceCDPPort)
	if err != nil {
		return "", err
	}
	addTeardown(wtd)
	cdpURL := fmt.Sprintf("http://127.0.0.1:%d", wport)
	browser, err := waitForCDP(cdpURL, time.Duration(o.timeout)*time.Second)
	if err != nil {
		return "", fmt.Errorf("worker CDP not ready on %s: %w\n--- port-forward log ---\n%s", cdpURL, err, wlog.String())
	}
	fmt.Fprintf(os.Stderr, "homelab browser: connected to %s via %s (pool worker %s)\n", browser, cdpURL, pod)
	return cdpURL, nil
}

// --- broker client -------------------------------------------------------

// sessionOwner labels the pool session with the invoking OS user (mirrors the
// presence model). Falls back to $USER / "unknown".
func sessionOwner() string {
	if u, err := user.Current(); err == nil && u.Username != "" {
		return u.Username
	}
	if v := os.Getenv("USER"); v != "" {
		return v
	}
	return "unknown"
}

// sessionPurpose is a short human hint for FleetView: the script name (run) or
// the target URL (open).
func sessionPurpose(o browserOpts) string {
	if o.mode == "open" && o.url != "" {
		return "open " + o.url
	}
	if o.script != "" {
		return "run " + filepath.Base(o.script)
	}
	return "homelab browser " + o.mode
}

// waitHTTP polls url until it returns any 2xx, or the timeout elapses.
func waitHTTP(url string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	client := &http.Client{Timeout: 3 * time.Second}
	var lastErr error
	for time.Now().Before(deadline) {
		resp, err := client.Get(url)
		if err != nil {
			lastErr = err
			time.Sleep(300 * time.Millisecond)
			continue
		}
		resp.Body.Close()
		if resp.StatusCode/100 == 2 {
			return nil
		}
		lastErr = fmt.Errorf("status %d", resp.StatusCode)
		time.Sleep(300 * time.Millisecond)
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("timed out after %s", timeout)
	}
	return lastErr
}

// parseAcquire reads the broker's /acquire response into (pod, cdpPort, session).
// An {"error":...} body (e.g. pool at capacity) is surfaced as an error.
func parseAcquire(body []byte) (pod string, port int, session string, err error) {
	var v struct {
		Pod     string `json:"pod"`
		CDPPort int    `json:"cdpPort"`
		Session string `json:"session"`
		Error   string `json:"error"`
	}
	if e := json.Unmarshal(body, &v); e != nil {
		return "", 0, "", fmt.Errorf("parse /acquire response: %w", e)
	}
	if v.Error != "" {
		return "", 0, "", fmt.Errorf("broker: %s", v.Error)
	}
	if v.Pod == "" || v.Session == "" {
		return "", 0, "", fmt.Errorf("broker /acquire returned no pod/session: %s", string(body))
	}
	return v.Pod, v.CDPPort, v.Session, nil
}

// acquireSession asks the broker for a worker; returns its pod name + session id.
func acquireSession(brokerBase, owner, purpose string) (pod, session string, err error) {
	reqBody, _ := json.Marshal(map[string]string{"owner": owner, "purpose": purpose})
	client := &http.Client{Timeout: 90 * time.Second} // create+ready can take a few s
	resp, err := client.Post(brokerBase+"/acquire", "application/json", strings.NewReader(string(reqBody)))
	if err != nil {
		return "", "", fmt.Errorf("POST /acquire: %w", err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	pod, _, session, err = parseAcquire(b)
	return pod, session, err
}

// releaseSession tells the broker to reap/return the worker. Best-effort.
func releaseSession(brokerBase, session string) {
	reqBody, _ := json.Marshal(map[string]string{"session": session})
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Post(brokerBase+"/release", "application/json", strings.NewReader(string(reqBody)))
	if err == nil {
		resp.Body.Close()
	}
}

// fetchSeed downloads the broker's on-demand storage_state export to dest.
func fetchSeed(brokerBase, dest string) error {
	client := &http.Client{Timeout: 40 * time.Second}
	resp, err := client.Get(brokerBase + "/seed")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("seed status %d", resp.StatusCode)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	return os.WriteFile(dest, b, 0o600)
}

// listSessions port-forwards the broker and prints the live pool session table.
func listSessions() error {
	bport, btd, blog, err := startForward("svc/"+brokerServiceName, brokerAPIPort)
	if err != nil {
		return err
	}
	defer btd()
	brokerBase := fmt.Sprintf("http://127.0.0.1:%d", bport)
	if err := waitHTTP(brokerBase+"/healthz", 20*time.Second); err != nil {
		return fmt.Errorf("broker not reachable: %w\n--- port-forward log ---\n%s", err, blog.String())
	}
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(brokerBase + "/sessions")
	if err != nil {
		return fmt.Errorf("GET /sessions: %w", err)
	}
	defer resp.Body.Close()
	var out struct {
		Sessions []struct {
			Owner, Purpose, Session, URL, Name string
			Ready                              bool
		} `json:"sessions"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return fmt.Errorf("decode /sessions: %w", err)
	}
	active := 0
	fmt.Printf("%-14s  %-6s  %-24s  %s\n", "OWNER", "READY", "POD", "PURPOSE / URL")
	for _, s := range out.Sessions {
		if s.Session == "" {
			continue // idle/warm worker, not a claimed session
		}
		active++
		detail := s.Purpose
		if s.URL != "" {
			detail = s.URL
		}
		fmt.Printf("%-14s  %-6t  %-24s  %s\n", s.Owner, s.Ready, s.Name, detail)
	}
	if active == 0 {
		fmt.Println("(no active pool sessions)")
	}
	return nil
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
	if vp := resolveViewport(o); vp != "" {
		env = append(env, "HOMELAB_VIEWPORT="+vp)
	}
	if o.seedPath != "" {
		env = append(env, "HOMELAB_STORAGE_STATE="+o.seedPath)
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
