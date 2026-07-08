# Backup MX — self-hosted store-and-forward relay on Oracle Always-Free — design

Date: 2026-07-04 (v3 — post-challenge; v2 Oracle pivot same day) · **Status:
IMPLEMENTED + all gates O1–O5 passed 2026-07-08** · ADR:
[0019](../adr/0019-backup-mx-self-hosted-oracle-relay.md) · as-built runbook:
[backup-mx.md](../runbooks/backup-mx.md)

> **As-built deltas from this design (2026-07-08):** (1) the drain rides a
> **WireGuard tunnel** to pfSense (`10.3.2.10 → 10.0.20.1:25`), NOT the WAN:2526
> NAT rule — no new WAN port; Oracle egress-25 is dodged by UDP encapsulation.
> (2) **Break-glass SSH** from the homelab WAN /32 was added (the devvm isn't a
> tailnet node, so tailnet-only management was inoperable). (3) Drain TLS =
> `none` (redundant inside the tunnel; STARTTLS to the IP literal fails). (4)
> The O5 scale-to-zero test exposed a chronic **postsrsd** spin on the PRIMARY;
> SRS was disabled (`ENABLE_SRS=0`) to keep mail durable — see mailserver.md.
> (5) PAYG deferred; free-only + load-bearing keep-alive.

v3 incorporates two independent adversarial-challenge reviews (same day). Their
material corrections are marked **[CH]** throughout — the largest: the v2 drain
path would never have drained (primary-side smtpd rejects), monitoring-over-
tailnet was fiction (no cluster→tailnet route exists), and the VM's bounce
model was wrong (it can never deliver a DSN).

## Goal

Inbound mail for `viktorbarzin.me` must survive homelab outages without loss.
Requirement level (Viktor, 2026-07-04): **never lose mail; delayed delivery is
acceptable; budget is $0** (hard constraint — reaffirmed after the Rollernet
gates failed). A store-and-forward backup MX queues mail while the homelab is
down and re-delivers when it returns.

Out of scope, explicitly:

- Reading new mail *during* an outage.
- Outbound mail during outages.
- The "primary up but hard-bouncing 5xx" misconfig class — a backup MX is
  never consulted when the primary answers. Separate hardening/alerting track.

Known residual limit (state it plainly): an outage **longer than 30 days**
loses the queued mail *silently* — the VM cannot emit a bounce to anyone
(egress 25 blocked), so no sender ever learns. Accepted; 30 days is already
6× the sender-retry status quo.

## v1 → v2: why Rollernet was dropped (gate evidence, 2026-07-04)

v1 selected Roller Network's free Secondary MX. The validation gates killed it
before any DNS change:

