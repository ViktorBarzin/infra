# homelab browser verbs: headful (anti-bot) web automation via cluster Chrome

v0.8 adds `browser run`, `browser open`, and `browser --help`. They package a
capability that already existed but was undiscoverable: driving the cluster's
**headful** Chrome (`chrome-service` — real Chrome under Xvfb, CDP on
`svc/chrome-service:9222`) from the devvm, for sites that detect and block
headless automation.

## Motivating incident (2026-06-22)

Logging a washing-machine repair on the Stirling Ackroyd **Fixflo** tenant
portal: the headless `@playwright/mcp` browser loaded the site and filled the
entire multi-step form, but the **final submit silently failed** — Fixflo's
pre-submit `POST /IssuePreCreationCheck` returned `net::ERR_FILE_NOT_FOUND`, the
spinner hung, no issue was created. Root cause = headless-Chrome detection. The
fix was to drive the headful `chrome-service` over `connect_over_cdp` — it
submitted first try (Fixflo ref IS22657587). That capability was documented
(`docs/architecture/chrome-service.md`) but **not packaged or discoverable**, so
it took ~40 min, three redundant full form re-runs, and a user hint. The agent
also misread `ERR_FILE_NOT_FOUND` as "network egress" and retried blind instead
of inspecting the network panel.

## Decisions

- **Mechanics in `homelab`, not a `~/.claude` skill.** A standalone skill was
  rejected: the CLI is run every session (so the verb is *discoverable*), is
  versioned, multi-user, and test-covered. A private, untested skill is none of
  those. The command owns only the deterministic *mechanics* (port-forward,
  stealth injection, lifecycle) — the agent supplies the Playwright script, so
  *judgment* stays out of the CLI (the founding rule, ADR-0004/0005).
- **The failure was judgment, not setup friction**, so the CLI is paired with a
  one-line pointer in always-in-context `~/code/CLAUDE.md` and a diagnostic
  payload in `browser --help`: the *when-to-use* signature (a site loads but a
  gated action fails/hangs, or one request 500s/aborts while siblings 200 →
  suspect headless detection) and an error-code cheat-sheet (`ERR_FILE_NOT_FOUND`
  = request resolved/intercepted by the automation layer, **not** egress;
  egress failures are `ERR_CONNECTION_REFUSED`/`_TIMED_OUT`/`_NAME_NOT_RESOLVED`
  and would break the page load too). A command the agent doesn't think to run is
  useless; the cheat-sheet is the actual fix for the misdiagnosis.
- **Reach the pod via `kubectl port-forward`, then `connect_over_cdp` to
  localhost.** port-forward tunnels API-server→pod, so it **bypasses the `:9222`
  NetworkPolicy** that gates in-cluster callers — the devvm needs no namespace
  label. Readiness is asserted against `/json/version`: the endpoint must report
  a real `Chrome/…`, never `HeadlessChrome` (the whole point). The forward is
  **always** torn down (process-group kill + signal handler), on success and on
  error — an acceptance requirement.
- **Default to a fresh incognito context; `--shared-context` opts into the warmed
  profile.** chrome-service is a single shared browser with a persistent profile.
  A fresh, always-closed context is safe for concurrent callers (tripit's fare
  scrape connects per-quote) and is what production already does. The warmed
  persistent profile (cookies from a manual noVNC login) is opt-in for flows that
  need a pre-logged-in session.
- **Pin the node CDP client to `playwright-core@1.48.2`** to match the
  chrome-service image minor (`mcr.microsoft.com/playwright:v1.48.0-noble`,
  Chromium 130). `connect_over_cdp` speaks the browser's CDP, and protocol
  changes between Playwright minors — the devvm's ambient Python Playwright was
  1.58, a 10-minor skew. The pin makes behaviour deterministic across the fleet
  regardless of local drift. `playwright-core` (not `playwright`) because no
  browser binary is needed — we connect to the remote one.
- **Self-provision the client lazily, no per-user setup.** The pinned client is
  installed once into `~/.cache/homelab/browser-client/` (idempotent, version-
  guarded) on first use, alongside the embedded runner + stealth files. node is
  already fleet-wide; this avoids coupling the feature to a provisioner change
  and keeps it self-contained and self-healing. The client runs on the devvm, so
  `setInputFiles` streams local files to the remote browser over CDP — no
  `chmod`/staging-dir workaround on the CDP path.
- **Vendor `stealth.js`, guard against drift.** The CLI embeds a byte-for-byte
  copy of `stacks/chrome-service/files/stealth.js` (the source of truth the
  in-cluster callers use) via `go:embed`; a unit test fails if the copy drifts.
  `go:embed` can't reach outside the package dir, hence the vendored copy rather
  than a path reference.
- **Scope held at two action verbs + help.** `run` (arbitrary script — the
  workhorse) and `open` (navigate + title/text/screenshot — a quick check) cover
  the surface. Both are write-tier; the bare `browser`/`--help` is read. Re-measure
  via `usage top` (ADR-0011) before adding more.
