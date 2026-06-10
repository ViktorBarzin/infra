# pfSense HAProxy for Mailserver — Runbook

Last updated: 2026-04-19 (Phase 6 complete)

## What & why

External mail traffic (SMTP/IMAP) requires **real client IP visibility** for
CrowdSec + Postfix rate-limiting. MetalLB cannot inject PROXY-protocol
headers (see [`mailserver-proxy-protocol.md`](./mailserver-proxy-protocol.md)),
so pfSense runs a small HAProxy that:

1. Listens on the pfSense VLAN20 IP (`10.0.20.1`) on all 4 mail ports,
2. Forwards each connection to a k8s node's NodePort with `send-proxy-v2`,
3. Injects PROXY v2 framing so Postfix/Dovecot see the original client IP,
4. TCP-checks every k8s worker via dedicated **non-PROXY healthcheck NodePorts**
   (30145/30146/30147 → pod stock 25/465/587 listeners, no PROXY required).
   This split path avoids the `smtpd_peer_hostaddr_to_sockaddr` fatal that
   used to fire on every PROXY-aware health probe and throttled real client
   connections.

Corresponding k8s-side setup (`stacks/mailserver/modules/mailserver/`):

- ConfigMap `mailserver-user-patches` → `user-patches.sh` appends 3 alt
  `master.cf` services to Postfix:
  - `:2525` postscreen (alt :25) with `postscreen_upstream_proxy_protocol=haproxy`
  - `:4465` smtpd (alt :465 SMTPS) with `smtpd_upstream_proxy_protocol=haproxy`
  - `:5587` smtpd (alt :587 submission) with `smtpd_upstream_proxy_protocol=haproxy`
- ConfigMap `mailserver.config` adds Dovecot `inet_listener imaps_proxy` on
  port 10993 with `haproxy = yes` and `haproxy_trusted_networks = 10.0.20.0/24`.
- Service `mailserver-proxy` (NodePort, ETP:Cluster) — 4 PROXY data ports +
  3 non-PROXY healthcheck ports:
  - Data (PROXY v2):
    - `port 25 → targetPort 2525 → nodePort 30125`
    - `port 465 → targetPort 4465 → nodePort 30126`
    - `port 587 → targetPort 5587 → nodePort 30127`
    - `port 993 → targetPort 10993 → nodePort 30128`
  - Healthcheck (no PROXY, stock SMTP/SMTPS/Submission listeners):
    - `port 2500 → targetPort 25 → nodePort 30145`  (smtp-check)
    - `port 4650 → targetPort 465 → nodePort 30146` (smtps-check)
    - `port 5870 → targetPort 587 → nodePort 30147` (sub-check)
- Service `mailserver` (ClusterIP) — unchanged stock ports 25/465/587/993
  for intra-cluster clients (Roundcube pod, `email-roundtrip-monitor`
  CronJob, book-search). These listeners are PROXY-free.

bd: `code-yiu`.

## Steady-state architecture

```
External mail (WAN) path — PROXY v2
┌─────────────────────────────────────────────────────────────────────┐
│  Client (real IP)                                                   │
│      │  SMTP/SMTPS/Sub/IMAPS                                        │
│      ▼                                                              │
│  pfSense WAN:{25,465,587,993}                                       │
│      │  NAT rdr → 10.0.20.1:{same}                                  │
│      ▼                                                              │
│  pfSense HAProxy  (mode tcp, 5 frontends, 6 backend pools)          │
│      │  data: send-proxy-v2 → :{30125..30128}  (PROXY-aware pod)   │
│      │  health: TCP-check    → :{30145..30147}  (no-PROXY pod)     │
│      │  inter 5000                                                  │
│      ▼                                                              │
│  k8s-node<1-4>:{30125..30128}   ← any node (ETP:Cluster)            │
│      │  kube-proxy SNAT (source IP lost on the wire)                │
│      ▼                                                              │
│  mailserver pod :{2525,4465,5587,10993}                             │
│      │  postscreen / smtpd / Dovecot parse PROXY v2 header          │
│      │  → real client IP recovered despite kube-proxy SNAT          │
│      ▼                                                              │
│  CrowdSec + Postfix / Dovecot see the true source IP ✓              │
└─────────────────────────────────────────────────────────────────────┘

Intra-cluster path — no PROXY
┌─────────────────────────────────────────────────────────────────────┐
│  Roundcube pod / email-roundtrip-monitor CronJob                    │
│      │  SMTP/IMAP                                                   │
│      ▼                                                              │
│  mailserver.mailserver.svc.cluster.local:{25,465,587,993}           │
│      │  ClusterIP — bypasses LoadBalancer/NodePort layer entirely   │
│      ▼                                                              │
│  mailserver pod stock :{25,465,587,993}  (PROXY-free)               │
└─────────────────────────────────────────────────────────────────────┘
```

