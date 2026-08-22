# Post-mortem — Actual Budget bank sync re-imported the same transactions nightly

**Date found:** 2026-08-16
**Duration:** Viktor's instance from ~2024-12; Anca's worsened from 2026-06-14.
**Severity:** SEV3 — no data loss, no outage. One user's ledger was materially
incomplete and both budget files accumulated duplicate rows indefinitely.
**Detection:** Viktor noticed the sync "hadn't worked for more than two weeks".
No alert fired at any point.

## What happened

The nightly bank sync ran every night, returned HTTP 200 for every account, and
kept every metric green. It was also re-importing transactions it had already
imported — about 93% of the rows it created each run were duplicates of rows
already in the file.

A user-defined Actual rule with a `set account` action fires at import time and
moves the freshly-imported row into a different account. Actual's bank-sync
dedupe is scoped to the account being synced (`WHERE imported_id = ? AND account
= ?`, with `account` = the sync target). The moved copy is invisible to the next
night's lookup, so a new row is inserted, the rule moves it again, and the cycle
repeats for as long as the transaction stays inside GoCardless's 89-day window.

Twelve rules carried that action: two on Viktor's instance, ten on Anca's.

Anca's ten all pointed at an account that was **deleted on 2026-06-14**. Since
then her matched transactions were routed into a tombstoned account, so 9,350 of
her 12,818 live transactions resolved to `account IS NULL` and were invisible in
every view. Those rows represented 378 distinct real transactions genuinely
missing from her ledger — the closest match to the original report.

## Impact

| | Viktor | Anca |
|---|---|---|
| Rows in the rule-target account | 2,430 | 9,350 |
| Distinct real transactions behind them | 493 | 378 |
| Excess duplicate rows | 1,648 | 8,984 |
| Growth rate | +37/night | +178/night |
| Transactions invisible in the ledger | 0 | 378 |

No financial data was overwritten or destroyed. Reconciliation state was intact
(Viktor had exactly one `reconciled` 1→0 transition ever, dated 2025-02-02; Anca
had none). Category, amount, date and note values were never changed by the loop
— the runs INSERTed rather than rewrote. Envelope-budget maths and reports were
insulated because both rule-target accounts were off-budget and the reports
filter off-budget accounts out.

Downstream consumers were unaffected: fire-planner reads only on-budget monthly
category spend, and there were no same-`financial_id` duplicates in on-budget
non-tombstoned accounts for either user.

## Why nothing alerted

The CronJob's only success criterion was `HTTP_CODE = 200` on the `/banksync`
POST. That asserts the request succeeded, not that the import was correct.
Actual computes `{errors, newTransactions, matchedTransactions, updatedAccounts}`
internally, but `api/bank-sync` keeps only `errors` and the http-api route
discards even that, returning a fixed `{"message": "Bank sync started"}`.

Both existing alerts — `BankSyncStale` (48h) and `BankSyncAccountStale` (72h) —
detect the *absence* of syncing. Nothing measured whether the rows landing were
new. A second, narrower gap: the CronJob pushed
`bank_sync_account_last_success_timestamp` only for accounts that returned 200,
relying on Pushgateway preserving values for absent label sets. A Pushgateway
POST replaces the whole metric family for a job, so a failing account's series
vanished rather than aging — and a series that disappears can never go stale.
`BankSyncAccountStale` could not fire on a partial failure.

## Contributing factors

Two things made this harder to see than it needed to be.

A genuine bank-sync outage from 2026-07-05 to 2026-07-24 (both users, GoCardless
re-authorization) created a quiet period. Measuring the loop's "baseline" against
that window made a normal rate look like a regression starting 2026-07-24, which
pointed the first investigation at the 2026-07-25 Keel full-auto upgrade
(`actualbudget: enable full-auto upgrades`). That was a coincidence of dates:
Viktor's loop runs continuously from 2024-12, and the first image change since
April was 2026-07-25T11:31:17Z, which postdates the apparent inflection. The
upgrade decision at `stacks/actualbudget/main.tf:79-92` is not implicated.

