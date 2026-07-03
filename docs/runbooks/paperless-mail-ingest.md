# Paperless-ngx Mail Ingest (docs@viktorbarzin.me)

Last updated: 2026-07-03 (initial build)

Forward any email with document attachments to **`docs@viktorbarzin.me`** and
paperless-ngx ingests the attachments, owned by the paperless account mapped
from the **sender** (From) address. Built entirely from existing parts: a
docker-mailserver mailbox + Dovecot sieve, and paperless-ngx's native mail
consumer (the same machinery as the `utility:` rules).

## Flow

```
family member forwards email ──> MX ──> docker-mailserver
    │  postfix virtual: docs@ has an explicit self-alias (extra/aliases.txt),
    │  so the @domain catch-all (→ spam@, swept by TripIt) does NOT apply
    ▼
Dovecot LMTP delivery to docs@
    │  per-user sieve (docs@viktorbarzin.me.dovecot.sieve): sender NOT in
    │  allowlist → discard (decision 2026-07-03: unmatched = ignore & delete)
    ▼
docs@ INBOX ── paperless-ngx mail task (every 10 min, PAPERLESS_EMAIL_TASK_CRON
    │          default) applies mail rules in order: filter_from = <sender>
    │          → consume attachments (ALL parts incl. inline — see design
    │          notes: Apple Mail marks real PDFs inline), owner = mapped user,
    │          tag = email-ingest, title = mail subject
    ▼
consumed mail is MOVED to the "Processed" IMAP folder (audit trail);
INBOX stays empty in steady state
```

## Sender → paperless account map (as built)

| Sender (From)            | Paperless user | Rule            |
|--------------------------|----------------|-----------------|
| me@viktorbarzin.me       | root (id 3)    | forward: Viktor (me@) |
| vbarzin@gmail.com        | root (id 3)    | forward: Viktor (gmail) |
| viktorbarzin@meta.com    | root (id 3)    | forward: Viktor (meta) |
| ancaelena98@gmail.com    | anca (id 4)    | forward: Anca   |
| emil.barzin@gmail.com    | emo (id 7)     | forward: Emo    |

The map lives in **two places by design** — keep them in sync:

1. **Delivery gate (infra, Terraform):**
   `stacks/mailserver/modules/mailserver/extra/docs-at-viktorbarzin.me.dovecot.sieve`
   — senders not listed here are discarded at delivery (spam control + the
   "ignore and delete unmatched" behaviour; paperless cannot express
   "delete without ingesting", so this must happen before the mailbox).
2. **Owner map (paperless DB, via API/UI):** one mail rule per sender on the
   `docs@viktorbarzin.me` mail account. DB-state like workflows — NOT
   Terraform.

## Add a family member / sender

1. Add the address to the sieve allowlist file above; commit; apply the
   `mailserver` stack (normal apply is enough — the sieve CM key is not under
   `ignore_changes`; Reloader restarts the pod).
2. Clone an existing `forward:` mail rule in the paperless admin UI
   (Mail → Rules) or via API, changing `filter_from` and the rule **owner**
   (documents are owned by the rule owner — `assign_owner_from_rule=true`).
   Keep: action = Move to `Processed`, attachment type = **process all files
   including inline** (`attachment_type=2` — NOT attachments-only, see design
   notes), consumption scope = attachments only, tag `email-ingest`, order
   after the existing rules.

## Operations

- **Trigger a fetch immediately** (instead of waiting ≤10 min):
  `kubectl -n paperless-ngx exec deploy/paperless-ngx -c paperless-ngx -- s6-setuidgid paperless python3 manage.py mail_fetcher`
  The `s6-setuidgid paperless` is **required**: `kubectl exec` runs as root, and a
  root-run fetcher downloads attachments root-owned into the scratch dir, which
  the celery consumer (uid 1000) then can't read — `PermissionError` on
  `/tmp/paperless/paperless-mail-*/...`, consume task FAILURE (hit during the
  2026-07-03 build E2E). The mail correctly stays in INBOX for retry (the move
  action is a chord callback on successful consumption). Recover: `rm -rf
  /tmp/paperless/paperless-mail-*` (as root) and let the next scheduled fetch
  re-process.
