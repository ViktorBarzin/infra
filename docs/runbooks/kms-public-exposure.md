# Runbook: KMS public exposure (kms.viktorbarzin.me:1688)

`kms.viktorbarzin.me:1688/TCP` is intentionally open to the internet so any
visitor can activate Volume License Microsoft products. The webpage at
`https://kms.viktorbarzin.me/` documents how to use it.

This runbook covers operations on the public exposure: where to find logs,
how to tune the rate limit, how to revoke if abused.

## Architecture

- **K8s service**: `windows-kms` in namespace `kms`, MetalLB shared LB IP
  `10.0.20.200:1688`. ETP=Cluster, so client IPs in vlmcsd logs are SNAT'd
  k8s node IPs (not real-world client IPs). Trade-off accepted —
  preserving real client IPs would require a dedicated MetalLB IP with
  ETP=Local or a PROXY-protocol bounce; vlmcsd doesn't speak PROXY-v2.
- **pfSense WAN forward**: `WAN TCP/1688 → k8s_shared_lb:1688`
  (alias = `10.0.20.200`). Description: `KMS public — kms.viktorbarzin.me`.
- **Filter rule** on the WAN interface, TCP/1688, with state-table
  per-source caps:
  - `max-src-conn 50` — concurrent connections per source IP
  - `max-src-conn-rate 10/60` — 10 new connections per 60 seconds per
    source
  - `overload <virusprot>` flush — sources that exceed either cap get added
    to pfSense's stock `virusprot` pf table and have their existing states
    flushed. (`virusprot` is the only table pfSense's filter generator
    targets for `overload`; see `/etc/inc/filter.inc`. Don't try to point
    it at a custom table — the schema doesn't expose that knob.)

## Where the logs are

### vlmcsd (kms namespace, k8s)

```bash
# Live tail
kubectl logs -n kms -l app=kms-service -c windows-kms --tail=50 -f

# All activations in the running pod
kubectl logs -n kms -l app=kms-service -c windows-kms | grep "Incoming KMS request"
```

Source IPs in this log are the SNAT'd node IPs because the LB Service uses
ETP=Cluster on a shared MetalLB IP. Don't expect real WAN client IPs here.

### Slack notifier (kms namespace, k8s)

```bash
kubectl logs -n kms -l app=kms-service -c slack-notifier --tail=50 -f
```

Posts to `#alerts`, dedup window 1h per (source-IP, product). Activations
also increment the Prometheus counter `kms_activations_total{product,status}`
exposed on the same pod at `:9101/metrics` (scraped by the cluster-wide
`kubernetes-pods` job; query via Prometheus or Grafana directly).

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
   `WAN TCP/1688 → k8s_shared_lb` → **delete** (or disable). Apply.
2. **pfSense web UI** → `Firewall → Rules → WAN` → find
   `KMS public — kms.viktorbarzin.me` → **delete** (or disable). Apply.
3. Verify externally: from a phone tether, `nc -zw3 kms.viktorbarzin.me 1688`
   should now fail.

The k8s service stays reachable on the LAN
(`10.0.20.200:1688` and the internal `kms.viktorbarzin.lan` ingress for
the webpage) — only the WAN port-forward is removed.

To put it back, recreate the NAT rule (target alias `k8s_shared_lb`,
port `1688`) and the filter rule with the same per-source caps.

## Related

- Stack: `stacks/kms/` (Terraform; deployment, MetalLB Service, ingress,
  ExternalSecret for the Slack webhook)
- Webpage source: `kms-website/` repo (Hugo + nginx, deployed via Drone CI)
- Networking architecture footnote:
  `docs/architecture/networking.md` § "MetalLB & Load Balancing"
