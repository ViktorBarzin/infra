# Inbound mail gets a self-hosted store-and-forward backup MX on Oracle Always-Free

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
  publishes no commitment that inbound 25 stays open. Mitigations:
  **Pay-As-You-Go conversion is a required prerequisite** (exempts idle
  reclamation, stays $0), a recurring inbound-25 probe, `BackupMxDown`, and
  the queue being empty outside outages (a surprise reclamation loses
  coverage, never mail). Home region is fixed at signup — Frankfurt, chosen
  once.
- The drain stream bypasses `reject_unknown_client_hostname`, anvil limits,
  and rspamd's reject tier for one /32; DKIM verification, SPF/DMARC (against
  the original IP via `external_relay`), and content scoring stay on — spam
  arriving via the backup is tagged and folded to Junk, never bounced. The VM
  is deliberately NOT in the primary's `mynetworks` (a compromised VM must
  not relay through us).
- **Outages > 30 days lose queued mail silently** — no DSN can ever leave the
  VM. Stated and accepted (6× better than the status quo).
- Outage mail sits in plaintext on Oracle disk ≤ 30 days — single-tenant but
  off-premises; accepted (same class as Brevo holding outbound today).
- Cloudflare zone lands at 197/200 records; the MTA-STS follow-up (policy
  host found dangling during design — inert today; must list `mx2` when
  fixed) needs 1–2 more → schedule the next record purge proactively.
- `architecture/mailserver.md` §"No Backup MX" superseded at implementation;
  new runbook `docs/runbooks/backup-mx.md` (incl. OCI console break-glass);
  `vpn.md`'s stale headscale claims fixed in passing; the roundtrip probe's
  failure semantics change (a "failing" probe may now mean "delayed via mx2,
  drains shortly" — noted in alert description).
