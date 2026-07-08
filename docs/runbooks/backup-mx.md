# Backup MX (Oracle Always-Free relay) — runbook

Backup MX for `viktorbarzin.me` per [ADR-0019](../adr/0019-backup-mx-self-hosted-oracle-relay.md).
Design: [plan](../plans/2026-07-04-backup-mx-design.md). Built + all gates passed 2026-07-08.
Since [ADR-0020](../adr/0020-mx2-outage-failover-and-external-vantage.md) (2026-07-08) the
VM also carries the **failover tenants** — status page, edge error page, edge-unreachable
alerting — see [§ Status page / failover tenants](#status-page--failover-tenants-adr-0020).

## What it is

A disposable Postfix store-and-forward relay, `mx2.viktorbarzin.me`, on an Oracle
Cloud **Always-Free** `VM.Standard.E2.1.Micro` (Frankfurt AD-3). Published as
**MX priority 20** behind the primary (`mail.viktorbarzin.me`, pri 1). When the
homelab is unreachable, senders fall to mx2, which accepts and queues mail up to
**30 days**, then drains it to the primary on recovery. Nothing is lost for
outages ≤ 30 days.

```
sender ─MX─┬─ pri 1  mail.viktorbarzin.me → pfSense HAProxy → mailserver pod
           └─ pri 20 mx2.viktorbarzin.me (Oracle VM)
                       │ accepts + queues (≤30d)
                       └ drains: postfix → WireGuard tunnel → 10.0.20.1:25 (HAProxy) → primary
```

- **Drain rides WireGuard, not the WAN.** mx2 is a road-warrior peer on pfSense
  `tun_wg0` (tunnel IP `10.3.2.10`); the drain to `10.0.20.1:25` is
  UDP-encapsulated to `:51821`, so Oracle's tenancy-wide egress-25 block never
  applies and no new WAN mail port exists. Drain TLS is `none` (redundant inside
  the encrypted tunnel; opportunistic STARTTLS to the IP literal fails the
  handshake anyway).
- **Reserved public IP** `92.5.132.215` — stable across stop/start; four controls
  key on it (DNS A, Oracle security list, scrape allowlist) or on the tunnel IP
  (the primary's drain exemption).
- **Account is free-only** (PAYG deferred — the £80 upgrade pre-auth took while
  Revolut was rejected as prepaid-class). Idle-reclamation defense = a
  load-bearing `keepalive-cpu.service` (`stress-ng --cpu-load 30`, idle sched
  priority) — since ADR-0020, gatus' real probe traffic helps defend the same
  bar. Quarterly: log into the OCI console once (30-day account-abandonment
  clause).
- **Not just mail anymore (ADR-0020, 2026-07-08)**: mx2 is also the homelab's
  external vantage — it serves `status.viktorbarzin.me`, hosts the `/error.html`
  the edge failover Worker serves for proxied hosts, and fires edge-unreachable
  Slack alerts. **Mail keeps priority** on the 1 GB box; the tenants are capped
  (gatus `MemoryMax=128M`). Details + drill in the dedicated section below.

## Secrets (Vault — `secret/viktor` unless noted)

| Key | Use |
|-----|-----|
| `oci_api_private_key`, `oci_api_key_fingerprint`, `oci_user_ocid`, `oci_tenancy_ocid` | OCI Terraform provider + `oci` CLI |
| `backup_mx_ssh_private_key` / `_public_key` | break-glass SSH (key at `~/.ssh/backup-mx`) |
| `backup_mx_wg_private_key` / `_public_key` | WireGuard drain tunnel (pubkey is in the pfSense peer) |
| `backup_mx_headscale_preauth` | tailnet enrollment — **reusable + ephemeral**, so rebuilds need no re-mint |
| Slack webhook — in **`secret/platform`** | gatus edge-unreachable alerts (ADR-0020) — **baked into the gatus config at provision**; mx2 never reads Vault at runtime (unreachable mid-outage), so rotation = re-converge/rebuild |

## Disposability — recreate the VM from scratch

The VM is pure cattle: `stacks/backup-mx/` (OCI resources) + `cloud-init.yaml.tftpl`
(the entire machine) + Vault-held identity. **One command rebuilds it**, and the
pfSense peer + primary exemption never need re-touching (they key on the
Vault-stable WG identity / tunnel IP):

```sh
# from the MAIN infra checkout (never a worktree — git-crypt), TMPDIR off /tmp:
export TMPDIR=~/.tmp-tf
cd stacks/backup-mx
../../scripts/tg apply -replace=oci_core_instance.mx2   # ~8 min: full cloud-init re-run
```

cloud-init is idempotent and self-contained: OS-iptables ACCEPTs for
25/80/443/9100 (443 since ADR-0020, mirrored in the OCI security list),
egress-gated + retried package install (postfix/certbot/node-exporter/stress-ng/
wireguard, plus the ADR-0020 tenants nginx + gatus), **postfix debconf preseeded
+ `DEBIAN_FRONTEND=noninteractive`** (without this `apt install postfix` HANGS
on an interactive TUI and cloud-init never finishes), WireGuard up (`wg0`, key
from Vault, endpoint `vpn.viktorbarzin.me` + re-resolve timer), the
accept-and-queue Postfix config, certbot bootstrap (retries until DNS resolves;
webroot mode via nginx, SANs `mx2` + `status` since ADR-0020), the keep-alive,
and the status-page/error-page tenants. Nothing lives only on the box — any
hand-applied change is mirrored into cloud-init the same session (see
LIVE-CONVERGE vs REBUILD below).

Full teardown: `../../scripts/tg destroy` on `backup-mx`, then remove the
Cloudflare state that keys on mx2 in `stacks/cloudflared` — `backup_mx_a`,
`backup_mx_mx`, and since ADR-0020 the `status` A record (the status page dies
with the VM) plus the failover Worker's error-page source (the Worker then
degrades to its inline-HTML fallback) — and the pfSense peer
(`wg set tun_wg0 peer jxwL9ZmO… remove` + delete from `/usr/local/etc/wireguard/tun_wg0.conf`).

## The pfSense side (WireGuard peer)

Hand-configured kernel `wg` (NOT the pfSense package): config
`/usr/local/etc/wireguard/tun_wg0.conf`, started by an `earlyshellcmd`. mx2 is
one peer among the London/Sofia site tunnels. Reproducer (idempotent, applies
live without an interface reconnect):

```sh
scp scripts/pfsense-backup-mx-wg.sh admin@10.0.20.1:/tmp/ && ssh admin@10.0.20.1 'sh /tmp/pfsense-backup-mx-wg.sh'
```

No firewall rule needed — `opt2` (tun_wg0) already has an any→any allow.

## Operations

- **SSH in** (break-glass, homelab-WAN-locked): `ssh -i ~/.ssh/backup-mx ubuntu@92.5.132.215`
- **Mid-outage, if the tailnet/SSH is unreachable**: OCI serial console —
  `oci compute instance-console-connection create` (works with all ports/security
  lists blocked). Serial *console-history* is a boot-only ring buffer — useless
  for live debug; use SSH.
- **Inspect the queue**: `sudo postqueue -p`  ·  **force a drain**: `sudo postqueue -f`
  (or `sudo postsuper -r ALL` to reset deferrals)
- **Cert**: ONE cert, SANs `mx2` + `status` — **webroot mode through nginx**
  since ADR-0020; certbot auto-renews (`certbot-bootstrap.timer` + the renew
  timer); port 80 stays open.
- **Verify the drain path** (from mx2): `python3 -c "import smtplib;s=smtplib.SMTP('10.0.20.1',25);print(s.ehlo(),s.mail('t@gmail.com'),s.rcpt('spam@viktorbarzin.me'));s.quit()"` → expect RCPT `250`.

## Primary-side drain exemption

The primary permits mx2's tunnel IP `10.3.2.10` past `reject_unknown_client_hostname`
(a private IP has no PTR) via `check_client_access cidr:/tmp/docker-mailserver/backup-mx-permit.cidr`
(`10.3.2.10/32 OK`) prepended to `smtpd_sender_restrictions`
(`stacks/mailserver/modules/mailserver/main.tf` + `variables.tf`). `OK` clears
only client/helo/sender — relay is still gated by `smtpd_relay_restrictions`, so
no relay is granted (deliberately not `mynetworks`). The tunnel IP is also in
`smtpd_client_event_limit_exceptions` so a big post-outage drain isn't anvil-throttled
to ~30 msg/min (which would false-fire `BackupMxQueueStuck`).

## Filtering parity (added 2026-07-08, same-day audit)

A backup MX is a classic spam-filter bypass — spammers deliberately target the
higher-preference MX. Parity is split across the two hosts; all reputation
verdicts on mx2 are **4xx-only** (a backup MX that 5xxs manufactures the loss
it exists to prevent):

**On mx2** (`stacks/backup-mx/cloud-init.yaml.tftpl`, mirrors the primary):
- **postscreen** fronts :25 — pregreet `enforce` + Spamhaus zen DNSBL
  (`threshold 3`), with `-o soft_bounce=yes` on the postscreen service so its
  rejects are 450s, never 550s. Spamhaus resolves fine via the OCI
  per-instance resolver (verified). NOTE: the original bring-up guard
  `grep -q postscreen master.cf` matched Ubuntu's stock COMMENTED postscreen
  examples and silently skipped activation — mx2 ran bare smtpd until the
  2026-07-08 audit. The guard now matches only an active line.
- **anvil rate limits** identical to the primary (10 conn / 30 msg per 60s).
- **FCrDNS** (`reject_unknown_client_hostname`, 450) — so no-PTR clients can't
  use mx2 to dodge the primary's identical check.

**On the primary, for the drain stream** (`stacks/mailserver`):
- **rspamd `external_relay`** (`ip_map = 10.3.2.10/32`): scores drained mail
  against the ORIGINAL client IP from mx2's Received header, not the tunnel IP
  — without it rspamd treats 10.3.2.10 as `local_addrs` and skips the scan
  entirely (verified on the O5 mail: zero X-Spamd headers). Stamps the
  `BACKUP_MX_DRAIN` symbol.
- **rspamd `force_actions`**: when `BACKUP_MX_DRAIN` is present, downgrades
  reject/soft-reject to `add header` — spam is tagged and foldered, never
  5xx'd back to mx2 (a reject makes mx2 bounce, and its DSN can never leave —
  egress 25 blocked — so a false positive would be SILENT loss). A settings
  rule matching `ip = 10.3.2.10` does NOT work — external_relay rewrites the
  IP before settings match.
