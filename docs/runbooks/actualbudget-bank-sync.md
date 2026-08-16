# Runbook — Actual Budget bank sync

Covers the nightly GoCardless import for both Actual Budget instances: how it
works, how to tell whether it is genuinely working, and how to diagnose the
failure modes we have actually seen.

## The two syncs are different things

Actual Budget has two independent syncs. Conflating them costs a lot of time.

1. **Bank sync** — GoCardless → actual-server, driven by the
   `bank-sync-<user>` CronJob (`0 0 * * *`, namespace `actualbudget`) hitting
   `POST /banksync` on `jhonderson/actual-http-api`. It syncs only accounts that
   are open and on-budget (`closed == false && offbudget == false`). This
   runbook is about that one.
2. **File sync** — browser ↔ actual-server CRDT. The web error "Syncing has
   been reset on this cloud file…" belongs here, not to bank sync. Click
   **Revert** to re-download the authoritative server copy; never "upload this
   file to be the latest version", which pushes a stale browser copy over good
   server data.

## Layout

| Piece | Where |
|---|---|
| CronJobs | `bank-sync-viktor`, `bank-sync-anca` (ns `actualbudget`) |
| Terraform | `stacks/actualbudget/factory/main.tf` (the CronJob is an inline `/bin/sh` heredoc) |
| Servers | `actualbudget-{viktor,anca}` — `actualbudget/actual-server` |
| API | `actualbudget-http-api-{viktor,anca}` — `jhonderson/actual-http-api`, svc `budget-http-api-<user>:80` → port 5007 |
| Metrics | Pushgateway job `bank-sync-<user>` |
| Credentials | literals in the CronJob spec (`SYNC_ID`, `API_KEY`) |

Both images are Keel-managed (`keel.sh/policy=minor`); the Terraform `tag` /
`http_api_tag` values are create-time seeds only. Keep the seeds level with live
— see the comment block in `stacks/actualbudget/main.tf`.

## Reading the budget file directly

The http-api pod holds a decrypted SQLite copy of the budget, which is the
fastest way to answer "did the import actually do the right thing".

```sh
POD=$(kubectl get pod -n actualbudget -l app=actualbudget-http-api-viktor -o name | head -1)
kubectl exec -n actualbudget ${POD#pod/} -- ls /data          # find the budget dir
kubectl exec -n actualbudget ${POD#pod/} -- node -e '
  const D = require("/usr/src/app/node_modules/better-sqlite3");   // NOT /app/...
  const db = new D("/data/<budget-dir>/db.sqlite", {readonly: true});
  console.log(db.prepare("select name, account_sync_source, bank_sync_status from accounts where tombstone = 0").all());'
```

Use bound parameters (`?`). Double quotes inside SQL are parsed as identifiers
and will error.

Useful tables: `accounts` (`account_sync_source`, `last_sync`,
`bank_sync_status`), `transactions` (`financial_id`, `acct`, `raw_synced_data`),
`rules`, and `messages_crdt` — whose `timestamp` is
`<ISO8601>-<counter>-<16-hex client id>`, so writes can be attributed to a
client and counted per day.

## Green metrics do not mean the import is correct

The CronJob's success test is the HTTP status of the `/banksync` POST. That
asserts the request succeeded, not that the right rows landed. Two independent
things to check:

- **Is it importing at all?** `BankSyncStale` / `BankSyncAccountStale` cover
  this (48h / 72h thresholds).
- **Is it importing correctly?** `bank_sync_excess_imported_rows` counts live
  transaction rows beyond one per `imported_id`. Steady growth means the import
  is creating duplicates. `BankSyncDuplicateImports` alerts on >20 new excess
  rows in 24h.

`bank_sync_duration_seconds` is the third signal — a normal run is 30–95s.

## Failure mode: nightly re-import loop (2026-08-16)

**Symptom.** Every metric green, transactions visibly importing, but duplicate
rows accumulate every night and some transactions never appear where the user
expects them.

**Mechanism.** A user-defined Actual rule with a `set account` action fires at
import time and moves the freshly-imported row into a different account. Actual's
bank-sync dedupe is scoped to the account being synced:

```sql
SELECT * FROM v_transactions WHERE imported_id = ? AND account = ?   -- account = the sync target
```

