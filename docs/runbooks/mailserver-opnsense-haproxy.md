# OPNsense HAProxy for Mailserver: runbook

> Rewritten for OPNsense at the 2026-11-10 cutover; HAProxy ran on pfSense before.

## What and why

External mail traffic (SMTP/IMAP) requires **real client IP visibility** for
CrowdSec + Postfix rate-limiting. MetalLB cannot inject PROXY-protocol
headers (see [`mailserver-proxy-protocol.md`](./mailserver-proxy-protocol.md)),
so the edge firewall runs a small HAProxy (OPNsense plugin `os-haproxy`) that:

1. Listens on the firewall's VLAN20 IP (`10.0.20.1`) on all 4 mail ports,
2. Forwards each connection to a k8s node's NodePort with `send-proxy-v2`,
3. Injects PROXY v2 framing so Postfix/Dovecot see the original client IP,
4. TCP-checks every k8s worker via dedicated **non-PROXY healthcheck NodePorts**
   (30145/30146/30147 → pod stock 25/465/587 listeners, no PROXY required).
   This split path avoids the `smtpd_peer_hostaddr_to_sockaddr` fatal that
   used to fire on every PROXY-aware health probe and throttled real client
   connections. The IMAPS pool has no separate check port in `haproxy.yml`.

Corresponding k8s-side setup (`stacks/mailserver/modules/mailserver/`):

- ConfigMap `mailserver-user-patches` → `user-patches.sh` appends 3 alt
  `master.cf` services to Postfix:
  - `:2525` postscreen (alt :25) with `postscreen_upstream_proxy_protocol=haproxy`
  - `:4465` smtpd (alt :465 SMTPS) with `smtpd_upstream_proxy_protocol=haproxy`
  - `:5587` smtpd (alt :587 submission) with `smtpd_upstream_proxy_protocol=haproxy`
- ConfigMap `mailserver.config` adds Dovecot `inet_listener imaps_proxy` on
  port 10993 with `haproxy = yes` and `haproxy_trusted_networks = 10.0.20.0/24`.
- Service `mailserver-proxy` (NodePort, ETP:Cluster): 4 PROXY data ports +
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
- Service `mailserver` (ClusterIP): unchanged stock ports 25/465/587/993
  for intra-cluster clients (Roundcube pod, `email-roundtrip-monitor`
  CronJob, book-search). These listeners are PROXY-free.

bd: `code-yiu`.

## Steady-state architecture

```
External mail (WAN) path: PROXY v2
┌─────────────────────────────────────────────────────────────────────┐
│  Client (real IP)                                                   │
│      │  SMTP/SMTPS/Sub/IMAPS                                        │
│      ▼                                                              │
│  OPNsense WAN:{25,465,587,993}                                      │
│      │  NAT rdr → 10.0.20.1:{same}                                  │
│      ▼                                                              │
│  OPNsense HAProxy  (mode tcp, 5 frontends, 6 backend pools)         │
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
│  CrowdSec + Postfix / Dovecot see the true source IP                │
└─────────────────────────────────────────────────────────────────────┘

Intra-cluster path: no PROXY
┌─────────────────────────────────────────────────────────────────────┐
│  Roundcube pod / email-roundtrip-monitor CronJob                    │
│      │  SMTP/IMAP                                                   │
│      ▼                                                              │
│  mailserver.mailserver.svc.cluster.local:{25,465,587,993}           │
│      │  ClusterIP: bypasses LoadBalancer/NodePort layer entirely    │
│      ▼                                                              │
│  mailserver pod stock :{25,465,587,993}  (PROXY-free)               │
└─────────────────────────────────────────────────────────────────────┘
```

IPv6 mail does not pass through HAProxy: OPNsense forwards it on the HE
tunnel interface from `2001:470:5a7f:20::203` to `mailserver-v6`
(`2001:470:5a7f:20::204`) in the cluster (`nat_port_forwards.yml`, the
`k8s-ipv6: mail ...` entries); see `docs/architecture/networking.md` →
"IPv6 Ingress (native, cluster dual-stack)".

## Config

Config is code. Never change HAProxy in the OPNsense GUI.