- **G2 FAILED**: the [free-accounts policy](https://rollernet.us/policy/free-accounts.html)
  caps free mail service at **200 relayed messages or 10 MB per rolling 7
  days**; overage → domain suspended **48 h answering SMTP 5xx** (permanent
  bounces), repeatable. Spammers deliberately target backup MXes even while
  the primary is up, so background spam alone can hold the domain suspended —
  worse than no backup MX.
- **G1 SHAKY**: same policy page says free accounts are being discontinued.
- **G3 PASSED** (for posterity): `mail{,2}.rollernet.us` present valid LE
  certs over STARTTLS.
- Signup is Cloudflare-Turnstile-gated — moot given G1/G2.

Viktor's decision: stay free → self-host on Oracle Always-Free. **[CH]** The
external challenger re-searched the free landscape (DNSExit, KisoLabs,
DuoCircle, AWS/Azure/GCP/Hetzner/Fly/Vultr/Linode free tiers) and confirmed:
no credible free managed backup-MX or free VM with a usable port-25 story
exists in 2026 other than OCI. GCP's free e2-micro also blocks egress 25 and
is US-regions-only (wrong continent).

## Decision

A minimal **Postfix store-and-forward relay** (`mx2.viktorbarzin.me`) on an
Oracle Cloud **Always-Free** compute instance, published as a lower-preference
MX. It accepts mail for `viktorbarzin.me` when the primary is unreachable,
queues up to 30 days, and drains to the primary when it returns. No mailboxes,
no third-party terms — the queue-lifetime and reject-behavior knobs are ours.

## Architecture

```
                         ┌── pri 1  mail.viktorbarzin.me ──► pfSense HAProxy ──► mailserver pod
sender MTA ──► MX lookup ┤                                        ▲
                         └── pri 20 mx2.viktorbarzin.me           │ drain: smtp to
                             (Oracle VM, Postfix relay,           │ mail.viktorbarzin.me:2526
                              queue ≤ 30 days) ───────────────────┘ (pfSense WAN NAT rdr
                                                                     2526 → 10.0.20.1:25,
                                                                     existing HAProxy frontend)
```

- **Normal operation**: senders use pri 1; the VM idles (spammers targeting
  the backup + transient-blip retries get relayed onward immediately).
- **Outage**: senders fall back to pri 20 → VM accepts + queues → Postfix
  retries the primary on its native schedule → queue drains after recovery
  through the standard external ingress path (PROXY v2 → :2525 → rspamd →
  Dovecot).
- **Custom drain port**: Oracle blocks **egress TCP 25** tenancy-wide
  (post-2021; exemptions unreliable) — the VM cannot reach
  `mail.viktorbarzin.me:25`. One pfSense WAN NAT rule `TCP 2526 →
  10.0.20.1:25` reuses the existing HAProxy frontend unchanged. **[CH]
  Verified against the runbook**: the frontend binds `*:25` on pfSense (not
  strictly 10.0.20.1), rdr dst-port rewrite is the existing production
  pattern (WAN:25 already rewrites to 10.0.20.1:25), and port 2526 collides
  with nothing (the HAProxy test frontend uses :2525). Inbound TCP 25 **to**
  the VM is unaffected by Oracle's egress-only block per practitioner
  evidence (iRedMail/mailcow on OCI: receive works, send doesn't) — **to be
  proven at gate O2 before any DNS change** (Oracle publishes no positive
  commitment).

## Oracle account & instance

- **Account**: Viktor creates it (human signup; card for identity, $0
  charged). **Home region is fixed at signup and Always-Free compute exists
  only there — choose `eu-frankfurt-1` deliberately; there is no
  try-another-region fallback without a new account. [CH]**
- **PAYG conversion: DEFERRED (Viktor, 2026-07-08) — running free-only.**
  v3 made PAYG a hard prerequisite (idle-reclamation exemption). The upgrade
  attempt failed in practice: Oracle's £80 (~$100) pre-authorization was
  placed on Viktor's Revolut card while the card itself was REJECTED
  (Revolut classified as prepaid-class by Oracle's processor — the known
  failure; the pending hold voids within days). Viktor's decision: stay on
  the free-only account. Trade-offs accepted: (a) idle reclamation applies
  (95th-pct CPU < 20% AND network < 20% over 7 days) → **the cloud-init
  keep-alive workload is now load-bearing, not belt-and-braces** — it must
  hold the instance above the idle bars (lookbusy-style CPU tickler +
  periodic network pulls; calibrate against OCI metrics after launch);
  (b) free-only accounts have lower capacity priority and were the ones hit
  by the June 2026 A1 terminations — `BackupMxDown` + a documented
  CLI-restart recovery (reclamation STOPS the instance, doesn't delete it;
  the queue is empty outside outages, so exposure = a coverage gap until
  restarted, never lost mail); (c) the 30-day account-abandonment clause
  gets a quarterly console-login reminder in the runbook. Silver lining: a
  free-only account has no payment method — Oracle cannot bill anything,
  ever. PAYG retry with a non-Revolut (conventional bank / credit) card
  stays the recommended future hardening.
- **Shape**: `VM.Standard.E2.1.Micro` (x86, 1/8 OCPU burst, 1 GB RAM; 2
  always-free instances allowed; ample for queue-only Postfix — and untouched
  by the 2026 A1 cuts). ARM A1 fallback is **unreliable** (halved quota,
  chronic Frankfurt capacity) — treat E2.1.Micro availability as the gate.
- **[CH] Reserved public IP is mandatory** (`oci_core_public_ip`, reserved):
  an ephemeral IP rotates on stop/start and would silently break all four
  IP-keyed controls at once (pfSense NAT source-restriction, the primary's
  smtpd/rspamd exemptions, the Oracle security list, Prometheus scrape
  allowlist) — discovered only at the next outage's drain.
- **OS**: Ubuntu 24.04. **[CH] OCI Ubuntu images ship an OS-level iptables
  ruleset (`/etc/iptables/rules.v4`) that ACCEPTs 22 and REJECTs everything
  else, independent of security lists** — cloud-init must insert ACCEPT rules
  for 25/80 (+ scrape ports) ahead of the REJECT and persist them, or gate O2
  fails on day 1 with a correct security list.
- **Credentials**: OCI API key for Terraform → Vault `secret/viktor`
  (`oci_*`); web login → Vaultwarden item `Oracle Cloud (backup MX)`.

## Networking & security posture

- **Ingress on the VM**: TCP 25 world-open (the service). **[CH] TCP 80
  world-open permanently** — Let's Encrypt validation is multi-perspective
  with no published source IPs, so it cannot be source-scoped, and a
  "open-only-during-renewal" toggle is unspecified automation whose realistic
  failure mode is an expired cert at day ~90. Nothing listens on 80 outside
  certbot's seconds-long renewal windows; connection-refused surface is
  negligible. TCP 9100/9154 (exporters) restricted to the homelab WAN /32
  (176.12.22.76) in both the Oracle security list and the VM firewall.
- **No public SSH**: management rides the headscale tailnet — cloud-init
  enrolls via a **preauth key for a dedicated non-OIDC headscale user** with
  node tag `tag:backup-mx` (headscale 0.28.0 file-mode ACL, content in Vault
  `secret/headscale` → `headscale_acl`); SSH bound to the tailnet interface.
  ACL grant: `group:admin → tag:backup-mx:22` (cluster pods are NOT tailnet
  members — see monitoring). **[CH] Outage caveat**: headscale's control
  plane + DERP live in the cluster, so mid-outage tailnet reachability is
  cached-netmap best-effort — the runbook documents the **OCI instance
  console connection as break-glass** management. (Also fix `vpn.md`'s stale
  "0.23.x / OIDC-only" claims while in there.)
- **VM compromise blast radius**: plaintext of outage-queued mail + a relay
  surface contained by `relay_domains = viktorbarzin.me` only, no submission
  ports, no SASL, no local delivery. The VM is deliberately NOT added to the
  primary's `mynetworks` (that would let a compromised VM relay arbitrary
  mail *through* the primary) — per-stage exemptions instead, below.

## Postfix configuration (relay-only, accept-and-queue with 4xx-only hygiene)

- `relay_domains = viktorbarzin.me`; `mydestination =` (empty).
- **[CH]** `smtpd_relay_restrictions = permit_mynetworks,
  reject_unauth_destination` — explicit 5xx for foreign-domain RCPTs (the
  default tail is `defer_unauth_destination`, whose 4xx invites every relay
  probe to retry forever).
- **[CH]** `relay_recipient_maps` explicitly set to the wildcard form
  (`@viktorbarzin.me OK`) — documents accept-all-recipients as a decision
  (the domain is catch-all; every RCPT is valid by definition).
- `transport_maps`: `viktorbarzin.me smtp:[mail.viktorbarzin.me]:2526`.
- `maximal_queue_lifetime = 30d`. **[CH]** `bounce_queue_lifetime = 1d` and
  `delay_warning_time = 0` — this host can never deliver a DSN to anyone
  (egress 25 blocked; its only egress is 2526 to the primary), so undeliverable
  bounces must be discarded quickly or they rot in the queue for a month and
  permanently poison the queue-depth alert.
- **[CH]** `message_size_limit = 209715200` — exactly the primary's 200 MB
  (`POSTFIX_MESSAGE_SIZE_LIMIT`, mailserver main.tf:88). The stock 10 MB
  default would 552-reject large legitimate mail during outages — the exact
  loss mode this project exists to prevent. Equal, never higher (higher
  recreates drain-time rejects).
- **[CH] postscreen on the VM in 4xx-only posture**: pregreet test ON
  (fire-and-forget bots don't retry; real MTAs do — the whole design already
  rests on sender retry, so 4xx filtering is loss-free by construction),
  optionally `postscreen_dnsbl_action = defer` with a conservative threshold.
  v2's blanket "no DNSBL" conflated 5xx reputation rejects (rightly banned)
  with 4xx tempfail (harmless); without any hygiene the backup is a 24/7
  spam backdoor since spammers deliberately deliver to the highest-numbered
  MX. Zero 5xx from reputation, ever.
- `inet_protocols = ipv4` **[CH]** — the primary publishes an AAAA (HE
  tunnel) but the IPv6 HAProxy bridge has no :2526 listener; skip the wasted
  v6 attempt per delivery.
- `smtpd_tls_cert_file` = LE cert for `mx2.viktorbarzin.me` (opportunistic
  STARTTLS inbound; `smtp_tls_security_level = may` on the drain leg).
- Queue disk: the ~45 GB free boot volume dwarfs any realistic 30-day
  accumulation for a personal domain.

## TLS

certbot standalone HTTP-01 for `mx2.viktorbarzin.me` (no Cloudflare API token
on an internet-facing VM). Port 80 permanently open (see above); certbot renew
timer. The MTA-STS follow-up (separate task; policy host currently dangling —
below) must list `mx2.viktorbarzin.me` when implemented.

## Primary-side drain enablement **[CH — this section replaces v2's "SPF/DMARC exemption + postscreen permit", which exempted the wrong layers]**

The v2 exemptions targeted postscreen DNSBL (which is **off** on the primary —
`ENABLE_DNSBL` unset) and rspamd SPF/DMARC scoring — but missed the three
mechanisms that would actually break the drain. All are keyed on the VM's
reserved /32 (the PROXY-v2-recovered client IP):

1. **`reject_unknown_client_hostname` bypass** — the primary sets
   `POSTFIX_REJECT_UNKNOWN_CLIENT_HOSTNAME=1` (main.tf:89); an Oracle IP
   without full FCrDNS (PTR needs an Oracle SR; limited on free accounts)
   would be **450-deferred on every drain attempt → the queue never drains →
   mass-bounces at day 30**. Fix: `check_client_access` permit for the VM /32
   early in `smtpd_client_restrictions`, and a matching permit at the sender
   stage (SPOOF_PROTECTION=1 rejects unauthenticated own-domain envelope
   senders — drained self-addressed/bounced mail would 5xx). Attempt the
   Oracle PTR anyway (belt and braces).
2. **Anvil rate-limit exception** — `smtpd_client_message_rate_limit = 30`/min
   keys on the VM's IP at drain; a >3,600-message backlog would throttle for
   hours and false-fire the queue alert. Add the VM /32 to
   `smtpd_client_event_limit_exceptions`.
3. **rspamd: evaluate the original sender, never 5xx the drain stream** — via
   the existing override.d ConfigMap pattern (same mount as
   `dkim_signing.conf`): (a) configure rspamd's **`external_relay`** module
   (ip_map = VM /32) so SPF/DMARC/IP reputation evaluate against the
   *original* client IP parsed from the VM's Received header — this keeps
   DMARC protection for the entire drain stream instead of v2's blanket
   disable; (b) cap rspamd's **action at the VM /32 to tag/fold — never
   milter-reject**: the primary's default reject tier (DMS default, active
   since only dkim_signing is overridden today) would 5xx high-score spam at
   DATA, forcing the VM to generate DSNs to forged senders = classic
   backup-MX backscatter → mx2's IP blacklisted. Drained spam lands tagged in
   the catch-all's Junk instead. Validate the external_relay ↔ settings-rule
   interplay at gate O5 with a high-spam-score message.