Separately, `actual-http-api` branches on the presence of the
`budget-encryption-password` header and takes a full `downloadBudget()` +
decrypt + ~20 MB backup-zip path when it is present. The CronJob always sent it.
Neither budget file is actually end-to-end encrypted, so the header bought
nothing and cost a great deal: measured 110,000 ms (timed out) with the header vs
108 ms without, on Anca's ~118 MB file. Anca's 2026-08-16 run was still hung on
that path 18 minutes in with zero log output when it was found, and neither curl
had a timeout — with `concurrency_policy = "Replace"` it would have sat there
until the next day's schedule, losing a day's sync while the Pushgateway still
showed the previous run's success.

## Resolution

Budget data (not Terraform — these are user rules, and the fix leaves no trace in
the repo, which is why this post-mortem and the runbook exist):

- Removed the `set account` action from all 12 rules. Eleven had it as their only
  action and were deleted; one kept its category action.
- Restored Anca's 378 orphaned transactions into the GoCardless-linked accounts
  that supplied them, resolved via `raw_synced_data.account`.
- Moved Viktor's 36 in-window transactions into their true accounts (net
  −£420.00 — internal transfers, mostly self-cancelling pairs) and tombstoned the
  duplicates. His 450 out-of-window historical rows stay where they were.
- Tombstoned the accumulated duplicate rows on both instances.

Terraform (`stacks/actualbudget/`, `stacks/monitoring/`):

- Dropped the `budget-encryption-password` header from both CronJob curls.
- Added `--max-time` to every curl and `active_deadline_seconds = 1800` to the job.
- Added a duplicate-import check → `bank_sync_duplicate_imported_ids`,
  `bank_sync_excess_imported_rows`, `bank_sync_dupcheck_success`.
- The per-account failure branch now carries the previous timestamp forward, so
  `BankSyncAccountStale` can actually reach its threshold. Emitting `0` was
  considered and rejected: `(time() - 0) > 259200` is trivially true and would
  fire after any single failed run, which the deliberate no-`BankSyncFailing`
  design rejects (PSD2 quota makes isolated per-account failures routine).
- New alerts `BankSyncDuplicateImports` (`delta`, not `increase` — the gauge
  drops when duplicates are cleaned up and `increase` reads that as a counter
  reset), `BankSyncDupCheckFailing`, `BankSyncSlow`.
- Parameterised the http-api image (was a hardcoded `latest`) and moved both
  version seeds 26.6.0 → 26.8.1. The old seeds sat below the migration floor:
  both budget files carry migrations first shipping in v26.7.0, so a recreate at
  26.6.0 would have started a server older than the file it opens and reproduced
  the documented "client too old" break.

## What we would do differently

**A success metric should measure the outcome, not the call.** Every signal here
was green for roughly twenty months. The specific lesson is narrow and
transferable: when a job's job is to *change data*, assert something about the
data, not only about the HTTP status of the request that changed it. The
duplicate-import check is cheap (~60–2000 ms, reads the local budget file, no
GoCardless quota) and would have caught this on day one.

**A quiet period is not a baseline.** The 2026-07-05→07-24 outage made the
following weeks look like a regression and sent the first pass after a version
upgrade. Checking how far back the behaviour actually extended — trivially
visible in `messages_crdt` — would have ruled that out immediately.

## Open questions

- Why Anca's "Ignore" account was deleted on 2026-06-14 while ten live rules
  still pointed at it. It was one tombstone write alongside 30,289 others that
  day.
- The cause of the 2026-07-05→07-24 degradation is inferred from browser
  re-link writes to the accounts CRDT, not confirmed. Both users dropped out
  simultaneously right after the 07-04 run, which does not fit independent
  per-user 90-day consent clocks. Confirming would need a GoCardless API call.
- A nightly flip-flop on `imported_description` for existing on-budget rows
  (Anca 794 changes across 53 rows, mostly Revolut GBP; Viktor 61 across 5) —
  e.g. `Anca Elena Milea` ↔ `Anca Elena Milea (GB16 XXX 6108)` alternating.
  Real, unexplained, display-only, not addressed by any change above.
- Why Anca's request took >110 s with the encryption header while Viktor's took
  340 ms, given near-identical file sizes. Removing the header makes both fast.
- The `kube-apiserver` restarted once (exit 137) during the cleanup, at
  2026-08-16T00:45:26Z. No actualbudget pod restarted, and the work was
  app-level HTTP against a pod on node4 rather than apiserver load, so a causal
  link is not established — the exec session died because the apiserver did, not
  the other way round. `KernelOOMKiller` and `HighSystemLoad` were already firing
  before the work started.
