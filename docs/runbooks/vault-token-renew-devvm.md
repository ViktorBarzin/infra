# Runbook: devvm Vault token auto-renewal

**Host:** `devvm` (10.0.10.10), users `wizard` + `emo` (one deployment per user)
**Source of truth:** `infra/scripts/vault-token-renew.{sh,service,timer}`
**Live paths (per user):** `~/.local/bin/vault-token-renew`, `~/.config/systemd/user/vault-token-renew.{service,timer}`

## What this is

Each devvm user authenticates to Vault with a **periodic, orphan** token stored
in their `~/.vault-token`, instead of a 7-day OIDC login that needed weekly
re-auth (the OIDC role caps `token_max_ttl` at 168h). A systemd **user** timer
renews it daily so it never expires.

**One script, per-user scope.** `vault-token-renew.sh` self-configures on the OS
user (`vtr_resolve_config`): each user's token is scoped to **that user's own
Vault entitlement — never another user's**. The systemd units are identical
across users (`ExecStart=%h/.local/bin/vault-token-renew`); to onboard a user,
add a `case` arm to `vtr_resolve_config` (+ a test case) — an unmapped user
fails loud rather than minting an unknown scope.

| User | `display_name` | `policies` | Can self-heal a clobber? |
|---|---|---|---|
| `wizard` | `token-devvm-wizard` | `default`, `sops-admin`, `vault-admin` | yes — holds orphan-create authority |
| `emo` | `token-devvm-emo` | `default`, `personal-emo` (own tree `secret/emo/*`) | no — fails loud; an admin re-mints |

`emo`'s scope matches emo's OIDC entitlement (entity `emo`, alias
`emil.barzin@gmail.com`, direct policy `personal-emo`) made persistent — no
escalation. Common to all: `period` `768h` (32 days), `explicit_max_ttl` `0`
(no hard cap), `orphan` `true` (not revoked when any parent expires).

Periodic tokens have no max-TTL; they only need renewing once per `period`.
Daily renewal leaves a 32× margin. **If devvm is decommissioned and the timer
stops, the token self-expires within ~32 days** — deliberately, unlike a root
token which would live forever (this is the security trade-off Viktor chose:
periodic + renewer over a never-expiring root token).

## Deploy on a fresh devvm

The renewer is a host-side script + user systemd units, deployed manually (same
model as the other `infra/scripts/` host scripts). Run these **as the target
user on devvm** (self, or `sudo -u <user> ... XDG_RUNTIME_DIR=/run/user/<uid>`
for another user):

```bash
cd ~/code/infra/scripts
install -m 0755 vault-token-renew.sh ~/.local/bin/vault-token-renew   # strip .sh
install -m 0644 vault-token-renew.service vault-token-renew.timer ~/.config/systemd/user/

# user manager must survive logout, so the daily timer fires headless
loginctl enable-linger "$USER"

systemctl --user daemon-reload
systemctl --user enable --now vault-token-renew.timer
```

The user must already have a `case` arm in `vtr_resolve_config` (else the
renewer fails loud). Then mint the token (one-time — see below). The script and
units carry no secret; only the token itself is sensitive and stays out of git.

## Mint / re-mint the token

Mint an orphan periodic token scoped to the user, write it to their
`~/.vault-token`, `chmod 600`. `-orphan` is essential (a child of the 7-day OIDC
token would be revoked when that parent expired); Vault prefixes the display
name, so `devvm-<user>` becomes `token-devvm-<user>` (what the drift guard checks).