## Validation

```sh
# All HAProxy frontends listening
ssh admin@10.0.20.1 'sockstat -l | grep haproxy'
# Expect: *:25, *:465, *:587, *:993, *:2525 (test port)

# All backend pools healthy
ssh admin@10.0.20.1 "echo 'show servers state' | socat /tmp/haproxy.socket stdio" \
  | awk 'NR>1 {print $3, $4, $6}'
# srv_op_state 2 = UP, 0 = DOWN

# Container listens on all 8 ports
kubectl exec -n mailserver -c docker-mailserver deployment/mailserver -- \
  ss -ltn | grep -E ':(25|2525|465|4465|587|5587|993|10993)\b'

# pf rdr points at pfSense (10.0.20.1), not <mailserver> alias
ssh admin@10.0.20.1 'pfctl -sn' | grep -E 'port = (25|submission|imaps|smtps)'

# E2E probe — Brevo → external MX :25 → IMAP fetch
kubectl create job --from=cronjob/email-roundtrip-monitor probe-test -n mailserver
kubectl wait --for=condition=complete --timeout=90s job/probe-test -n mailserver
kubectl logs job/probe-test -n mailserver | grep SUCCESS
kubectl delete job probe-test -n mailserver

# Real client IP in maillog post-delivery
kubectl logs -c docker-mailserver deployment/mailserver -n mailserver \
  | grep 'smtpd-proxy25.*CONNECT from' | tail -5
# Expect external source IPs (e.g., Brevo 77.32.148.x), NOT 10.0.20.x
```

## SNI-routed internal :443 frontend (2026-06-10)

`internal_https_443` binds `10.0.20.1:443` + `10.0.10.1:443` and completes
the internal port table of the mail front door so `mail.viktorbarzin.me`
(internal A record → 10.0.20.1) serves webmail too. Routing (Viktor's
design — route by what the client asked for):

| Client connects with | Routed to |
|---|---|
| SNI = `pfsense.viktorbarzin.{lan,me}` | webgui backend `127.0.0.1:8443` |
| any other SNI (hostnames, e.g. `mail.…`) | Traefik `10.0.20.203:443`, send-proxy-v2 |
| no SNI (bare IP — `https://10.0.20.1`) | webgui backend `127.0.0.1:8443` |

The **pfSense webGUI was moved to `:8443`** (config.xml
`system.webgui.port`, 2026-06-10) to free the 443 socket; admin access by
IP keeps working through the no-SNI route, and `:8443` remains a direct
fallback if HAProxy is down. The `pfsense.viktorbarzin.me` Traefik ingress
(stacks/reverse-proxy) targets `:8443` directly. Traefik leg mirrors the
IPv6 bridge: send-proxy-v2 (Traefik trusts 10.0.20.1), **no health check**
(PROXY-expecting receivers reject bare probes — gotcha above). All of this
is declared in `pfsense-haproxy-bootstrap.php` — re-run to reset.

## Bootstrap / restore from scratch

pfSense HAProxy config lives in `/cf/conf/config.xml` under
`<installedpackages><haproxy>`. That file is scp'd nightly to
`/mnt/backup/pfsense/config-YYYYMMDD.xml` by `scripts/daily-backup.sh`, then
synced to Synology. To rebuild from source of truth (git):

```sh
scp infra/scripts/pfsense-haproxy-bootstrap.php admin@10.0.20.1:/tmp/
ssh admin@10.0.20.1 'php /tmp/pfsense-haproxy-bootstrap.php'
```

The script is idempotent — re-runs reset the mailserver frontends + backends
to the declared state.

Expected output:
```
haproxy_check_and_run rc=OK
```

## Operations

### Change backend k8s node IPs / NodePorts