4. postscreen permit for the /32 (harmless; pregreet never trips a real
   Postfix client and DNSBL is off — kept for future-proofing only).

## Our-side changes (Terraform unless noted)

1. **New stack `stacks/backup-mx/`** (Tier 1): OCI provider (creds from
   Vault), VCN + subnet + security list + **reserved public IP** +
   `VM.Standard.E2.1.Micro` + cloud-init (`templatefile`): **OS iptables
   ACCEPTs for 25/80/9100/9154 ahead of the OCI image's REJECT rule
   (persisted)**, postfix + config above, certbot, tailscale→headscale
   enrollment (preauth key from Vault), node_exporter, postfix_exporter,
   unattended-upgrades, and a **keep-alive service holding the instance above
   Oracle's idle bars** (95th-pct CPU ≥ 20% AND network ≥ 20% over 7 days —
   load-bearing while the account is free-only; calibrate against the OCI
   Monitoring metrics after launch and document the observed margins in the
   runbook).
2. **DNS** — `stacks/cloudflared/modules/cloudflared/cloudflare.tf`: A
   `mx2.viktorbarzin.me` → reserved IP (non-proxied), MX pref 20 → `mx2`.
   **[CH] Live zone count verified: 195/200 → 197/200 after this change; only
   3 slots remain and the MTA-STS follow-up needs 1–2 → plan the next
   record-purge now, not at collision time.**