| What | Where |
|---|---|
| Frontends, backends, servers, ACLs | `playbooks/files/opnsense/haproxy.yml`, applied by `playbooks/tasks/opnsense/haproxy.yml` |
| WAN port forwards 25/465/587/993 → `10.0.20.1` | `playbooks/files/opnsense/nat_port_forwards.yml` |
| Generated config on the box | `/usr/local/etc/haproxy.conf` (regenerated on every apply; do not hand-edit) |
| Admin socket | `/var/run/haproxy.socket` |
| Boot hook | `/usr/local/etc/rc.syshook.d/start/99-haproxy-ensure` starts HAProxy at the end of boot if the early start failed |

Bind addresses in `haproxy.yml` are placeholders (`{{ fw.opt1 }}`,
`{{ fw.lan }}`) that the playbook fills per profile. Server names on the box
are `<backend>_<server>` (for example `mailserver_nodes_smtp_k8s-node1`),
because OPNsense server names are global.

```sh
cd ~/code/infra
presence claim host:opnsense --purpose "opnsense haproxy"
ansible-playbook -i playbooks/inventory.ini playbooks/opnsense.yml -e opnsense_allow_production=true --tags haproxy --check --diff
ansible-playbook -i playbooks/inventory.ini playbooks/opnsense.yml -e opnsense_allow_production=true --tags haproxy
scripts/opnsense-verify --host 10.0.10.1 --profile production
```

The tasks prune objects that are not in the YAML, so a run resets the pools
and frontends to the declared state. `--check --diff` lists what would change.

## Validation

```sh
# All HAProxy frontends listening (root's shell on the box is csh)
ssh root@10.0.10.1 'sockstat -l -4 | grep haproxy'
# Expect: 10.0.20.1:{25,465,587,993,443} and 10.0.10.1:443

# All backend pools healthy: backend, server, srv_op_state (2 = UP, 0 = DOWN)
ssh root@10.0.10.1 "echo 'show servers state' | nc -U /var/run/haproxy.socket" \
  | awk 'NR>2 {print $2, $4, $6}'

# Container listens on all 8 ports
kubectl exec -n mailserver -c docker-mailserver deployment/mailserver -- \
  ss -ltn | grep -E ':(25|2525|465|4465|587|5587|993|10993)\b'

# pf rdr points at the firewall (10.0.20.1), not a <mailserver> alias
ssh root@10.0.10.1 'pfctl -sn' | grep -E 'port = (25|smtp|submission|imaps|smtps)'

# E2E probe: Brevo → external MX :25 → IMAP fetch
kubectl create job --from=cronjob/email-roundtrip-monitor probe-test -n mailserver
kubectl wait --for=condition=complete --timeout=90s job/probe-test -n mailserver
kubectl logs job/probe-test -n mailserver | grep SUCCESS
kubectl delete job probe-test -n mailserver

# Real client IP in maillog post-delivery
kubectl logs -c docker-mailserver deployment/mailserver -n mailserver \
  | grep 'smtpd-proxy25.*CONNECT from' | tail -5
# Expect external source IPs (e.g., Brevo 77.32.148.x), NOT 10.0.20.x
```

Testing inbound SMTP from outside: mx2 (Oracle) cannot, Oracle blocks outbound
port 25. Use mladost3-openwrt: `(sleep 4; echo QUIT) | nc 176.12.22.76 25`.

## SNI-routed internal :443 frontend (2026-06-10)

`internal_https_443` binds `10.0.20.1:443` + `10.0.10.1:443` and completes
the internal port table of the mail front door so `mail.viktorbarzin.me`
(internal A record → 10.0.20.1) serves webmail too. Routing (Viktor's
design: route by what the client asked for):

| Client connects with | Routed to |
|---|---|
| SNI = `opnsense.viktorbarzin.{lan,me}` or `pfsense.viktorbarzin.{lan,me}` | webgui backend `127.0.0.1:8443` |
| any other SNI (hostnames, e.g. `mail.…`) | Traefik `10.0.20.203:443`, send-proxy-v2 |
| no SNI (bare IP, `https://10.0.20.1`) | webgui backend `127.0.0.1:8443` |

The OPNsense GUI listens on **`:8443`** (`misc.yml` `webgui.port`), as
pfSense's did from 2026-06-10, to leave the 443 socket to HAProxy. Admin
access by IP works through the no-SNI route, and `https://10.0.10.1:8443`
is a direct fallback if HAProxy is down. The `opnsense.viktorbarzin.me`
Traefik ingress (`stacks/reverse-proxy`, behind Authentik) targets
`10.0.20.1:8443` directly; `pfsense.viktorbarzin.me` is retired. Traefik leg:
send-proxy-v2 (Traefik trusts 10.0.20.1), **no health check**
(PROXY-expecting receivers reject bare probes). All of this is declared in
`haproxy.yml`.

