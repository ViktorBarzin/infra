# Backup MX via Roller Network free Secondary MX — design

Date: 2026-07-04 · Status: design approved pending user review, pre-implementation · ADR: [0019](../adr/0019-backup-mx-roller-network-free-tier.md)

## Goal

Inbound mail for `viktorbarzin.me` must survive homelab outages without loss.
Requirement level (Viktor, 2026-07-04): **never lose mail; delayed delivery is
acceptable; budget is $0**. A store-and-forward backup MX queues mail while the
homelab is down and re-delivers when it returns.

Out of scope, explicitly:

- Reading new mail *during* an outage (would need a deliver-to-mailbox backup —
  rejected in favour of queue-only).
- Outbound mail during outages.
- The "primary up but hard-bouncing 5xx" misconfig class (e.g. broken alias map
  → `550 user unknown`): a backup MX is never consulted when the primary
  answers. That is a separate hardening/alerting track.

## Current state and gap

- Single MX: `mail.viktorbarzin.me` (pri 1) → `176.12.22.76` → pfSense HAProxy
  (PROXY v2) → mailserver pod. No backup MX — documented decision in
  [`architecture/mailserver.md`](../architecture/mailserver.md) §"No Backup MX"
  (2026-04-12), which this design supersedes (ADR-0019).
- Only protection today: sender MTAs queue and retry, typically 1–5 days.
  Loss vectors: outages longer than a sender's retry window, and senders with
  unusually short retry policies.
- Prior art: **ForwardEmail** relay abandoned 2026-04-12 (its forced
  anti-spoofing rejected legitimate forwarded mail); **Cloudflare Email
  Routing** rejected (pass-through only, no queue); **Dynu** ($9.99/yr) was the
  doc-flagged fallback; **mailflare** (hieunc229) evaluated and rejected
  2026-07-04 (memory #7148).

## Decision

Adopt **Roller Network free-tier Secondary MX** (`mail.rollernet.us` +
`mail2.rollernet.us`) as a store-and-forward backup MX. Rationale (full
alternatives in ADR-0019):

- Purpose-built queue relay: **3-week queue**, sliding retry (15 min doubling
  to a max 1-week interval), queue storage not counted against the account.
- Spam filtering on secondary MX is **optional and off by default** ("little to
  no spam filtering" per their FAQ) — avoids the ForwardEmail failure class.
- **Catch-all compatible**: their valid-user table supports a default *allow
  any* ("catch-all/dropbox") action, preserving the `@viktorbarzin.me → spam@`
  infinite-alias pattern. New domains default to *deny* — must be flipped
  explicitly at setup.
- Free; unlimited domains; config API; "Accept and Hold" mode usable for
  planned maintenance windows.

## Architecture

Normal operation (unchanged): senders resolve MX, prefer pri 1
`mail.viktorbarzin.me`, deliver directly. Rollernet sits idle. (Spammers
deliberately targeting the backup MX get relayed to the primary immediately —
see failure modes.)

Outage: senders fail to connect to pri 1 → fall back to pri 20
`mail{,2}.rollernet.us` → Rollernet accepts (allow-any user table), queues up
to 3 weeks, retries the primary on a sliding schedule → queue drains
automatically after recovery, entering via the standard external path (pfSense
HAProxy → `:2525` postscreen, PROXY v2), then rspamd → Dovecot as usual.

```
                         ┌── pri 1  mail.viktorbarzin.me ──► pfSense HAProxy ──► mailserver pod
sender MTA ──► MX lookup ┤                                                        ▲
                         └── pri 20 mail.rollernet.us ─┐                          │ retry ≤ 3 weeks
                             pri 20 mail2.rollernet.us ┴─► Rollernet queue ───────┘
                                                           (only used when pri 1 unreachable)
```

## Rollernet account & configuration (out-of-band SaaS, like Brevo)

- Account email: **`rollernet@viktorbarzin.me`** (Viktor, 2026-07-04; resolves
  via catch-all → `spam@`). Known circularity: during an outage their
  notifications to this address are themselves queued (at their side) until
  recovery. Accepted — credentials and config live in Vault and the runbook
  documents ACC access; nothing operational depends on receiving their mail
  mid-outage.
- Credentials → Vault `secret/viktor` (`rollernet_password`, plus API key if
  minted).
- Domain `viktorbarzin.me` in **Secondary MX** mode; valid-user table default
  action = **allow any** (catch-all).
- `abuse@` / `postmaster@` must be deliverable (their RFC requirement) — the
  catch-all already satisfies this.
- Record their **relay source CIDRs** from the post-signup Resource Access page
  (feeds the whitelist below). Their published mail ranges as of 2026 include
  `162.216.242.0/24` and `72.51.58.0/24` — confirm the authoritative list in
  the ACC.

## Our-side changes (all Terraform; worktree → master → CI apply)

1. **DNS** — `stacks/cloudflared/modules/cloudflared/cloudflare.tf`: add two MX
   records for the zone apex, `mail.rollernet.us` and `mail2.rollernet.us` at
   equal preference **20** (primary record untouched at pri 1). Implementation
   checks: (a) their MX-setup help page has a loop-avoidance rule about
   priority layout — confirm 1/20/20 matches their prescription post-signup;
   (b) **the zone sits near Cloudflare's Free-plan 200-record cap** (commit
   `1a63fee4` dropped 6 names for headroom) — verify ≥2 free slots before
   apply.
2. **Postscreen whitelist** — `stacks/mailserver/modules/mailserver/main.tf`:
   mount a `postscreen_access.cidr` (permit Rollernet CIDRs) via the existing
   config ConfigMap and set `postscreen_access_list =
   permit_mynetworks, cidr:/tmp/docker-mailserver/postscreen_access.cidr` on
   the `:2525` alt listener (in `user-patches.sh`, where the listener is
   defined). Rationale: their relays must not be DNSBL-scored or
   pregreet-tested — queue drains would tempfail/deferred otherwise.
3. **rspamd SPF/DMARC exemption** — same stack, via the established
   `override.d`/`local.d` ConfigMap-mount pattern (as `dkim_signing.conf`
   today): exempt the Rollernet CIDRs from **SPF and DMARC scoring only**
   (relayed mail arrives from their IPs, so envelope SPF legitimately fails —
   the exact ForwardEmail lesson applied on our side). Content, AV, Bayes and
   DKIM verification stay fully active; DKIM-signed senders still validate
   end-to-end through the relay.
4. **Monitoring** — blackbox DNS assertion that the MX set contains all three
   hosts (drift guard, same pattern as `viktorbarzin-apex-probe`); alert on
   drift. Optional informational probe: TCP:25 reachability of
   `mail.rollernet.us` (their uptime, weekly cadence, no paging).
5. **Docs (same commit as implementation)** — rewrite `mailserver.md` §"No
   Backup MX" (decision superseded by ADR-0019, new inbound flow + DNS table +
   monitoring rows), add `docs/runbooks/backup-mx-rollernet.md` (ACC queue
   inspection, post-outage drain verification, Accept-and-Hold for planned
   maintenance, overage semantics, whitelist upkeep if their CIDRs change).

