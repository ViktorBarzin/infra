# ADR-0027: CrowdSec AppSec runs inside our Traefik bouncer, and never reads an upload

- Status: accepted
- Date: 2026-10-02
- Supersedes: the 2026-09-16 decision recorded in memory #13252 ("do not adopt CrowdSec AppSec on Traefik")
- Related: ADR-0026 (Cloudflare 100 MiB upload cap), `docs/architecture/security.md` (CrowdSec section)

## Context

Until now CrowdSec on HTTP has worked from logs: the agents read Traefik's access
log, scenarios notice abusive behaviour, and the bouncer plugin on the `websecure`
entrypoint returns 403 to banned addresses. It does that well (verified
2026-10-02: a scanner got its last 200 at 23:53:00 and 315 consecutive 403s after
that). What it does not do is look at a request before it reaches the backend, so
the first exploit attempt from a fresh address always arrives. Nothing else in the
stack inspects request content either, and the Cloudflare edge cannot be relied on
for it, because pfSense forwards WAN :443 straight to Traefik.

CrowdSec's AppSec component is the inspection engine CrowdSec ships for this. The
2026-09-16 review rejected it because the stock Traefik bouncer
(`maxlerebourg/crowdsec-bouncer-traefik-plugin`) reads up to 10 MB of every request
body into memory before calling the backend (`appsecQuery`, `io.ReadAll` over an
`io.LimitReader`, about three copies). The hosts without Cloudflare in front of
them are exactly the ones that move large bodies (Immich, Forgejo, Stremio), and an
earlier setup that held Immich uploads at the ingress before passing them on caused
doubled upload time and failed uploads whenever the ingress restarted.

## Decision

AppSec inspection is added to our own bouncer plugin
(`stacks/traefik/modules/traefik/crowdsec-bouncer-plugin/`), with a body policy
under which an upload body is never read.

```mermaid
flowchart TD
  C[Client] --> P{IP banned?}
  P -->|yes| X[403]
  P -->|no| S{host skipped?}
  S -->|yes| B[backend]
  S -->|no| A[AppSec check:<br/>small text body,<br/>else headers only]
  A -->|403| X
  A -->|allow / error| B
```

- **Body policy.** The body goes to AppSec only when Go's parsed
  `req.ContentLength` is between 1 and 65,536 bytes, the request has no
  `Content-Encoding` (or `identity`), and the media type is
  `application/x-www-form-urlencoded`, `application/json`, `*+json`,
  `application/xml`, `text/xml` or `*+xml`. Any other request, including every
  multipart, chunked, octet-stream, compressed or larger upload, is checked on
  method, URI and headers only, and its body is passed to the backend untouched.
  An inspected body is read through a limit as bytes arrive, never pre-allocated
  from the declared length.
- **Opt-out.** `appsecSkipHosts` lists hosts that skip AppSec but keep ban
  enforcement. At launch it holds `immich.viktorbarzin.me`. The existing
  `skipHosts` (the two Authentik hosts) skip the whole plugin, AppSec included.
- **Enforcement.** Blocking from the first day. Only an AppSec `403` blocks;
  `200` allows, and `401`, `500`, timeouts and connection errors fail open.
- **Failure handling.** Each check has a 200 ms deadline. A circuit breaker shared
  by every middleware instance (package level, because Traefik rebuilds
  middlewares on every config reload, about 285 times an hour) stops calling
  AppSec for 30 s when at least half of the last 20 checks failed. Only breaker
  state changes are logged.
- **Kill switch.** `appsecEnabled` on the Middleware. Turning it off is a dynamic
  config reload; no Traefik pod restarts.
- **AppSec itself.** The crowdsec chart's `appsec` Deployment: 2 replicas spread
  across nodes, rolling updates, a PodDisruptionBudget of 1, explicit resources,
  the chart PodMonitor, and the trusted-IP whitelist mounted so its ban scenario
  never bans our own addresses. Rules are `crowdsecurity/appsec-virtual-patching`
  and `crowdsecurity/appsec-generic-rules`, in-band. The OWASP core rule set is
  not loaded.
- **Bans.** The collections' `appsec-vpatch` scenario is on from the first day.
  It bans an address for 4h, on every host, when two distinct rules match it
  within 60 s; a single rule hit is a single 403.
- **Trusted addresses** (home, London, the Meta corp ranges) are inspected like
  everyone else. They cannot be banned by AppSec, but a false positive still
  returns a 403 on that request.

## Considered options

| option | why not |
|---|---|
| Stock maxlerebourg plugin | Buffers up to 10 MB per request before the backend sees it, the behaviour behind the Immich incident. Setting its body limit to 0 disables body inspection entirely |
| Coraza as a Traefik WASM plugin | The same rule engine, as a second system with its own state. Reported memory and latency problems inside Traefik |
| Cloudflare managed rules | Only see proxied traffic; the direct :443 path skips them |
| Per-ingress middleware through `ingress_factory` | Fans out across about 128 stacks, and lock-contended stacks are skipped during apply. The entrypoint attachment plus a host list covers the catchall and hand-rolled ingresses too |
| A 7-day log-only phase | Offered and declined. A replay of the last 7 days of unique real request lines runs before blocking instead. 30 days was tried: the September crawl left 845k lines a day and two days alone held 470k unique requests, too many to replay in useful time |

## Consequences

- Body inspection is narrow on purpose. A payload inside a multipart upload, a
  chunked body or a gzip body is not inspected. URI, query and header inspection
  covers every request.
- Every non-skipped request makes one in-cluster HTTP call before reaching its
  backend. The `Overhead` field of the Traefik access log (total time minus
  backend time) measures it; it was about 4-5 ms before this change.
- The pre-launch replay (2026-10-02) sent the 782,025 unique method, host and
  URI combinations from 2026-09-25 to 2026-10-02 to AppSec; 407,413 were on
  inspected hosts. It blocked 20,461, and every block was a probe or an exploit
  attempt (`.env`, `.git`, `.svn`, WordPress webshells, PHP-CGI, ProxyShell,
  Jira); 933 of them were on real services. No false positive was found.
- The replay covers method, path and query only. The access log keeps
  no bodies, cookies or authorisation headers, so false positives in JSON or form
  bodies can first appear in production.
- Forgejo's ingress carries an `ingress_factory` Buffering middleware
  (`max_body_size = "5g"`), which already writes request bodies over 1 MiB to a
  temporary file on the Traefik pod. That predates this ADR, is unrelated to
  AppSec, and is left as it is.
- A plugin that fails to load under Yaegi disables every Traefik plugin on that
  pod. The plugin change is gated by `scripts/yaegi-plugin-gate` and ships dark
  (`appsecEnabled = false`) before AppSec is switched on.

## Where to look when something regresses

| symptom | first check |
|---|---|
| Uploads slow, or arrive twice | `Overhead` on the upload's access-log line; if it approaches the upload time the body was held. Confirm the host or the request type falls outside the body policy |
| 403s on a real app | `[crowdsec-bouncer] action=appsec-block` lines name host, path and status; add the host to `appsecSkipHosts` |
| Someone banned everywhere for 4h | `cscli alerts list -s crowdsecurity/appsec-vpatch` |
| Every site 404 on one Traefik pod after a deploy | "Plugins are disabled" in that pod's log: a Yaegi load failure |
| Requests slower everywhere | `Overhead` p99, `action=appsec-breaker` lines, AppSec pod health |