The moved copy is therefore invisible to the next night's lookup, a new row is
inserted, the rule moves it again, and the loop repeats for as long as the
transaction stays inside GoCardless's 89-day window (hard-coded in
`@actual-app/core`, `sync.ts` — there is no configuration knob, and
`syncAccount`'s `customStartingDate` is unreachable through this API).

**Diagnosis.**

```sh
# rules that will break dedupe
kubectl exec -n actualbudget <http-api-pod> -- node -e '
  const D = require("/usr/src/app/node_modules/better-sqlite3");
  const db = new D("/data/<dir>/db.sqlite", {readonly: true});
  db.prepare("select id, actions from rules where tombstone = 0").all().forEach(r => {
    const a = JSON.parse(r.actions);
    if (a.some(x => x.field === "acct")) console.log(r.id, r.actions);
  });'
```

```sh
# duplicate load, live
homelab metrics query 'bank_sync_excess_imported_rows'
```

**Fix.** Remove the `set account` action. A rule whose only action is
`set account` has to be deleted outright — Actual rejects an actionless rule.
Via the API (no encryption header, see below):

```sh
DELETE /v1/budgets/{syncId}/rules/{ruleId}
PATCH  /v1/budgets/{syncId}/rules/{ruleId}   # body {"rule": {...,"actions":[...]}} to drop just the action
```

To exclude a transaction from the budget without moving it, use a category or
payee marker plus a report filter. Any `set account` action recreates the loop.

**Cleanup.** Existing duplicates are identified by `financial_id` groups with
more than one live row. Keep the copy whose `acct` is the GoCardless-linked
account that supplied it — `raw_synced_data.account` carries the true source —
and tombstone the rest via `DELETE /v1/budgets/{syncId}/transactions/batch`
with `{"transactionIds": [...]}`. Do the cleanup **after** the rules are fixed;
a keep-rule that is not account-aware will leave the surviving copy outside the
sync target and restart the loop.

## Failure mode: the encryption header makes every request slow

`actual-http-api` branches on the mere presence of the
`budget-encryption-password` header: with it, every request takes the
`downloadBudget()` path — a full re-download, decrypt and ~20 MB backup zip —
instead of the cheap `loadBudget()` + `sync()`. Measured 2026-08-16 on a ~118 MB
budget file: 110,000 ms (timed out) with the header vs 108 ms without.

Neither budget file is end-to-end encrypted (`encrypt_keyid` is null in the
server's `account.sqlite`), so the header buys nothing here and the CronJob no
longer sends it. fire-planner has always called this API without it. Restore the
header if E2E encryption is ever enabled.

Note that `var.budget_encryption_password` is really the server login password —
it is passed as `ACTUAL_SERVER_PASSWORD` on the http-api Deployment. The variable
name predates the distinction.

## Failure mode: a run that never finishes

Before 2026-08-16 neither curl in the CronJob had a timeout and the job had no
`active_deadline_seconds`. With `concurrency_policy = "Replace"`, a run wedged on
a slow budget load sat `Running` until the next day's schedule replaced it —
losing a day's sync while the Pushgateway still showed the previous run's
success. Both curls now carry `--max-time` and the job has a 1800s deadline;
`BankSyncSlow` fires at 300s.

## Accounts that report OK but never reach GoCardless

An account with `account_sync_source IS NULL` has no bank link. The http-api
skips it (`if (acct.bankId && acct.account_id)`), returns 200, and the CronJob
records a success. Viktor has four such accounts (dormant manual ledgers), which
is why `bank_sync_success{job="bank-sync-viktor"}` is pinned at 1. Check
`account_sync_source` before concluding an account is syncing.

## Backups

The actual-server PVCs (`actualbudget-{viktor,anca}-data-encrypted`) are covered
by the host-level 3-2-1 system — `lvm-pvc-snapshot` (daily 03:00, 3-day
retention) and `daily-backup` (daily 05:00, 4-week file-level history); neither
is in the skip-list. There is no in-cluster snapshot mechanism (no Velero, no
VolumeSnapshots). Before any destructive data operation, take a point-in-time
copy anyway — the scheduled cadence can be up to a day stale:

```sh
kubectl cp actualbudget/<http-api-pod>:/data/<budget-dir>/db.sqlite ./<user>-preclean.sqlite
```

The `backups/` directory inside the http-api pod is on the container's ephemeral
layer (the Deployment declares no volume) and does not survive a restart.