- **policyd-spf `skip_addresses += 10.3.2.10/32`** (user-patches.sh): policyd
  checks SPF against the CONNECTING IP, so any strict-SPF (`-all`) sender
  drained through mx2 was 550'd at RCPT — a pre-existing loss bug found by
  this audit (O3/O5 used `~all` senders and never tripped it). SPF for
  drained mail is rspamd's job, against the original IP.
- **GTUBE exception**: rspamd handles the GTUBE test-string as a core
  pre-result that bypasses force_actions — a drained GTUBE still bounces.
  Only the literal test pattern does this; treat it as a canary.

Verify after changes: send through mx2 from an external client and check
`grep <subject> /var/log/mail/rspamd.log` on the pod shows `ip: <original>`,
`BACKUP_MX_DRAIN(0.00)`, and for a >11-score message an `add header` action
with mx2 logging `status=sent`, not `bounced`.

## Status page / failover tenants (ADR-0020)

mx2 doubles as the homelab's **external vantage**
([ADR-0020](../adr/0020-mx2-outage-failover-and-external-vantage.md), 2026-07-08):
`status.viktorbarzin.me` is a **grey-cloud A → 92.5.132.215**, so it resolves
and serves through a homelab + tunnel outage. Everything below is codified in
`stacks/backup-mx/cloud-init.yaml.tftpl` — the single source of truth for
on-box config; the edge Worker lives in
`stacks/cloudflared/modules/cloudflared/worker_failover.js`.