## Operations

### Change backend k8s node IPs / NodePorts

Edit the `servers` lists (address, `port`, `check_port`) of the backends in
`playbooks/files/opnsense/haproxy.yml` and run the playbook with
`--tags haproxy`.

### Check health of backends

```sh
ssh root@10.0.10.1 "echo 'show servers state' | nc -U /var/run/haproxy.socket"
```
`srv_op_state=2` means UP, `0` means DOWN.

### Restart

```sh
ssh root@10.0.10.1 'configctl haproxy restart'
```

`configctl haproxy start` started it on the first boot after the cutover,
when the early boot start had failed (`docs/runbooks/opnsense.md`, Gotchas).
The boot hook now does the same automatically.

### Rollback (flip NAT back to MetalLB, post-Phase-6 only partial)

There is no Phase-6 rollback one-liner. Phase 6 removed the MetalLB
LoadBalancer 10.0.20.202 entirely, so un-flipping NAT now would send
traffic to a dead address. To regress:

1. Re-add `metallb.io/loadBalancerIPs = "10.0.20.202"` + `type = "LoadBalancer"`
   + `external_traffic_policy = "Local"` to `kubernetes_service.mailserver`,
   apply.
2. Add a `mailserver` host alias for 10.0.20.202 to
   `playbooks/files/opnsense/aliases.yml`.
3. Point the four mail forwards in `nat_port_forwards.yml` at that alias
   instead of `{{ fw.opt1 }}`, then run the playbook with
   `--tags aliases,nat` (first with `--check --diff`).

Note that 10.0.20.202 is now the dedicated KMS address (`k8s_kms_lb`,
`docs/runbooks/kms-public-exposure.md`), so step 1 needs a different free
address today.

History: on pfSense step 3 was `scripts/pfsense-nat-mailserver-haproxy-unflip.php`.
That script and `pfsense-haproxy-bootstrap.php` / `playbooks/pfsense-haproxy.yml`
do not apply to OPNsense.

### Restore from backup

The source of truth is `haproxy.yml` in git: re-running the playbook rebuilds
the HAProxy config. The daily `config.xml` copy (HAProxy settings included) is
`/mnt/backup/opnsense/config-YYYYMMDD.xml` on the Proxmox host, synced to the
Synology `pve-backup/`. Rebuilding the whole box: `docs/runbooks/opnsense.md`.

## Phase history (bd code-yiu, on pfSense)

| Phase | Status | Description |
|---|---|---|
| 1a | done, commit `ef75c02f` | k8s alt :2525 listener + NodePort Service |
| 2  | done, 2026-04-19 | pfSense HAProxy pkg installed (`pfSense-pkg-haproxy-devel-0.63_2`, HAProxy 2.9-dev6) |
| 3  | done, commit `ba697b02` | HAProxy config persisted in pfSense XML (bootstrap script + this runbook) |
| 4+5| done, commit `9806d515` | 4-port alt listeners + HAProxy frontends for 25/465/587/993 + NAT flip |
| 6  | done | Mailserver Service downgraded LoadBalancer → ClusterIP; `10.0.20.202` released back to MetalLB pool; orphan `mailserver` pfSense alias removed; monitors retargeted |
| OPNsense | done, 2026-11-10 | Same frontends and pools moved to `os-haproxy` on OPNsense at the cutover (`haproxy.yml`); the `:2525` test frontend and its pool were left out |

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
- ~~Frontend binds on all firewall interfaces (`bind :25` instead of
  `10.0.20.1:25`).~~ That was pfSense, which templated the bind port-only.
  On OPNsense the frontends bind `10.0.20.1` (and `10.0.10.1` for 443) only.
- k8s-node5 doesn't exist: the cluster has master + 4 workers. Backend pool
  capped at 4 servers.
- Postscreen still logs `improper command pipelining` for legitimate
  clients that send `EHLO\r\nQUIT\r\n` as a single TCP write. This is
  unchanged pre/post-migration: postscreen's anti-bot heuristic.
- On the first boot after the 2026-11-10 swap HAProxy did not start, most
  likely because the generated `haproxy.conf` was still the staging one
  binding 10.0.20.2. The boot hook above covers that case.
