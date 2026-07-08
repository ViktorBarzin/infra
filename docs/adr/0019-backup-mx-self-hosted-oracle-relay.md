# Inbound mail gets a self-hosted store-and-forward backup MX on Oracle Always-Free

**Status: IMPLEMENTED + LIVE** — built from `stacks/backup-mx/`; all validation
gates **O1–O5 passed 2026-07-08**. Runbook:
[`backup-mx.md`](../runbooks/backup-mx.md). Several mechanisms changed between
design and build — most importantly the drain now rides a **WireGuard tunnel**,
not the WAN:2526 NAT rule. See **As-built (2026-07-08)** below for the full delta
set; the decision narrative and considered options below are preserved as the
design-time record.

`viktorbarzin.me` has run a single direct MX to the home IP since the 2026-04-12
inbound overhaul, with sender-MTA retry (1–5 days, sender-dependent) as the only
outage protection — a documented "No Backup MX" decision made after ForwardEmail's
forced anti-spoofing rejected legitimate forwarded mail and Cloudflare Email
Routing proved pass-through-only. Viktor now wants inbound mail to survive
homelab outages **without loss** (2026-07-04): delayed delivery is fine,
mid-outage reading is not required, and the budget is **$0** — a hard
constraint that eliminated every managed option (see below).