### MTA-STS finding (no action in this change)

`_mta-sts.viktorbarzin.me TXT "v=STSv1; id=20260412"` is published, but
`mta-sts.viktorbarzin.me` has **no public DNS record and nothing serves the
policy file** → per RFC 8461 senders that see the TXT fail the HTTPS policy
fetch and proceed as if no policy exists. MTA-STS is inert today (docs-vs-live
mismatch vs the mailserver.md DNS table). Whenever it is fixed properly, the
policy's `mx:` list MUST include `mail.rollernet.us` and `mail2.rollernet.us`,
or MTA-STS-enforcing senders will refuse the backup path. Tracked as a
follow-up, not part of this design.

## Validation gates (in order; any failure → stop and report)

| # | Gate | Method | Failure handling |
|---|------|--------|------------------|
| G1 | Free tier still includes Secondary MX (2026) | Signup + ACC | Decision returns to Viktor: Dynu $9.99/yr vs Rollernet Basic $30/yr vs Oracle-VM self-host |
| G2 | 10 MB/day overage semantics: locked domain answers **4xx (defer)** not 5xx (bounce) | Their docs/support ticket before DNS golive | If 5xx: decision returns to Viktor (paid tier lifts cap, or accept the risk window) |
| G3 | STARTTLS on their MX hosts (cert quality) | `openssl s_client -starttls smtp -connect mail.rollernet.us:25` | Informational now (blocks only the future MTA-STS fix) |
| G4 | Authoritative relay CIDRs published | ACC Resource Access page | Whitelist (changes 2–3) MUST be applied **before** the MX records go live — ordering guard |
| G5 | Live failover test | See below | Debug or roll back (remove MX records) |

**G5 live failover test**: `presence claim service:mailserver` → scale
mailserver deployment to 0 (≈30 min window) → send probes from Gmail and via
Brevo API → confirm both queue in Rollernet ACC → scale back to 1 → verify
clean drain: delivered to `spam@`/target mailbox, headers show no SPF/DMARC
penalty and no postscreen interference, DKIM still validates. Also verify the
E2E roundtrip probe recovers on its own.

## Failure modes

Covered: cluster/pod outages, pfSense/power/ISP outages, WAN IP changes (queue
holds while DNS is fixed), multi-day outages ≤ 3 weeks, short-retry senders.

Not covered (out of scope, above): primary-up-but-5xx misconfigs; outbound;
mid-outage mailbox access.

Newly introduced, accepted:

- **Plaintext queue at a third party** during outages (same trust class as
  Brevo holding outbound today).
- **Spam-path bypass**: mail via the backup skips postscreen DNSBL (their IPs
  are whitelisted) and SPF/DMARC scoring; rspamd content/AV/Bayes still apply.
  Slight spam uptick possible during outages; catch-all absorbs to `spam@`.
- **10 MB/day cap** mid-outage → domain locks until midnight PT (severity
  depends on G2: defer = harmless delay at sender; bounce = loss → gate).
- Rollernet outage while primary is also down = status quo ante (sender
  retries), never worse than today.

## Rollback

Remove the two MX records (TTL is automatic/low) and disable the domain in the
ACC. Whitelist + rspamd exemption are inert without the MX records and may be
reverted in the same commit or left for a retry.