3. **pfSense (live network device — approved as part of this plan)**: WAN NAT
   rdr `TCP 2526 → 10.0.20.1:25` + firewall rule, source-restricted to the
   reserved IP. **[CH] Scripted** (extend the existing
   `scripts/pfsense-*-haproxy*.php` bootstrap-script family), not
   hand-clicked — keeps the git-rebuildable parity the rest of the pfSense
   mail config has. Config.xml rides the nightly backup.
4. **Mailserver stack**: the four-layer drain enablement above (client+sender
   `check_client_access` permits, anvil exception, rspamd external_relay +
   action cap, postscreen permit) — all keyed to one /32, via the existing
   `postfix_cf` / `user-patches.sh` / rspamd-override hook points (verified
   present: main.tf:129-144, 222-281, 467-474).
5. **Monitoring [CH — replaces v2's tailnet scraping, which had no transport:
   no cluster→tailnet route exists and no existing target is scraped that
   way]**: Prometheus scrapes `node_exporter`/`postfix_exporter` on the VM's
   **public reserved IP**, allowed only from the homelab WAN /32 (Oracle SL +
   VM firewall); blackbox TCP:25 from the cluster (`BackupMxDown`, warning);
   MX-set drift assertion (both MX records present). Alerts:
   `BackupMxQueueStuck` = **non-bounce** queue depth > 0 for 2 h while the
   primary is healthy (gate on the existing `MailServerDown`/roundtrip
   series, machine-readable — not prose); bounce residue is excluded by the
   1-day bounce lifetime. Note: during a full homelab outage Prometheus
   itself is down — queue growth is unobservable live under ANY transport;
   what we actually watch is the post-recovery drain. A WAN-IP change stales
   the Oracle allowlist → visible as ScrapeTargetDown (self-signaling).
   **Probe semantics note**: once mx2 exists, the Brevo roundtrip probe's
   mail fails over to mx2 on transient primary blips and arrives minutes late
   via the drain — `EmailRoundtripFailing` may then mean "delayed via mx2",
   not "lost"; note in the alert description and runbook.
