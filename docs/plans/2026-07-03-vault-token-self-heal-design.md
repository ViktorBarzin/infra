# Vault Token Renewer Self-Heal Design

**Date**: 2026-07-03
**Status**: Approved (brainstorm complete; implementation pending)
**Owner**: wizard@devvm
**Supersedes**: the "version-only, no self-heal" scope choice recorded in
`docs/runbooks/vault-token-renew-devvm.md` (2026-06-07)

## Problem

`wizard@devvm` holds a maintenance-free periodic Vault token
(`token-devvm-wizard`, `period=768h`, renewed daily by the
`vault-token-renew` user timer) precisely so no weekly re-login is needed.
But `~/.vault-token` is the Vault CLI's default token sink, so any
`vault login -method=oidc` — which the infra docs themselves instruct before
applies — overwrites it with a 7-day OIDC token. The renewer's drift guard
(deliberately detect-only) then refuses to renew the foreign token and fails
the unit daily, into a log nobody watches.

Observed consequence: a self-perpetuating weekly-expiry loop. The OIDC token
expires after 7 days → Vault 403s → the natural response is another
`vault login -method=oidc` → clobbers again. Drift persisted unnoticed
2026-06-18 → 06-26 and 2026-06-29 → 07-03 (memory #7121); Viktor experienced
it as "the token expires maybe once a week".

**Goal**: `vault login -method=oidc` becomes harmless on devvm. The renewer
converts any admin-capable clobber back into the permanent periodic token,
unattended. (Chosen over "never log in" doc-fixes and over instant path-unit
healing — see Alternatives.)

## Decisions

| # | Decision | Notes |
|---|----------|-------|
| 1 | Heal in the existing renewer's drift branch, at its nightly run | ~20-line diff to an already-tested script; no new units. A few-hours window holding the 7-day OIDC token is harmless (heal window 24h ≪ 7d TTL) |
| 2 | Heal = *attempt* re-mint using the foreign token itself; let Vault's 403 decide | No policy-list guessing — identity-vs-token-policies burned us before (memory #4211). OIDC tokens carry `vault-admin` via `identity_policies`, so the create succeeds |
| 3 | Weak foreign token (create denied) → keep today's loud DRIFT failure | A read-only clobber (e.g. the 2026-06-05 `kubernetes-woodpecker-default` incident) signals a misbehaving agent flow; auto-papering over it would hide the offender. Log gains a "heal denied — investigate what wrote it" suffix |
| 4 | Do NOT revoke the clobbering OIDC token | It may still back the user's live login session; it ages out in 7 days on its own |
| 5 | After a successful heal, revoke stale `token-devvm-wizard` accessors | Anti-sprawl: each heal would otherwise strand the previous periodic **admin** token server-side for up to 32 days. Walk `auth/token/accessors`, revoke every `display_name=token-devvm-wizard` except the just-minted one. Runs only on heal (rare), never on the happy path |
| 6 | Minted-token sanity check before writing the file | Look up the new token; require `display_name=token-devvm-wizard`. Write via temp file + `mv` + `chmod 600` so a failed mint can never truncate `~/.vault-token` |
| 7 | Keep timer cadence (daily) and all happy-path behavior unchanged | |
| 8 | No notification plumbing in this change | devvm alerting is tracked separately (beads `code-aslh`). Heal events are logged; heal-denied/FAIL still fail the unit |

## Behavior matrix

| Token found in `~/.vault-token` | Before | After |
|---|---|---|
| Our periodic token | renew-self, log `OK` | unchanged |
| Foreign, admin-capable (OIDC login) | log `DRIFT`, exit 1 | re-mint periodic token with it, sanity-check, atomic write, revoke stale periodic accessors, log `HEALED: re-minted from foreign dn=<dn> (revoked N stale)`, exit 0 |
| Foreign, weak (read-only k8s clobber) | log `DRIFT`, exit 1 | log `DRIFT … heal denied — foreign token lacks create authority; investigate what wrote it`, exit 1 |
| Vault unreachable / lookup fails | log `FAIL`, exit 1 | unchanged |

Re-mint command (identical to the manual recovery the DRIFT log already
prescribes):

```
vault token create -orphan -period=768h \
  -policy=vault-admin -policy=sops-admin -display-name=devvm-wizard
```

## Testing

- **Unit** (`scripts/test-vault-token-renew.sh`, existing source-the-functions
  harness): new pure functions for (a) the stale-accessor revoke filter
  (match on `display_name`, exclude the current accessor) and (b) the
  minted-token sanity predicate; regression cases for the existing drift
  predicate stay green.
- **Live, post-deploy** (on devvm):
  1. Mint a fake 1h admin token (`-display-name=fake-oidc`,
     `-policy=vault-admin -policy=sops-admin`), write to `~/.vault-token`,
     start the service → expect `HEALED`, file holds `token-devvm-wizard`.
  2. Mint a fake 10m no-privilege token (`-policy=default`), write it, start
     the service → expect `DRIFT … heal denied`, unit `failed`; restore real
     token.
  3. Revoke both fakes; one-off sweep of stale periodic accessors left by the
     June 26 / July 3 manual re-mints.

## Docs & rollout

- Same commit rewrites the runbook's "Drift guard & recovery" section:
  self-heal is the recovery for admin-capable clobbers; manual re-mint remains
  only for weak clobbers (or a dead token with no admin-capable replacement in
  the file).
- `vault login -method=oidc` instructions across the docs stay as-is — the
  login is now harmless by design.
- Deploy per the runbook's manual model: `install -m 0755` to
  `~/.local/bin/vault-token-renew`. Units unchanged — no daemon-reload.
- After landing: update memories #4204/#4211 (gotcha now self-healing).

## Alternatives considered

- **Instant heal** (systemd path unit + protected source-copy of the token):
  strictly more capable (seconds-latency, heals weak clobbers too, zero
  re-minting), but 2 new units + a second secret file + inotify re-trigger
  edge cases — machinery disproportionate to the residual risk. Revisit only
  if the few-hour heal window ever bites.
- **Vault CLI `token_helper` interception**: right interception point in
  theory, but a helper bug breaks every `vault` CLI call, Terraform reads
  `~/.vault-token` natively anyway, and it adds latency inside login. Rejected.
- **Docs-only ("never log in")**: rejected by user — the login should keep
  working, not become forbidden knowledge.
- **Raise the OIDC role's 7-day `token_max_ttl`**: shared role, affects every
  OIDC user; rejected previously for the same reason (memory #4205).