| Tenant | Unit(s) | What / where |
|--------|---------|--------------|
| gatus | `gatus.service` (`MemoryMax=128M`) | Status page + edge sentinels + Slack alerting. YAML config under `/etc/gatus/` (exact files: cloud-init). Probes **public hostnames only**; sentinel group = tunnel path (proxied host ⇔ cloudflared CONNECTED) + direct path (`mail…:993` TCP) + one direct HTTPS host, failure-threshold 3. Per-service alerting stays with in-cluster Alertmanager — mx2 pages ONLY for "homelab unreachable from the internet". |
| nginx | `nginx.service` | TLS for `status.viktorbarzin.me` (cert SANs `mx2`+`status`, certbot **webroot** mode) + serves the self-contained `/error.html` the failover Worker fetches (edge-cached 60 s). Port 443 world-open (OCI seclist + OS iptables). |
| WG re-resolve | timer + oneshot pair (names: cloud-init) | Re-resolves `vpn.viktorbarzin.me` and re-sets the `wg0` peer endpoint — WireGuard resolves `Endpoint=` once, so a homelab WAN renumber would otherwise strand the drain forever. The DNS record itself is refreshed homelab-side (bead `code-dvla`); the CF token is never on mx2. |
| certbot renew | `certbot-bootstrap.timer` + stock renew timer | Webroot renewals through nginx; port 80 stays open (LE is multi-perspective, unscopeable). |