6. **Docs (same commit as implementation)**: rewrite `mailserver.md` §"No
   Backup MX", new runbook `docs/runbooks/backup-mx.md` (`postqueue -p`,
   forced drain `postqueue -f`, cert renewal, **OCI console break-glass**, VM
   rebuild from stack, Oracle account facts incl. PAYG + home-region lock),
   `vpn.md` headscale-version/OIDC staleness fix, monitoring rows.

### MTA-STS finding (unchanged; no action in this change)

`_mta-sts` TXT is published but `mta-sts.viktorbarzin.me` has no record and
nothing serves the policy — MTA-STS is inert today. When fixed, the policy
MUST include `mx: mx2.viktorbarzin.me` (and budget its DNS records against the
3 remaining zone slots).

## Validation gates (in order; any failure → stop and report)

| # | Gate | Method | Failure handling |
|---|------|--------|------------------|
| O1 | Oracle account (home region `eu-frankfurt-1`, **fixed forever at signup**) + E2.1.Micro capacity. ~~PAYG~~ deferred (2026-07-08, free-only — see account section) | **PASSED 2026-07-08**: API-key auth verified from devvm; quota shows 2 available in AD-3 (AD-1/AD-2 at 0 — pin to AD-3) | A1-in-home-region is a best-effort fallback only (halved quota, contended); else decision returns to Viktor |
| O2 | Inbound TCP 25 reachable from the internet (after the OS-iptables fix) | `nc -zv <reserved-ip> 25` from outside + recurring Uptime-Kuma TCP monitor (keeps proving it — Oracle publishes no commitment) | Stop; decision returns to Viktor |
| O3 | Drain works: VM → `mail.viktorbarzin.me:2526` delivers end-to-end | Test message injected on the VM | Debug pfSense NAT / HAProxy path |
| O4 | LE cert issued | certbot standalone | STARTTLS is opportunistic — non-blocking for go-live; fix before MTA-STS |
| O5 | Live failover test — **hardened [CH]** | presence-claim → scale mailserver to 0 (~30 min) → send from Gmail + Brevo **plus a high-spam-score message and a >10 MB message** → confirm queued (`postqueue -p`) → scale up → verify full drain within the anvil-exception expectations, spam folded to Junk (not bounced), headers show original-IP SPF/DMARC evaluation, no DSN generated on the VM, roundtrip probe recovers | Debug or roll back (remove MX record) |