We run a minimal **Postfix store-and-forward relay on an Oracle Cloud
Always-Free `VM.Standard.E2.1.Micro`** (`mx2.viktorbarzin.me`, **reserved**
public IP, MX preference 20; primary untouched at 1). It accepts everything
for the domain (catch-all — every RCPT is valid; reputation may only ever
4xx-defer, via postscreen pregreet + conservative DNSBL-defer on the VM —
never 5xx: a backup MX that hard-rejects manufactures the loss it exists to
prevent), queues up to **30 days** (bounce lifetime 1 day — the VM can never
deliver a DSN, its only egress is the drain), and drains to the primary over
**port 2526** — one scripted pfSense WAN NAT rule onto the existing HAProxy
frontend — because Oracle blocks egress TCP 25 tenancy-wide. Management is
tailnet-only (headscale preauth key, `tag:backup-mx`; OCI console as
mid-outage break-glass since headscale itself lives in the cluster); TLS via
certbot HTTP-01 (port 80 permanently open — LE validation is
multi-perspective and unscopeable); the VM is a cattle-rebuild from a new
`stacks/backup-mx/` Terraform stack (OCI provider + cloud-init, which must
also punch 25/80 through the OCI Ubuntu image's OS-level iptables REJECT).
On the primary, the drain stream (one /32) is enabled at the layers that
actually bite — `check_client_access` permits past
`reject_unknown_client_hostname` and spoof-protection, an anvil rate-limit
exception, and rspamd `external_relay` (score against the *original* sender
IP) with the reject action capped to tag/fold so drained spam can never force
the VM to emit backscatter. Go-live is gated on empirical checks: inbound-25
reachability (recurring probe — Oracle publishes no commitment), drain
end-to-end, and a live failover test that includes a high-spam-score and a
>10 MB message. Two independent adversarial reviews (2026-07-04) shaped this
final form. Design:
[`plans/2026-07-04-backup-mx-design.md`](../plans/2026-07-04-backup-mx-design.md).

## As-built (2026-07-08)

Live from `stacks/backup-mx/` (reserved IP `92.5.132.215`, Frankfurt AD-3); all
gates passed — O1 auth+capacity, O2 inbound 25 from the internet, O3 drain
end-to-end, O4 LE cert, O5 live failover (mailserver scaled to 0 → external mail
queued on mx2 → scaled up → drained `status=sent`, queue empty). What shipped
differs from the design above:

- **Drain rides a WireGuard tunnel, not the WAN:2526 NAT rule.** mx2 is a
  road-warrior peer on pfSense `tun_wg0` (tunnel IP `10.3.2.10/32`; pfSense
  endpoint `176.12.22.76:51821`); the Postfix transport is `smtp:[10.0.20.1]:25`
  over the tunnel. Oracle's tenancy-wide egress-25 block is dodged because the
  drain is UDP-encapsulated to `:51821` — so **no new WAN mail port was opened**,
  a security win over the NAT plan. pfSense WireGuard is hand-configured kernel
  `wg` (NOT the package); reproducer `scripts/pfsense-backup-mx-wg.sh`; `opt2`
  (tun_wg0) already had an any→any allow, so no firewall rule was needed.
- **Drain TLS = none** — redundant inside the encrypted tunnel, and opportunistic
  STARTTLS to the `10.0.20.1` IP literal fails the handshake anyway.
- **Break-glass SSH was added** — a homelab-WAN-/32-locked, key-only rule in the
  OCI security list. The design's "tailnet-only management" was inoperable: the
  devvm the VM is operated from is not a tailnet node. Mirrors the PVE `:52222`
  break-glass precedent; Tailscale/headscale still enrolls, and the OCI serial
  console stays the mid-outage fallback.
- **PAYG deferred → free-only** (risk detail under Consequences): Oracle's £80
  upgrade pre-auth was taken while the Revolut card was rejected as
  prepaid-class, so the account runs free-only with a **load-bearing
  `keepalive-cpu.service`** as the idle-reclamation defense (not PAYG). PAYG retry
  with a conventional card stays recommended hardening.
- **Primary-side drain exemption simplified to one layer** — a single
  `check_client_access` permit for the tunnel IP (details under Consequences).
- **Monitoring wired 2026-07-08** (`stacks/monitoring`): blackbox TCP:25
  `BackupMxDown`, node/postfix-exporter queue-depth scrape allowlisted to the
  homelab WAN /32, and MX-set drift.
- **SRS disabled on the PRIMARY** as a side effect of the O5 test (postsrsd
  1.10 busy-loop); kept OFF permanently by decision — see Consequences.

## Considered options

- **Roller Network free Secondary MX** — v1 of this decision, killed at the
  validation gates the same day: free tier caps at 200 relayed messages or
  10 MB per rolling 7 days, and overage suspends the domain for 48 h
  answering **SMTP 5xx** (permanent bounces) — since spammers target backup
  MXes even while the primary is up, background spam alone can hold it
  suspended, making it *worse than no backup MX*. Free accounts are also
  being discontinued. (Their TLS checked out; their paid Basic at $30/yr is
  a fallback if the OCI route sours — behind RackNerd at $11/yr, whose VPSes
  ship with port 25 open by default per the community mail-provider matrix,
  making it the cheapest paid escape hatch with the same relay design and no
  custom drain port. A 2026-07-05 deep-research survey reconfirmed no free
  alternative exists: Fly.io's free tier is dead for new customers, GCP
  blocks egress 25 with US-only free regions, and OVH/IBM/Alibaba/Tencent/
  Scaleway offer no always-free VM.)
- **Dynu Email Backup ($9.99/yr)** — queue lifetime undocumented (FAQ hints
  12–24 h, barely beating sender retry); filtering black-box; not free.
- **Cloudflare Email Routing / mailflare** — no store-and-forward / terminal
  inbox on Cloudflare; rejected earlier (2026-04-12; 2026-07-04 memory #7148).
- **Other free tiers** (challenged and re-verified 2026-07-04): GCP e2-micro
  blocks egress 25 too and its free regions are US-only; AWS's 2025+ "free"
  plan is a 6-month credit; Azure has no always-free VM and blocks 25;
  Hetzner has no free tier; Fly.io ended free allowances; Vultr/Linode are
  trial credits; DNSExit/KisoLabs/DuoCircle backup-MX are paid or dead. OCI
  is the only standing free option.
- **Harden-only** (5xx-misconfig guards + paging) — does not address
  multi-day outages or short-retry senders; deferred as a complementary
  track.

## Consequences

- **A pet outside the cluster** — deliberately cattle: rebuilt entirely from
  Terraform + cloud-init, patched by unattended-upgrades, scraped by the
  cluster's Prometheus (exporters on the reserved public IP, allowlisted to
  the homelab WAN /32 — there is **no cluster→tailnet route**, so tailnet
  scraping was rejected as fictional; blackbox TCP:25 + MX-set drift alerts
  besides). Never a backup target itself.
- **Oracle free-tier caprice is the top risk**: Oracle silently halved the A1
  free allowance in June 2026 and terminated over-limit instances, and
  publishes no commitment that inbound 25 stays open. Mitigations: a
  **load-bearing keep-alive workload** above the idle-reclamation bars
  (95th-pct CPU/network ≥ 20% over 7 days), a recurring inbound-25 probe,
  `BackupMxDown` with a CLI-restart recovery path (reclamation stops, never
  deletes), and the queue being empty outside outages (a surprise reclamation
  loses coverage, never mail). **PAYG conversion — originally a required
  prerequisite — was DEFERRED on 2026-07-08**: Oracle's £80 upgrade pre-auth
  was taken while the Revolut card was simultaneously rejected as
  prepaid-class; Viktor chose to run free-only (no payment method on file =
  Oracle cannot bill, ever; retry later with a conventional card remains the
  recommended hardening). Home region is fixed at signup — Frankfurt, chosen
  once; quarterly console logins cover the 30-day account-abandonment clause.
- **Primary-side drain exemption (as-built — one layer, not the design's
  four).** A `check_client_access cidr` (`10.3.2.10/32 OK`) prepended to
  `smtpd_sender_restrictions` clears the PTR-less WireGuard tunnel IP past
  `reject_unknown_client_hostname`. `OK` clears client/helo/sender only — relay
  stays gated by `smtpd_relay_restrictions`, so the tunnel IP is deliberately
  **NOT** in the primary's `mynetworks` (a compromised VM must not relay through
  us).
