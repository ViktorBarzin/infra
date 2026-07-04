# Inbound mail gets a free store-and-forward backup MX (Roller Network)

`viktorbarzin.me` has run a single direct MX to the home IP since the 2026-04-12
inbound overhaul, with sender-MTA retry (1–5 days, sender-dependent) as the only
outage protection — a documented "No Backup MX" decision made after ForwardEmail's
forced anti-spoofing rejected legitimate forwarded mail and Cloudflare Email
Routing proved pass-through-only (no queue). Viktor now wants inbound mail to
survive homelab outages **without loss** (2026-07-04): delayed delivery is fine,
mid-outage reading is not required, and the budget is **$0** — which rules out
the doc-flagged Dynu fallback ($9.99/yr).

We adopt **Roller Network's free-tier Secondary MX** (`mail.rollernet.us` +
`mail2.rollernet.us` at equal MX preference 20, primary untouched): a
purpose-built store-and-forward relay with a **3-week queue** (sliding retries,
15 min doubling to 1-week max), **no forced spam filtering** on the secondary
path, and a valid-user table with a default-*allow-any* mode that preserves our
catch-all's infinite ad-hoc aliases. Our side whitelists their relay CIDRs in
postscreen (skip DNSBL/pregreet for queue drains) and exempts them from
SPF/DMARC *scoring* in rspamd — the ForwardEmail lesson applied at the right
layer; DKIM verification and content/AV scanning stay fully active. Go-live is
gated: confirm the free tier still includes Secondary MX, confirm the 10 MB/day
overage lock answers 4xx (defer) rather than 5xx (bounce), capture their
authoritative relay CIDRs, apply the whitelist **before** the MX records, and
finish with a live failover test (mailserver scaled to 0, probes from Gmail +
Brevo, verified queue-and-drain). Design:
[`plans/2026-07-04-backup-mx-rollernet-design.md`](../plans/2026-07-04-backup-mx-rollernet-design.md).

## Considered options

- **Dynu Email Backup ($9.99/yr)** — the previously doc-flagged option; simple,
  but queue lifetime is undocumented (FAQ hints at 12–24 h retry ceilings),
  filtering behaviour is a black box, and it costs money the free requirement
  excludes.
- **Self-hosted VPS relay** (Hetzner ~€50/yr, or Oracle Always-Free at $0) —
  full control (30-day queue, own TLS/MTA-STS story), but a second
  internet-facing pet to patch and monitor; Oracle hard-blocks egress port 25,
  forcing delivery to the primary on a custom port, and idles risk free-tier
  reclamation.
- **Cloudflare Email Routing / mailflare** — no store-and-forward (pass-through
  only) / a terminal inbox on Cloudflare respectively; both previously
  evaluated and rejected (2026-04-12; 2026-07-04, memory #7148).
- **Harden-only** (guard hard-5xx misconfig modes, add paging) — cheaper but
  does not address multi-day outages or short-retry senders; deferred as a
  complementary track, not an alternative.

## Consequences

- Outage mail queues **in plaintext at a third party** for up to 3 weeks —
  accepted; same trust class as Brevo holding our outbound relay traffic.
- The backup path bypasses postscreen DNSBL and SPF/DMARC scoring for
  Rollernet's CIDRs; content/AV/Bayes and DKIM verification still apply. A
  slight spam uptick during outages is possible (catch-all absorbs to `spam@`).
- The free tier's **10 MB/day cap** locks the domain until midnight Pacific
  when exceeded; the G2 gate decides whether that lock defers (harmless) or
  bounces (revisit: paid tier or accept). Overage never affects the primary
  path — only mail arriving via the backup while locked.
- Two more records in a Cloudflare zone already near the Free-plan 200-record
  cap (headroom must be verified at apply time).
- **MTA-STS was found dangling** during design: the `_mta-sts` TXT is published
  but no policy host exists, so MTA-STS is inert today. Any future fix must
  list the Rollernet MX hosts in the policy or enforcing senders will skip the
  backup path.
- `architecture/mailserver.md` §"No Backup MX" is superseded at implementation
  time; a new runbook covers ACC queue inspection, post-outage drain checks,
  and Accept-and-Hold for planned maintenance.
