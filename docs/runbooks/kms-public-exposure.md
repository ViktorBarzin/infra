# Runbook: KMS public exposure (vlmcs.viktorbarzin.me:1688)

`vlmcs.viktorbarzin.me:1688/TCP` is intentionally open to the internet so any
visitor can activate Volume License Microsoft products. The webpage at
`https://kms.viktorbarzin.me/` documents how to use it.

**Two hostnames, on purpose** (do not merge them):

- `kms.viktorbarzin.me` — the **website** (Traefik). Serves the docs and the
  `/scripts/*.ps1` activators. Internally resolves to the Traefik LB
  (`10.0.20.203`), which has **no** `:1688` listener.
- `vlmcs.viktorbarzin.me` — the **KMS endpoint** (vlmcsd). A-only (no AAAA —
  the IPv6 tunnel doesn't forward 1688). Resolves to `10.0.20.202` on the LAN
  (Technitium split-horizon, set via API — `cloudflare_record.vlmcs` in
  `stacks/kms` owns the public A) and to `176.12.22.76` on the internet
  (Cloudflare → pfSense WAN NAT :1688). Every `slmgr` / `ospp` command on the
  page points here.

Pointing a client at `kms.viktorbarzin.me:1688` fails from the LAN with "KMS
server cannot be reached" — that name is the website, not the KMS server.

This runbook covers operations on the public exposure: where to find logs,
how to tune the rate limit, how to revoke if abused.

## Architecture

- **K8s service**: `windows-kms` in namespace `kms`, MetalLB **dedicated**
  LB IP `10.0.20.202:1688`. ETP=Local, so vlmcsd sees real WAN client IPs
  in its log (pfSense WAN forwards do DNAT-only, no SNAT; ETP=Local skips
  the kube-proxy SNAT too). Same pattern mailserver used pre-2026-04-19.
  Sharing `10.0.20.200` isn't an option — all 10 services there are
  ETP=Cluster and MetalLB requires a single ETP per shared IP.
- **Native DNS auto-discovery for LAN clients**: any Windows client with
  DNS suffix `viktorbarzin.lan` activates with zero config — Windows
  queries `_vlmcs._tcp.viktorbarzin.lan` SRV by default, the SRV target
  resolves to `vlmcs.viktorbarzin.lan` → `10.0.20.202`, and `slmgr /ato`
  succeeds. Records:
  - `_vlmcs._tcp.viktorbarzin.lan` SRV 0 0 1688 vlmcs.viktorbarzin.lan
  - `vlmcs.viktorbarzin.lan` A `10.0.20.202`
  - `kms.viktorbarzin.lan` A `10.0.20.200` (Traefik — for the user-facing
    website at `https://kms.viktorbarzin.lan/`; **not** the KMS server)
  Manual override (e.g., for clients without the suffix or for clients
  on the public internet): `slmgr /skms vlmcs.viktorbarzin.me:1688` (works
  LAN + WAN) or `slmgr /skms 10.0.20.202:1688` (LAN, direct). Do **not** use
  `kms.viktorbarzin.me:1688` — that name is the website (Traefik), not the
  KMS server. To revert a manually-overridden client back to auto-discovery:
  `slmgr /ckms`.
- **Pod fluidity**: deployment has `replicas=1` (notifier dedup state is
  per-pod) with no node affinity. TCP readiness/liveness probes on 1688
  gate Pod Ready on the listener actually being up, so MetalLB only
  advertises `10.0.20.202` from a node where vlmcsd is serving.
- **pfSense WAN forward**: `WAN TCP/1688 → k8s_kms_lb:1688`
  (alias = `10.0.20.202`, dedicated to KMS). Description: `KMS public —
  kms.viktorbarzin.me`. Other forwards using `k8s_shared_lb` (WireGuard,
  HTTPS, shadowsocks, smtps, etc.) are unaffected.
- **Filter rule** on the WAN interface, TCP/1688 destination
  `<k8s_kms_lb>`, with state-table per-source caps:
  - `max-src-conn 50` — concurrent connections per source IP
  - `max-src-conn-rate 10/60` — 10 new connections per 60 seconds per
    source
  - `overload <virusprot>` flush — sources that exceed either cap get added
    to pfSense's stock `virusprot` pf table and have their existing states
    flushed. (`virusprot` is the only table pfSense's filter generator
    targets for `overload`; see `/etc/inc/filter.inc`. Don't try to point
    it at a custom table — the schema doesn't expose that knob.)
- **Probe filter in slack-notifier**: a bare TCP open/close (no
  Application/Activation block from vlmcsd) is treated as a probe — Uptime
  Kuma's port-type monitor on `windows-kms.kms.svc:1688` and the kubelet
  readiness/liveness probes both hit this path. Probes increment
  `kms_connection_probes_total{source}` (`source` ∈ `internal_pod`,
  `cluster_node`, `external`) and log to stdout, but never post to Slack.
  Real activations still post.
- **Website `/scripts` + `/keys.json` carve-out**: the website is Anubis-fronted
  (PoW challenge). `/scripts/*` and `/keys.json` are carved out to the bare
  nginx backend (`module.ingress_scripts` in `stacks/kms`, `ingress_path`)
  because PowerShell `iwr | iex` / `ConvertFrom-Json` are non-JS clients that
  can't solve the PoW — without the carve-out they'd download the Anubis
  challenge HTML and choke. Everything else stays behind Anubis. Verify:
  `curl -A curl https://kms.viktorbarzin.me/scripts/setup-kms.ps1` and
  `.../keys.json` both return real content (not "Making sure you're not a bot!").
- **Auto-key selection**: the scripts no longer require the user to pick a GVLK.
  `/keys.json` is `data/products.yaml` rendered to JSON (Hugo KEYS output format).
  When no Volume License key is installed, `setup-kms.ps1` / `kms-bootstrap.ps1`
  detect the edition — Windows via registry `EditionID` (+ `CurrentBuildNumber`
  for LTSC/Server, which share an EditionID across releases), Office via the
  Click-to-Run `ProductReleaseIds` — fetch `/keys.json`, and `slmgr /ipk` /
  `ospp /inpkey` the matching key before activating. Only fires when not already
  licensed (never clobbers a working retail key). Azure-Edition server SKUs are
  intentionally unmapped (they collide with Datacenter and KMS may fail there).
- **Edition switch (kms-bootstrap.ps1, consent-gated)**: when the installed
  product *can't* KMS-activate (Windows Home/retail; no VL Office), the bootstrap
  shows the consequences and asks before changing anything (default No). Windows
  → `changepk.exe /ProductKey <target GVLK>` (default Pro; `$env:KMS_EDITION`
  overrides) — in-place edition UPGRADE, **needs a reboot then re-run**, one-way
  (no in-place downgrade). Office → slim ODT `setup.exe /configure` to a VL
  product (default ProPlus2024Volume; `$env:KMS_OFFICE_PRODUCT` overrides) — ~3 GB
  download, closes Office. If an INCOMPATIBLE Click-to-Run Office is installed
  (retail/M365 — `ProductReleaseIds` not ending in `Volume`), it's named in the
  prompt and **uninstalled first** via ODT `<Remove>` of just those products (VL
  products of other families are kept), then the VL product installs. The ODT run
  is one shared `Invoke-Odt` for both `<Add>` and `<Remove>`. **Removing the bundled
  consumer Office leaves a pending reboot**, so a VL install in the same run — or a
  re-run before rebooting — fails with `setup.exe` exit **1603**. Two guards: a
  hard-reboot (CBS/WU) gate before the ~3 GB download, and a reboot-aware 1603
  message telling the user to reboot + re-run (idempotent — the incompatible Office
  is already gone). `Invoke-Odt` checks the setup.exe exit code and on failure
  captures the C2R log from `%TEMP%` into telemetry; `Wait-OfficeInstalled` polls
  on-disk state (ospp.vbs + ProductReleaseIds) because `setup.exe` can return before
  the C2R install finishes. Non-interactive runs only proceed with an explicit env
  override. setup-kms.ps1 stays minimal and points non-VL editions at the bootstrap.
  NOTE: real-hardware status (2026-06-01) — the incompatible-uninstall path DID run
  on a real M365/Office-Home box (`O365HomePremRetail` removed cleanly); the VL
  install then needs a reboot first (hit 1603, now guided). changepk edition-switch
  remains untested (no Home test box; the Pro test VM can't be switched reversibly).
- **Self-hosted ODT bootstrapper**: the Office reinstall path fetches the Office
  Deployment Tool from `https://kms.viktorbarzin.me/scripts/odt-setup.exe` (a
  committed copy in `kms-website/static/scripts/`), NOT from Microsoft —
  `download.microsoft.com`'s ODT URL is build-numbered and rotates every release
  (the old hardcoded one 404'd). `$env:KMS_ODT_URL` overrides. The bootstrapper
  self-updates the Office payload, so refresh the committed copy only occasionally.
- **Client telemetry → Loki**: the scripts POST a small ANONYMOUS diagnostics
  event per run to `https://kms.viktorbarzin.me/diag` (action, outcome, error +
  exit codes, EditionID/build/locale, detected Office products, script version;
  NO hostname/user/keys). Fire-and-forget (3s, swallowed) — never affects
  activation. `$env:KMS_NO_TELEMETRY=1` opts out; `$env:KMS_DIAG_URL` overrides.
  Collector: standalone `kms-diag` Deployment (`stacks/kms`, python stdlib HTTP
  on :9102) reachable via the `/diag` ingress carve-out (bypasses Anubis like
  `/scripts`); it prints `KMSDIAG <json>` to stdout → Loki. Query in Grafana:
  `{namespace="kms",pod=~"kms-diag.*"} |= "KMSDIAG"`. Disclosed in the site FAQ.

## Where the logs are

### vlmcsd (kms namespace, k8s)

```bash
# Live tail
kubectl logs -n kms -l app=kms-service -c windows-kms --tail=50 -f

# All activations in the running pod
kubectl logs -n kms -l app=kms-service -c windows-kms | grep "Incoming KMS request"
```

Source IPs from the WAN are real client IPs (pfSense DNAT-only + ETP=Local
preserve them through the chain). LAN clients hitting the LB IP directly
appear as their own IP. Pod-source probes (Uptime Kuma) appear as a Calico
pod IP in `10.10.0.0/16`. Kubelet readiness/liveness probes appear as the
hosting node IP in `10.0.20.0/24`.

### Slack notifier (kms namespace, k8s)

```bash
kubectl logs -n kms -l app=kms-service -c slack-notifier --tail=50 -f
```

Posts to `#alerts`, dedup window 1h per (source-IP, product). Activations
also increment the Prometheus counter `kms_activations_total{product,status}`
exposed on the same pod at `:9101/metrics` (scraped by the cluster-wide
`kubernetes-pods` job; query via Prometheus or Grafana directly).

Probe-only TCP connections (open+close, no KMS RPC) are silently filtered
out of Slack and counted in `kms_connection_probes_total{source}`. Useful
queries:
```promql
# Probe rate by source
rate(kms_connection_probes_total[5m])
# Probes from the public WAN (a non-zero rate here means real port-scans
# are reaching us, not just internal monitoring)
rate(kms_connection_probes_total{source="external"}[5m])
```

### pfSense — virusprot table and filter hits

```bash
# SSH to 10.0.20.1 as root
pfctl -t virusprot -T show          # who's currently in the virusprot table
pfctl -t virusprot -T expire 86400  # boot anyone added more than 24h ago
pfctl -t virusprot -T flush         # nuke the entire table

# Filter rule hit counts (find the KMS public rule, look at Evaluations / States)
pfctl -sr -v | grep -A 4 1688

# State table — current TCP/1688 connections, per source
pfctl -ss | grep ':1688 '
```

## Tightening or loosening the rate limit

The filter rule is configured via the pfSense web UI
(`Firewall → Rules → WAN`, look for the `KMS public — kms.viktorbarzin.me`
rule) under **Advanced Options → "Maximum new connections per source per
seconds"** and **"Maximum state entries per source"**.

- **Default**: `max-src-conn 50`, `max-src-conn-rate 10/60`
- To **tighten** (suspected abuse): drop to `max-src-conn 10`,
  `max-src-conn-rate 3/60`. Flush state and existing virusprot afterwards
  (`pfctl -k 0.0.0.0/0 -K 0.0.0.0/0` is overkill — just save+apply the
  rule, pfSense reloads pf and existing virusprot stay blocked).
- To **loosen** (legitimate users blocked): bump to
  `max-src-conn-rate 30/60`. The `virusprot` table flush still applies on
  overload; reduce its lifetime via
  `Firewall → Advanced → State Timeouts` if entries linger.

The `overload` table entry survives pf reloads. Running
`pfctl -t virusprot -T flush` after a tuning change clears the slate.

## Revoking the public exposure

If the activation surface needs to come down (abuse, legal, audit):

1. **pfSense web UI** → `Firewall → NAT → Port Forward` → find
   `WAN TCP/1688 → k8s_kms_lb` → **delete** (or disable). Apply.
2. **pfSense web UI** → `Firewall → Rules → WAN` → find
   `KMS public — kms.viktorbarzin.me` → **delete** (or disable). Apply.
3. Verify externally: from a phone tether, `nc -zw3 kms.viktorbarzin.me 1688`
   should now fail.

The k8s service stays reachable on the LAN
(`10.0.20.202:1688` directly, and the website at `kms.viktorbarzin.lan`
via Traefik on `10.0.20.200:443`) — only the WAN port-forward is removed.

To put it back, recreate the NAT rule (target alias `k8s_kms_lb`,
port `1688`) and the filter rule with the same per-source caps. The alias
itself is independent of any forward and persists across delete/restore.

## Related

- Stack: `stacks/kms/` (Terraform; deployment, MetalLB Service, ingress,
  ExternalSecret for the Slack webhook)
- Webpage source: `kms-website/` repo (Hugo + nginx; Woodpecker builds +
  pushes to forgejo, then `kubectl set image deployment/kms-web-page`)
- Networking architecture footnote:
  `docs/architecture/networking.md` § "MetalLB & Load Balancing"
