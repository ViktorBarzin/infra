package main

import "fmt"

// browser verbs drive the cluster's HEADFUL Chrome (ns chrome-service) over CDP
// from outside the cluster, for sites that detect/block headless automation.
// The headless @playwright/mcp browser can load such sites but their gated
// actions (submit/login) silently fail; this path submits first try. Mechanics
// only — the agent supplies the Playwright script. See docs/adr/0013.

func browserCommands() []Command {
	return []Command{
		{Path: []string{"browser"}, Tier: TierRead,
			Summary: "headful cluster-Chrome automation for anti-bot sites (run `browser --help`)", Run: browserTopHelp},
		{Path: []string{"browser", "run"}, Tier: TierWrite,
			Summary: "run a Playwright script against headful cluster Chrome: browser run <script.js> [--url U] [--shared-context]", Run: browserRun},
		{Path: []string{"browser", "open"}, Tier: TierWrite,
			Summary: "open a URL in headful cluster Chrome; print title + text + screenshot: browser open <url>", Run: browserOpen},
		{Path: []string{"browser", "ls"}, Tier: TierRead,
			Summary: "list live pool browser sessions (owner, purpose, current URL, age)", Run: browserLs},
	}
}

func browserLs(args []string) error {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			fmt.Print(browserHelp())
			return nil
		}
	}
	return listSessions()
}

func browserTopHelp([]string) error {
	fmt.Print(browserHelp())
	return nil
}

func browserRun(args []string) error {
	o, err := parseBrowserArgs("run", args)
	if err != nil {
		return err
	}
	if o.help {
		fmt.Print(browserHelp())
		return nil
	}
	return runBrowser(o)
}

func browserOpen(args []string) error {
	o, err := parseBrowserArgs("open", args)
	if err != nil {
		return err
	}
	if o.help {
		fmt.Print(browserHelp())
		return nil
	}
	return runBrowser(o)
}

// browserHelp carries the discoverability payload: WHEN to reach for this, and
// the diagnostic cheat-sheet that lets the agent self-correct instead of
// retrying a deterministic form blind (the failure mode that motivated this).
func browserHelp() string {
	return `homelab browser — drive the cluster's HEADFUL Chrome (anti-bot) over CDP

The shared chrome-service (ns chrome-service) runs a REAL, headed Chrome under
Xvfb. This connects to it via a port-forward + Playwright connect_over_cdp,
injects the same stealth.js the in-cluster callers use, and runs your script.

USAGE
  homelab browser run <script.js> [--url URL] [--shared-context] [--no-seed] [--viewport WxH | --tall] [--keep-open] [--timeout S]
  homelab browser open <url> [--shared-context] [--timeout S]
  homelab browser ls        # list live pool sessions (owner, current URL, age)

WHEN TO USE THIS — escalation only; DEFAULT to the headless/MCP browser
  Default to the Playwright MCP / headless browser for ALL routine browsing and
  automation — it's interactive (snapshot per step), fast to start, isolated.
  Reach for THIS command ONLY when headless is demonstrably blocked: a site
  LOADS fine but a gated action FAILS or HANGS — a submit/login/checkout spins
  forever, or ONE request errors while its siblings 200. That is the signature
  of headless / anti-bot detection (navigator.webdriver, UA "HeadlessChrome",
  disable-devtool traps). It presents as a real Chrome and usually succeeds
  first try — but it's the shared cluster browser (slower startup, one batch
  run, no per-step feedback), so it's the escalation path, never the default.

ERROR-CODE CHEAT-SHEET (diagnose BEFORE retrying)
  ERR_FILE_NOT_FOUND (-6)   request intercepted/resolved locally by the
                            automation layer — NOT a network/egress problem.
                            (This is what silently broke the headless submit.)
  ERR_CONNECTION_REFUSED /  real egress failure (DNS/route/firewall). These also
  ERR_TIMED_OUT /           break the initial page load — if the page loaded,
  ERR_NAME_NOT_RESOLVED     egress is fine and the cause is elsewhere.
  one endpoint 500s while   server-side bot rejection of the automation, not
  its siblings 200          your payload.

HABITS
  - Inspect the network panel BEFORE retrying a deterministic form; a blind
    retry just repeats the same silent failure.
  - Don't park a half-filled multi-step form across a user pause — the session
    can expire; re-run the whole flow from this command in one shot.
  - Uploads stream over CDP via setInputFiles from THIS host — no chmod/staging
    of $HOME needed; just point setInputFiles at a local path.

CONTEXT (pool by default)
  Default: you get your OWN isolated worker pod from the pool (broker at
  chrome-fleet), seeded read-only with the master's logged-in cookies +
  localStorage, in a fresh context closed on exit. Concurrent callers never
  contend; a wedged session is capped to its own pod. If the broker is down this
  falls back to the shared master browser automatically.
  --no-seed:         a pure clean context (no master cookies injected).
  --shared-context:  bypass the pool and reuse the master's warmed PERSISTENT
                     profile (cookies from a manual noVNC login at
                     chrome.viktorbarzin.me) — needed for write-back workflows
                     (e.g. Google Maps saved lists) and IndexedDB-bound auth.
  --viewport WxH:    context viewport (default 1920x1080 DPR1).
  --tall:            1280x2000 — pulls more lazy-loaded/virtualized DOM per snapshot.
  Watch live sessions in FleetView: https://chrome-fleet.viktorbarzin.me

SCRIPT CONTRACT (run mode)
  Your file's body runs with page, context, browser and log() already in scope
  (top-level await allowed). Return a value to print it. Example flow.js:

    await page.goto('https://portal.example.com/login');
    await page.fill('#user', 'me'); await page.fill('#pass', process.env.PW);
    await page.click('button[type=submit]');
    await page.waitForURL('**/dashboard');
    return 'logged in: ' + page.url();

  Run it:  homelab browser run flow.js

NOTES
  - The CDP client is ` + clientPackage + `@` + clientVersion + ` (a playwright-core drop-in that
    avoids the Runtime.enable anti-bot leak); installed once into ~/.cache/homelab/.
  - All port-forwards + the pool session are always torn down, on success and error.
`
}