## Failure modes

Covered: cluster/pod outages, pfSense/power/ISP outages ≤ 30 days, WAN IP
changes, short-retry senders. If pfSense is down the drain waits — Postfix
retries until it heals.

Not covered: primary-up-but-5xx misconfigs; outbound; mid-outage mailbox
access; **outages > 30 days lose queued mail silently (no DSN possible)**.
Simultaneous Oracle+homelab outage = status quo ante (sender retries).

Newly introduced, accepted:

- **A pet outside the cluster** — deliberately cattle: rebuilt from TF +
  cloud-init, patched by unattended-upgrades, scraped by Prometheus. Never a
  backup target.
- **Oracle free-tier caprice [CH — upgraded from v2's framing]**: Oracle has
  silently cut Always-Free allowances and terminated over-limit instances
  (June 2026, A1). Mitigations: load-bearing keep-alive workload (PAYG
  deferred 2026-07-08 — free-only account, see account section), recurring
  inbound-25 probe, `BackupMxDown` + CLI-restart recovery in the runbook, and
  the fact that outside an active outage the queue is empty — a surprise
  reclamation loses nothing, only coverage until restarted.
  If OCI sours, the documented fallback order is: **RackNerd VPS ($11/yr,
  port 25 open by default per the community mail-provider matrix — same
  self-hosted relay design, and outbound 25 works so the custom drain port
  becomes unnecessary)**, then Rollernet Basic ($30/yr, managed). [Deep-research
  survey 2026-07-05: no other free VM tier or free managed backup-MX exists.]
- **Spam hygiene**: 4xx-only postscreen on the VM (pregreet + conservative
  DNSBL-defer) instead of v2's nothing; drained spam is tagged/folded by
  rspamd, never bounced.
- Outage mail sits plaintext on Oracle disk ≤ 30 days (single-tenant;
  accepted).

## Rollback

Remove the MX + A records; wait for `postqueue -p` empty; `terraform destroy`
on `backup-mx`; delete the pfSense NAT rule (scripted); drop the mailserver
/32 exemptions. Order matters: MX record first.

## Viktor's manual steps (everything else is mine)

1. Create the Oracle Cloud account — **home region `eu-frankfurt-1`** (fixed
   forever), card for identity, $0 charged.
2. ~~Convert the tenancy to Pay-As-You-Go~~ — DEFERRED (2026-07-08): the £80
   pre-auth landed while the Revolut card was rejected as prepaid-class;
   running free-only with the keep-alive mitigation. Optional future
   hardening with a conventional bank/credit card.
3. ~~Hand me the tenancy OCID + API key~~ — DONE (2026-07-08): key pasted,
   auth verified from the devvm, creds in Vault.
4. Approve the (scripted) pfSense NAT rule when I reach that step.
5. Quarterly: log into the OCI console once (30-day account-abandonment
   clause; reminder lives in the runbook).
