# t3 drop attribution — "is it infra or my network?"

When a t3 user reports "disconnects, then self-recovers after a few seconds",
that is the t3 **client watchdog**: the browser heartbeats every 10s and force-
reconnects after >20s without a response. Any stall or break anywhere on
browser → Cloudflare → tunnel → Traefik → t3-dispatch → `t3 serve` produces
the identical symptom. This runbook attributes a drop to a segment in minutes.

## 1. Check the probe (first stop)

The in-cluster `t3-probe` (stacks/t3code, scrape job `t3-probe`) holds three
permanent legs that differ only in path segment:

| leg | path under test | drop means |
|---|---|---|
| `cloudflare` | WAN → CF edge → tunnel → cloudflared → Traefik → dispatch | Cloudflare/WAN segment |
| `internal` | Traefik LB (10.0.20.203) → dispatch (no Cloudflare) | Traefik / dispatch / devvm network |
| `t3serve` | HTTP straight to devvm:3773 (`t3 serve` process) | the serve process itself (event-loop stall) |

Prometheus queries:

```promql
increase(t3probe_disconnects_total[1h])          # drops per leg+reason
t3probe_connected                                # current state per leg
histogram_quantile(0.99, rate(t3probe_rtt_seconds_bucket{leg="t3serve"}[15m]))
```

Attribution table:

- `cloudflare` drops, `internal` clean → Cloudflare edge / QUIC tunnel / WAN.
- both WS legs drop together → Traefik, dispatch, or devvm reachability.
- `t3serve` RTT spikes / timeouts → the user's `t3 serve` stalled (see §3).
- **all legs clean while the user dropped → their last mile / device. Infra
  is exonerated, with data.**

Alerts `T3ProbeLegDown` / `T3ProbeDropBurst` fire on sustained breakage.

## 1b. Connection logs in Loki (passive, always-on — catch a real drop)

Three layers of the real path log every t3 `/ws` connection to Loki, so a drop
the user actually experienced is attributable after the fact without a repro. A
drop is **a short-lived `/ws` connection** (a healthy session holds one socket
for hours); the client's 20s heartbeat watchdog reconnects on any break.

| Layer | Loki stream | What it tells you |
|---|---|---|
| Traefik | `{job="traefik"}` ⟶ filter `t3code-t3` + `GET /ws` | per-connection **duration** (trailing `…ms`) + edge (cloudflared pod) IP |
| cloudflared | `{job="cloudflared"}` ⟶ filter `t3.viktorbarzin.me/ws` | CF-tunnel-side close (`ended abruptly: context canceled` = browser/CF side hung up) |
| t3-dispatch | `{job="devvm-journal",unit="t3-dispatch.service"} \|= "ws close"` | **`dur_ms` + `cause`** — the discriminator below |

`cause` on the dispatch `ws close` line:
- **`downstream_closed`** — client / Cloudflare / Traefik tore the socket down
  (`context canceled`). Short `dur_ms` = client watchdog firing → a **last-mile /
  network-quality** drop (or CF/tunnel blip); t3-serve was fine.
- **`upstream_closed`** — the user's `t3 serve` closed/reset (reset by peer / EOF
  / refused) → t3-serve stall/restart/OOM.
- **`graceful`** — clean close from either side (e.g. the client watchdog's
  `disconnect()` after a >20s heartbeat gap). Cross-check `dur_ms`: a ~20s+
  graceful close with no devvm pressure spike (§3) is a heartbeat-timeout whose
  stall was NOT on devvm → last-mile.

Triage query (Grafana Explore → Loki) — every short t3 socket in a window:

```logql
{job="devvm-journal", unit="t3-dispatch.service"} |= "ws close"
  | regexp `dur_ms=(?P<dur>[0-9]+) cause=(?P<cause>\S+)` | dur < 120000
```

Line the timestamp up against `{job="traefik"}` (duration + edge IP) and
`{job="cloudflared"}` (CF-side close) for the same second to localise the layer.
devvm journald (incl. `t3-serve@<user>`) ships via `scripts/devvm-promtail.*`.

## 2. Server-side log recipe (per-event forensics)

On devvm (timestamps in UTC):

```bash
# dispatch view — error class identifies which side died:
#   "context canceled"                      = front/client side tore down
#   "connection reset by peer 127.0.0.1:PORT" = that user's serve closed
#   "connection refused"                    = that user's serve was down
journalctl -u t3-dispatch --since "1 hour ago" | grep "proxy error"

# mass-cancel bursts (many same-second cancels = shared-segment break):
journalctl -u t3-dispatch --since "6 hours ago" \
  | grep -oE '^.* [0-9:]+ http: proxy error: context canceled' \
  | awk '{print $6}' | sort | uniq -c | awk '$1>=5'

# serve-side starvation markers (git taking >5s = devvm frozen):
journalctl -u t3-serve@<user> --since "6 hours ago" | grep "timed out"

# tunnel-side: cloudflared pod restarts + per-connection events
kubectl -n cloudflared get pods
kubectl -n cloudflared logs <pod> --since=6h | grep -E "ERR|reconnect"
```

## 3. devvm pressure correlation

devvm node_exporter is scraped as job `devvm` (since 2026-06-10). The known
high-frequency drop mechanism is **memory+IO pressure on devvm**: agent
processes live inside `t3-serve@<user>`'s cgroup; a runaway agent swap-thrashes
the spinning root disk and freezes the box in multi-10s windows — every
connected client's watchdog fires at once (2026-06-10: a 10.8G agent → global
OOM → 8.5min hard outage).

```promql
rate(node_pressure_io_stalled_seconds_total{instance="devvm"}[5m])
rate(node_pressure_memory_stalled_seconds_total{instance="devvm"}[5m])
node_memory_SwapFree_bytes{instance="devvm"}
```

Guardrails in place (2026-06-10, hardened 2026-07-02; `scripts/t3-serve@.service`):
per-unit `MemoryMax=16G`, `MemorySwapMax=0`, `OOMPolicy=continue`, and
`MemoryHigh=infinity` — deliberately NO soft throttle band. With swap=0, a hog
plateauing between high and max never OOMs and the kernel high-throttle stalls
the whole unit: a 12.3G agent `ugrep` livelocked t3-serve@wizard for ~50min on
2026-07-02 (signature: probe `t3serve` leg `Connection reset by peer`, dispatch
`proxy error: context canceled`, server D-state in `mem_cgroup_handle_over_high`,
`ss` backlog on the serve port; fix: SIGKILL the hog — the D-state is killable).
A runaway agent now OOMs alone at 16G inside the cgroup instead of throttling
the WS server with it. Post-mortem addendum:
`docs/post-mortems/2026-06-22-devvm-mem-io-overload-containment.md`.

## 4. Known root causes (2026-06-10 investigation)

1. **devvm memory/IO storms** (high-frequency mechanism) — §3.
2. **cloudflared in-place autoupdate** — fixed: `--no-autoupdate`
   (stacks/cloudflared). Before the fix every CF release exited all 3 pods
   (code 11), severing all tunnel WebSockets.
3. **QUIC tunnel churn** (~1–2/day, "no recent network activity") — inherent;
   visible as `cloudflare`-leg-only blips.
4. **t3 nightly autoupdate** — pinned after the 2026-06-09 outage, see
   `docs/post-mortems/2026-06-09-t3-nightly-autoupdate-auth-outage.md`.