- **SRS disabled on the primary — side effect of the O5 test; now a PERMANENT
  decision (2026-07-08).** The O5 scale-to-zero failover restarted the primary
  mailserver and exposed a chronic **postsrsd 1.10 busy-loop**: it
  deterministically spins ~100% CPU without binding `tcp:10001/10002` on any
  restart, and the documented restart/delete remedy no longer heals it.
  Disabled SRS (`ENABLE_SRS=0`) so mail stays durable across restarts. The only
  real fix is postsrsd 2.x (socketmap-only, no official container image → would
  require building `ghcr.io/viktorbarzin/postsrsd` + a sidecar), judged not
  worth it for the ~3 externally-forwarding aliases — **Viktor's decision: SRS
  stays OFF.** Those aliases now forward with the original envelope sender (may
  fail SPF at the destination). Cross-referenced in
  `architecture/mailserver.md` troubleshooting.
- **Outages > 30 days lose queued mail silently** — no DSN can ever leave the
  VM. Stated and accepted (6× better than the status quo).
- Outage mail sits in plaintext on Oracle disk ≤ 30 days — single-tenant but
  off-premises; accepted (same class as Brevo holding outbound today).
- Cloudflare zone lands at 197/200 records; the MTA-STS follow-up (policy
  host found dangling during design — inert today; must list `mx2` when
  fixed) needs 1–2 more → schedule the next record purge proactively.
- `architecture/mailserver.md` §"No Backup MX" superseded at implementation;
  new runbook `docs/runbooks/backup-mx.md` (break-glass SSH from the homelab WAN
  /32, OCI serial console as mid-outage fallback); `vpn.md`'s stale headscale
  claims fixed in passing; the roundtrip probe's failure semantics change (a
  "failing" probe may now mean "delayed via mx2, drains shortly" — noted in alert
  description).