**wizard** (self, admin — an interactive OIDC login can't run unattended):

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me
vault login -method=oidc
vault token create -orphan -period=768h \
  -policy=vault-admin -policy=sops-admin -display-name=devvm-wizard \
  -field=token > ~/.vault-token
chmod 600 ~/.vault-token
```

**emo** (non-admin: emo's own token *cannot* create orphan periodic tokens, so
an **admin mints it for emo**, then hands the file to emo). From an admin shell
with a `vault-admin` token:

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me
vault token create -orphan -period=768h \
  -policy=default -policy=personal-emo -display-name=devvm-emo \
  -field=token | sudo install -m 600 -o emo -g emo /dev/stdin /home/emo/.vault-token
```

## Health check

Run as the user being checked (for emo: `sudo -u emo XDG_RUNTIME_DIR=/run/user/1002 ...`).

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me
vault token lookup | grep -E 'display_name|period|explicit_max_ttl|policies'
# wizard: display_name token-devvm-wizard, policies [default sops-admin vault-admin]
# emo:    display_name token-devvm-emo,    policies [default personal-emo]
# both:   period 768h, explicit_max_ttl 0s

# authoritative capability check (do NOT trust the policies field alone — an
# OIDC token shows policies=[default] but carries its scope via identity):
vault token capabilities secret/data/viktor   # wizard: create/update/.../sudo
vault token capabilities secret/data/emo       # emo: create/read/update/delete/list

# renewer health
systemctl --user list-timers | grep vault-token-renew     # next/last run
tail -5 ~/.local/state/vault-token-renew.log              # recent results
```

A healthy log line looks like:
`<ts> OK renewed (dn=token-devvm-<user> ttl=2764800s)` (ttl 2764800s = 768h).

After an OIDC login you'll instead see, at the next nightly run:
`<ts> HEALED: re-minted periodic token from foreign dn=oidc-… (revoked N stale periodic token(s))`
— that's the self-heal working as designed.

## Drift guard & self-heal

`~/.vault-token` is the Vault CLI's default token sink, so **any** `vault login`
overwrites it. Two confirmed clobber vectors:

1. `vault login -method=oidc` → replaces it with a 7-day OIDC token (the renewer
   can't push past the OIDC role's 7-day `token_max_ttl`). The infra docs
   prescribe this login before applies, so it recurs — it went unnoticed for
   weeks twice (2026-06-18→26, 2026-06-29→07-03) and read as "Vault expires
   weekly".
2. A stray `vault login -method=kubernetes` (e.g. a headless agent flow) →
   writes a read-only `kubernetes-woodpecker-default` token (can read Vault but
   **cannot** write `secret/*`). Happened 2026-06-05, unnoticed for two days.

Since 2026-07-03 the renewer **self-heals**
(`docs/plans/2026-07-03-vault-token-self-heal-design.md`). On a foreign token
it attempts the re-mint **with the clobbering token's own authority** and lets
Vault's authz decide:

- **Admin-capable clobber (OIDC login)** → re-mints the periodic token,
  sanity-checks it against the drift guard, atomically replaces
  `~/.vault-token`, revokes stale `token-devvm-wizard` leftovers
  (anti-sprawl), logs
  `HEALED: re-minted periodic token from foreign dn=… (revoked N stale periodic token(s))`
  and exits 0. The clobbering token is NOT revoked — it may still back a live
  login session; it ages out on its own.
- **Weak clobber (any token without orphan-create authority)** → the mint is
  denied; logs
  `DRIFT: … heal denied, foreign token lacks create authority …; investigate what wrote it`
  and exits non-zero (unit `failed`). Deliberately loud: this signals a
  misbehaving agent flow — exactly the 2026-06-05 case.

**Non-admin users (e.g. `emo`) never self-heal.** A non-admin token can't create
orphan periodic tokens, so *any* clobber — even the user's own OIDC login — is a
weak clobber that fails loud. This is rare (emo doesn't `vault login`); when it
happens the fix is the **admin** [emo mint](#mint--re-mint-the-token) block.

**Manual recovery** is needed for the weak-clobber case (the DRIFT log line
still contains the exact re-mint command) — run the
[mint/re-mint](#mint--re-mint-the-token) block for that user.

## Tests

`infra/scripts/test-vault-token-renew.sh` unit-tests per-user scope resolution
(`vtr_resolve_config` for wizard + emo, and that an unmapped user is refused),
the drift-guard decision in **both** user contexts (including the exact
2026-06-05 woodpecker-clobber case and that emo's guard rejects wizard's token),
the lookup-JSON parsers, and the self-heal's revoke filter (which stale periodic
tokens a heal may sweep — and that it never sweeps another user's).
Run: `bash infra/scripts/test-vault-token-renew.sh` (43 assertions).
