# Runbook: devvm Vault token auto-renewal

**Host:** `devvm` (10.0.10.10), user `wizard`
**Source of truth:** `infra/scripts/vault-token-renew.{sh,service,timer}`
**Live paths:** `~/.local/bin/vault-token-renew`, `~/.config/systemd/user/vault-token-renew.{service,timer}`

## What this is

`wizard@devvm` authenticates to Vault with a **periodic, orphan** token stored
in `~/.vault-token`, instead of a 7-day OIDC login that needed weekly
re-auth. A systemd **user** timer renews it daily so it never expires.

| Property | Value |
|---|---|
| `display_name` | `token-devvm-wizard` |
| `period` | `768h` (32 days) |
| `explicit_max_ttl` | `0` (no hard cap) |
| `policies` | `default`, `sops-admin`, `vault-admin` |
| `orphan` | `true` (not revoked when any parent expires) |

Periodic tokens have no max-TTL; they only need renewing once per `period`.
Daily renewal leaves a 32× margin. **If devvm is decommissioned and the timer
stops, the token self-expires within ~32 days** — deliberately, unlike a root
token which would live forever (this is the security trade-off Viktor chose:
periodic + renewer over a never-expiring root token).

## Deploy on a fresh devvm

The renewer is a host-side script + user systemd units, deployed manually (same
model as the other `infra/scripts/` host scripts). From a checkout of the repo
**as user `wizard` on devvm**:

```bash
cd ~/code/infra/scripts
install -m 0755 vault-token-renew.sh ~/.local/bin/vault-token-renew   # strip .sh
install -m 0644 vault-token-renew.service vault-token-renew.timer ~/.config/systemd/user/

# user manager must survive logout, so the daily timer fires headless
loginctl enable-linger "$USER"

systemctl --user daemon-reload
systemctl --user enable --now vault-token-renew.timer
```

Then mint the token (one-time, interactive — see below). The script and units
carry no secret; only the token itself is sensitive and stays out of git.

## Mint / re-mint the token

Requires an interactive OIDC login (browser), so it can't run unattended:

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me
vault login -method=oidc
vault token create -orphan -period=768h \
  -policy=vault-admin -policy=sops-admin -display-name=devvm-wizard \
  -field=token > ~/.vault-token
chmod 600 ~/.vault-token
```

Vault prefixes the display name, so it becomes `token-devvm-wizard` (which is
what the drift guard checks for). `-orphan` is essential: a child of the 7-day
OIDC token would be revoked when that parent expired.

## Health check

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me
vault token lookup | grep -E 'display_name|period|explicit_max_ttl|policies'
# expect: display_name token-devvm-wizard, period 768h, explicit_max_ttl 0s,
#         policies [default sops-admin vault-admin]

# authoritative write-capability check (do NOT trust the policies field alone —
# an OIDC token shows policies=[default] but carries vault-admin via identity):
vault token capabilities secret/data/viktor   # expect create/update/.../sudo

# renewer health
systemctl --user list-timers | grep vault-token-renew     # next/last run
tail -5 ~/.local/state/vault-token-renew.log              # recent results
```

A healthy log line looks like:
`<ts> OK renewed (dn=token-devvm-wizard ttl=2764800s)` (ttl 2764800s = 768h).

## Drift guard & recovery

`~/.vault-token` is the Vault CLI's default token sink, so **any** `vault login`
overwrites it. Two confirmed clobber vectors:

1. `vault login -method=oidc` → replaces it with a 7-day OIDC token (the renewer
   can't push past the OIDC role's 7-day `token_max_ttl`).
2. A stray `vault login -method=kubernetes` (e.g. a headless agent flow) →
   writes a read-only `kubernetes-woodpecker-default` token (can read Vault but
   **cannot** write `secret/*`). This happened 2026-06-05 and went unnoticed for
   two days — reads worked, writes silently 403'd.

To stop the renewer from silently keeping a foreign token alive, it runs a
**drift guard** first: it refuses to renew unless the token is
`token-devvm-wizard` **and** carries `vault-admin`. On drift it logs loudly and
exits non-zero (the systemd unit goes `failed`) rather than renewing someone
else's token. Symptom in the log:

`<ts> DRIFT: ~/.vault-token is dn=... policies=... Refusing to renew a foreign token. Re-mint: ...`

**Recovery: re-mint** (the DRIFT log line contains the exact command) — run the
[mint/re-mint](#mint--re-mint-the-token) block. The drift guard detects but does
**not** auto-recover (a deliberate scope choice — version-only, no self-heal);
recovery is the manual re-mint above.

## Tests

`infra/scripts/test-vault-token-renew.sh` unit-tests the drift-guard decision
and the lookup-JSON parsers (including the exact 2026-06-05 woodpecker-clobber
case). Run: `bash infra/scripts/test-vault-token-renew.sh`.