The Slack webhook is baked into the gatus config **at provision** from Vault
`secret/platform` — mx2 cannot reach Vault mid-outage, so there is no runtime
lookup; webhook rotation = re-converge (or rebuild).

**Quick health checks:**

```sh
curl -sS https://status.viktorbarzin.me/myip        # end-to-end: DNS → mx2 nginx TLS → app; no homelab dependency
ssh -i ~/.ssh/backup-mx ubuntu@92.5.132.215 'systemctl status gatus nginx --no-pager'
# on the box:
journalctl -u gatus -e                               # probe results + alert sends
journalctl -u nginx -e
systemctl list-timers | grep -Ei 'certbot|resolve'   # renew + WG re-resolve timers armed
```

### LIVE-CONVERGE vs REBUILD

cloud-init runs **once**, at first boot — it does NOT reconcile a running VM.
The 2026-07-08 tenants were **converged onto the live VM by hand** (SSH), with
the identical config codified into `cloud-init.yaml.tftpl` in the same change.
That mirror is the disposability invariant: **any live change MUST land in
cloud-init in the same session**, or the next rebuild silently sheds it. A
REBUILD (`tg apply -replace=oci_core_instance.mx2`, above) replays cloud-init
and reproduces mail + all ADR-0020 tenants with zero hand steps — if it
wouldn't, the cloud-init mirror has drifted and that is the bug to fix.

### Verification drill

- **Cheap (any time, zero impact):** a permanent synthetic proxied host
  (CNAME → all-zeros tunnel UUID) is ALWAYS 530 at the edge. From OUTSIDE the
  homelab: `curl -i https://test-failover.viktorbarzin.me -H 'Accept: text/html'`.
  From the LAN/devvm the name deliberately has NO internal record (an internal
  CNAME-to-apex would hit Traefik instead of the Cloudflare edge and test
  nothing), so pin the edge IP via public DNS:
  `curl -i --resolve test-failover.viktorbarzin.me:443:$(dig +short @1.1.1.1 test-failover.viktorbarzin.me | head -1) https://test-failover.viktorbarzin.me/ -H 'Accept: text/html'`.
  Expect **HTTP 503** + an `x-failover` header + `Retry-After` + the branded
  page body (`Accept: text/html` is required — machine clients get the raw
  530 by design). This exercises DNS → Worker intercept → outage page without
  touching any real service. NOTE the ADR-0020 coverage gap: hosts with
  per-host rybbit-analytics routes (apex, www, immich, …) bypass the failover
  Worker until the two Workers are consolidated.
- **Full (deliberate outage — requires explicit human OK + a presence claim
  first):** scale the cloudflared deployment (`stacks/cloudflared`) to 0 for
  ~2 min; confirm real proxied hosts serve the failover page (503 + branded
  body, NOT raw 530/1033) and `status.viktorbarzin.me` stays up; then scale
  back to the Terraform replica count (3) and confirm normal service. The
  gatus tunnel-path sentinel goes red during the window; Slack fires only if
  the outage outlives failure-threshold 3. Inbound mail caught in the window
  queues on mx2 and drains — expected, not a failure.

## Gotchas learned during bring-up (2026-07-08)

- **OCI egress TCP 25 is blocked tenancy-wide** — the drain works only because
  it's WireGuard-encapsulated. Inbound 25 (mail receipt) is fine.
- **OCI Ubuntu images REJECT all but 22** at the OS iptables layer regardless of
  the security list — cloud-init inserts ACCEPTs at the top.
- **postfix debconf hang** (above) — the #1 cause of a dead cloud-init.
- **SRS / postsrsd**: disabled on the PRIMARY (`ENABLE_SRS=0`) because postsrsd
  1.10 deterministically busy-loops on restart (see the mailserver.md
  troubleshooting entry). Unrelated to mx2, but the O5 scale-to-zero test is what
  exposed it. Re-enable once postsrsd is fixed.

## Gate results (2026-07-08, all PASSED)

O1 auth+capacity · O2 inbound 25 from internet (`220 mx2… ESMTP`) · O3 drain
end-to-end (RCPT 250 over the tunnel) · O4 LE cert issued · O5 failover
(mailserver scaled to 0 → external mail queued on mx2 → scaled up → drained
`status=sent`, queue empty).
