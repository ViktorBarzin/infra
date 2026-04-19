# pfSense HAProxy for Mailserver — Runbook

Last updated: 2026-04-19

## What & why

External mail traffic (SMTP/IMAP) requires **real client IP visibility** for
CrowdSec + Postfix rate-limiting. MetalLB cannot inject PROXY-protocol
headers (see [`mailserver-proxy-protocol.md`](./mailserver-proxy-protocol.md)),
so pfSense runs a small HAProxy that:

1. Listens on the pfSense VIP,
2. Forwards each connection to a k8s node's NodePort,
3. Injects PROXY-v2 framing so Postfix/Dovecot see the original client IP,
4. TCP health-checks every worker — any node can serve.

Corresponding k8s-side setup lives in `stacks/mailserver/modules/mailserver/`:
- ConfigMap `mailserver-user-patches` → `user-patches.sh` appends alt
  `master.cf` service on port 2525 with
  `postscreen_upstream_proxy_protocol=haproxy`.
- Service `mailserver-proxy` → NodePort 30125 → targetPort 2525 →
  `externalTrafficPolicy: Cluster`.

bd: `code-yiu`.

## Current state (Phase 3 — TEST PATH)

```
                                 INTERNET
                                    │
                            (unchanged — still MetalLB path)
                                    ↓
                WAN:25/465/587/993 ─┐
                                    │                  TEST PATH ↓
                                    │                  (pfSense HAProxy, port 2525 only)
                          pfSense NAT rdr                │
                                ↓                        ↓
             <mailserver> alias (= 10.0.20.202)   HAProxy on pfSense (10.0.20.1:2525)
                                ↓                        ↓
                 MetalLB VIP 10.0.20.202           k8s-node:30125 (NodePort, ETP: Cluster)
                 (ETP:Local, kube-proxy DNAT)            ↓
                                ↓                  kube-proxy (SNAT — IP lost here, recovered by PROXY-v2)
                            mailserver pod               ↓
                       stock :25/:465/:587/:993   mailserver pod :2525 postscreen (PROXY-v2)
```

Nothing production flips to HAProxy yet; all real traffic still uses the
MetalLB LB IP path. To validate the HAProxy path:

```sh
# From any k8s VLAN host:
python3 -c "
import socket; s=socket.socket(); s.connect(('10.0.20.1', 2525))
print(s.recv(200).decode())
s.send(b'EHLO testclient\r\n')
print(s.recv(500).decode())
s.send(b'QUIT\r\n'); s.close()"

# Then check mailserver logs for CONNECT from [YOUR-IP]:
kubectl logs -c docker-mailserver deployment/mailserver -n mailserver --tail=20 | grep smtpd-proxy
```

## Bootstrap / restore from scratch

Config lives in pfSense `/cf/conf/config.xml` under
`<installedpackages><haproxy>`. Backed up nightly to
`/mnt/backup/pfsense/config-YYYYMMDD.xml` by `scripts/daily-backup.sh`, then
Synology. To rebuild from source of truth (git):

```sh
scp infra/scripts/pfsense-haproxy-bootstrap.php admin@10.0.20.1:/tmp/
ssh admin@10.0.20.1 'php /tmp/pfsense-haproxy-bootstrap.php'
```

The script is idempotent — re-runs reset the mailserver frontend + backend to
the declared state.

Expected output:
```
haproxy_check_and_run rc=OK
messages: ...
```

Verify:
```sh
ssh admin@10.0.20.1 "pgrep -lf haproxy; sockstat -l | grep ':2525'"
# 64009 /usr/local/sbin/haproxy -f /var/etc/haproxy/haproxy.cfg ...
# www  haproxy  64009 5  tcp4  *:2525  *:*
```

## Operations

### Change backend k8s node IPs

Edit `infra/scripts/pfsense-haproxy-bootstrap.php` → `foreach` array of
`[name, address]`, re-run via the bootstrap command above. Don't hand-edit
`/var/etc/haproxy/haproxy.cfg` — it is regenerated from XML on every apply.

### Check health of backends

```sh
ssh admin@10.0.20.1 "echo 'show servers state' | socat /tmp/haproxy.socket stdio"
```
`srv_op_state=2` means UP, `0` means DOWN.

### View live HAProxy stats (WebUI)

`https://pfsense.viktorbarzin.me` → Services → HAProxy → Stats

### Reload after config.xml edit

```sh
ssh admin@10.0.20.1 'pfSsh.php playback svc restart haproxy'
```

### Restore from backup

pfSense config backup is a plain XML file:
```
/mnt/backup/pfsense/config-YYYYMMDD.xml        # sda host copy (1.1TB RAID1)
/volume1/Backup/Viki/pve-backup/pfsense/...    # Synology offsite
```

Full restore: pfSense WebUI → Diagnostics → Backup & Restore → Upload that
`config.xml`. The `<installedpackages><haproxy>` section is included.

## Phase roadmap (bd code-yiu)

| Phase | Status | Description |
|---|---|---|
| 1a | ✅ done (commit `ef75c02f`) | k8s alt listener `:2525` + `mailserver-proxy` NodePort |
| 2  | ✅ done (2026-04-19) | pfSense HAProxy installed + test config on `:2525` |
| 3  | ✅ done (2026-04-19) | HAProxy config persisted to pfSense `config.xml` (this runbook + `pfsense-haproxy-bootstrap.php`) |
| 4  | not yet | Flip pfSense NAT rdr for `:25` from `<mailserver>` alias → HAProxy VIP. Requires atomic cutover. |
| 5  | not yet | Extend to ports 465/587/993: add alt container listeners (4465/5587/10993), add Dovecot `haproxy = yes` on extra inet_listener, expand HAProxy frontends, flip NAT. |
| 6  | not yet | Observe 48h, decommission MetalLB LB path (downgrade mailserver Service from LoadBalancer to ClusterIP, free `10.0.20.202`). |

## Known warts

- HAProxy TCP health-check with `send-proxy-v2` + short `inter` floods
  postscreen with `getpeername: Transport endpoint not connected` warnings
  every check cycle. Mitigated with `inter 120000` (2 min). To reduce
  further, switch to `option smtpchk` — but that requires a separate
  non-PROXY health-check port on the pod (not done yet).
- Frontend binds on all pfSense interfaces (`bind :2525`) rather than just
  `10.0.20.1:2525`. `<extaddr>` is set in XML but pfSense templates it as
  port-only. Low concern while port 2525 is a test port; tighten once
  promoted to real ports (25/465/587/993).
- k8s-node5 doesn't exist — cluster has master + 4 workers. Backend pool
  capped at 4 servers.