Edit `infra/scripts/pfsense-haproxy-bootstrap.php` — `$NODES` array + the
`build_pool()` port arguments. Re-run the bootstrap command above. Don't
hand-edit `/var/etc/haproxy/haproxy.cfg` — it is regenerated from XML on
every apply.

### Check health of backends

```sh
ssh admin@10.0.20.1 "echo 'show servers state' | socat /tmp/haproxy.socket stdio"
```
`srv_op_state=2` means UP, `0` means DOWN.

### View live HAProxy stats (WebUI)

`https://pfsense.viktorbarzin.me` → Services → HAProxy → Stats.

### Reload after config.xml edit

```sh
ssh admin@10.0.20.1 'pfSsh.php playback svc restart haproxy'
```

### Rollback (flip NAT back to MetalLB, post-Phase-6 only partial)

There is no Phase-6 rollback one-liner. Phase 6 removed the MetalLB
LoadBalancer 10.0.20.202 entirely, so un-flipping NAT now would send
traffic to a dead alias. To regress:

1. Re-add `metallb.io/loadBalancerIPs = "10.0.20.202"` + `type = "LoadBalancer"`
   + `external_traffic_policy = "Local"` to `kubernetes_service.mailserver`,
   apply.
2. Re-add the `mailserver` host alias in pfSense pointing at 10.0.20.202
   (Firewall → Aliases → Hosts).
3. Run `infra/scripts/pfsense-nat-mailserver-haproxy-unflip.php` on pfSense.

For rollback of just the NAT (Phase 4) without touching the Service, only
the third step is needed — but only meaningful BEFORE Phase 6.

### Restore from backup

pfSense config backup is a plain XML file:
```
/mnt/backup/pfsense/config-YYYYMMDD.xml        # sda host copy (1.1TB RAID1)
/volume1/Backup/Viki/pve-backup/pfsense/...    # Synology offsite
```

Full restore: pfSense WebUI → Diagnostics → Backup & Restore → Upload that
`config.xml`. The `<installedpackages><haproxy>` section is included.

## Phase history (bd code-yiu)

| Phase | Status | Description |
|---|---|---|
| 1a | ✅ commit `ef75c02f` | k8s alt :2525 listener + NodePort Service |
| 2  | ✅ 2026-04-19 | pfSense HAProxy pkg installed (`pfSense-pkg-haproxy-devel-0.63_2`, HAProxy 2.9-dev6) |
| 3  | ✅ commit `ba697b02` | HAProxy config persisted in pfSense XML (bootstrap script + this runbook) |
| 4+5| ✅ commit `9806d515` | 4-port alt listeners + HAProxy frontends for 25/465/587/993 + NAT flip |
| 6  | ✅ this commit | Mailserver Service downgraded LoadBalancer → ClusterIP; `10.0.20.202` released back to MetalLB pool; orphan `mailserver` pfSense alias removed; monitors retargeted |

## Known warts

- ~~HAProxy TCP health-check with `send-proxy-v2` generates `getpeername:
  Transport endpoint not connected` warnings on postscreen every check cycle.~~
  **Resolved 2026-05-05**: dedicated non-PROXY healthcheck NodePorts
  (30145/30146/30147 → stock pod 25/465/587) added; HAProxy now checks
  those, eliminating both the `getpeername` postscreen warnings and the
  `smtpd_peer_hostaddr_to_sockaddr: ... Servname not supported` fatals
  that were throttling smtpd respawns and causing ~50% client timeouts on
  the public 587 path. `inter` dropped 120000 → 5000 (fast failover, no
  log-spam concern). `option smtpchk` was tried but flapped against
  postscreen (multi-line greet + DNSBL silence + anti-pre-greet detection
  trip HAProxy's parser → L7RSP). Plain TCP check on the no-PROXY ports
  is sufficient.
- Frontend binds on all pfSense interfaces (`bind :25` instead of
  `10.0.20.1:25`). `<extaddr>` is set in XML but pfSense templates it
  port-only. Low concern in practice because WAN firewall rules plus the
  NAT rdr gate external access; internal VLAN clients SHOULD be able to
  reach HAProxy on any pfSense-local IP.
- k8s-node5 doesn't exist — cluster has master + 4 workers. Backend pool
  capped at 4 servers.
- Postscreen still logs `improper command pipelining` for legitimate
  clients that send `EHLO\r\nQUIT\r\n` as a single TCP write. This is
  unchanged pre/post-migration — postscreen's anti-bot heuristic.