- **Mailbox credentials:** Vault `secret/platform` → `mailserver_accounts`
  JSON, key `docs@viktorbarzin.me` (also used by the paperless mail account).
- **Inspect the mailbox:**
  `python3 -c` IMAP to `mailserver.mailserver.svc.cluster.local:993` (in-cluster,
  from a pod) or `mail.viktorbarzin.me:993` (externally / devvm).
- **Paperless-side logs:** `kubectl -n paperless-ngx logs deploy/paperless-ngx | grep -i mail`
  (also Loki, ns `paperless-ngx`). Rule/account state: `GET /api/mail_rules/`,
  `GET /api/mail_accounts/` with the admin token
  (k8s secret `paperless-ngx-secrets`, field `api_token`).
- **Account/mailbox provisioning:** adding/rotating anything in
  `mailserver_accounts` requires the ConfigMap replace workaround —
  `scripts/tg apply mailserver -- -replace=module.mailserver.kubernetes_config_map.mailserver_config`
  — because `postfix-accounts.cf` is under `ignore_changes`
  (non-deterministic bcrypt; see the module comment).

## Design notes / caveats

- **Why not the catch-all?** Mail to unknown `@viktorbarzin.me` addresses
  lands in `spam@`, which the TripIt `ingest-plans` CronJob sweeps every
  15 min: it marks everything `\Seen`, LLM-parses mail from linked senders and
  replies with ack/failure emails. Forwarded bank statements would get
  "couldn't parse a trip" replies. `docs@` being a real mailbox bypasses that
  path entirely; TripIt, the `smoke-test@` roundtrip probe, and `dmarc@` are
  untouched.
- **Spoofing:** the sender match is on the From header. Rspamd verifies
  SPF/DKIM/DMARC on inbound mail, but gmail.com publishes `p=none`, so a
  crafted spoof could ingest documents into a family member's account. Accepted
  risk (worst case: unwanted documents appear, visible + deletable in
  paperless).
- **Not PDF-only:** any attachment type paperless supports is consumed
  (PDF, images, Office via the existing tika+gotenberg pipeline).
- **Inline attachments ARE processed (`attachment_type=2`, flipped
  2026-07-03):** the rules originally used attachments-only (1) to skip
  signature logos, but the very first real forward (Apple Mail, Viktor's
  client) attached the invoice PDF with `Content-Disposition: inline` —
  paperless matched the rule, consumed nothing, and recorded
  `PROCESSED_WO_CONSUMPTION` (which, like any ProcessedMail row, blocks that
  UID from ever being re-processed — delete the row via `manage.py shell` to
  retry). Trade-off: signature/inline images in forwards may be ingested as
  junk docs (tagged `email-ingest`, easy to spot). If that gets noisy, add
  `filter_attachment_filename_exclude` patterns to the rules using the
  actually-observed junk filenames — do NOT flip back to attachments-only.
- **No dedicated alerting** (deliberate, 2026-07-03): mail-task errors surface
  in paperless logs; the mailserver inbound path is covered by
  `email-roundtrip-monitor`. Revisit if forwards start silently failing.
- **Workflows:** the global `payslip-webhook` + `claude-mcp-readers
  auto-permission` workflows fire for mail-ingested docs like any other
  consumption source (verified pre-build; payslip receiver does its own
  filtering).

## Rollback

1. Disable/delete the 5 `forward:` mail rules + the `docs@` mail account
   (paperless admin UI or API).
2. Revert the infra commit (aliases.txt entry, sieve file, CM key + mount).
3. Remove `docs@viktorbarzin.me` from Vault `mailserver_accounts`, then apply
   with the `-replace` workaround above. Mail to docs@ then falls back to the
   catch-all (spam@) like any unknown address.
