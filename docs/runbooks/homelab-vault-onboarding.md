# `homelab vault` onboarding (Vaultwarden access + `vault kv` infra secrets)

## Scope

`homelab vault` fronts **two unrelated secret stores** — the name collides, so
the command keeps them clearly separated:

- **Vaultwarden** — your personal *password manager* (logins/passwords/TOTP).
  The verbs below give each devvm roster user no-HITL access to **their own**
  Vaultwarden vault (and any Organization Collection shared with their account).
  It shells out to the official `bw` CLI; the user's Vaultwarden credentials live
  only in their isolated Vault path `secret/workstation/claude-users/<os-user>`
  and are decrypted as that OS user — the admin never sees them.
- **HashiCorp Vault / OpenBao** — the homelab *infra* secrets store (the
  `secret/…` KV mount at `vault.viktorbarzin.me`), under `homelab vault kv`.
  These use the caller's **own** Vault token (`vault login -method=oidc` →
  `~/.vault-token`), **not** the scoped Vaultwarden token (which only reads the
  `claude-users/<user>` path); access is whatever your Vault policy grants.

```text
# Vaultwarden (password manager)
homelab vault setup             one-time: store VW email + master password + API key
homelab vault status            configured / unlocked / reachable (no secrets)
homelab vault list [--search Q]  item names (no secrets)
homelab vault get <name> [--field password|username|uri|notes|totp] [--json]
homelab vault get <name> --all  all fields (incl. custom) as JSON; pipe it (| jq)
homelab vault code <name>       current TOTP code
homelab vault lock              lock / log out the local bw session

# HashiCorp Vault / OpenBao (infra secrets; uses your own OIDC token)
homelab vault kv get <path> [--field K]   read an infra KV secret
homelab vault kv list <path>              list sub-paths
homelab vault kv put <path> <key>         write one key (value via stdin; merges)
```

## How auth works (why a non-admin can use it)

`homelab vault` runs `vault` as the calling user. It resolves a Vault token in
this order (`ensureVaultToken`, `cli/cmd_vault.go`):

1. an explicit `$VAULT_TOKEN` (a deliberate override), then
2. the per-user **scoped token** that `claude-auth-sync` maintains at
   `~/.config/claude-auth-sync/vault-token` (policy `workstation-claude-<user>`), then
3. a native `~/.vault-token` (admins who carry one; non-admins usually don't).

**The scoped token deliberately beats `~/.vault-token`.** This tool only touches
your own `secret/workstation/claude-users/<user>` path, and a power-user who ran
`vault login -method=oidc` carries a read-only `~/.vault-token` (capability
`deny` on that path); letting it win would shadow the scoped token and fail every
op with `403 permission denied` (this is exactly what bit emo, 2026-06-28). The
CLI also **self-defaults `VAULT_ADDR`** to `https://vault.viktorbarzin.me` when
unset, so it works from non-login shells (tmux panes, AFK agent subprocesses)
that never sourced `/etc/environment` — otherwise every `vault` child hits the
`127.0.0.1:8200` default and fails `connection refused` (exit 2).

That scoped policy grants exactly `create`/`read`/`update` on the user's own
`secret/workstation/claude-users/<user>` path — no `patch` capability — so the
tool writes with `vault kv patch -method=rw` (read-modify-write), falling back to
`kv put` only when the path does not exist yet. This preserves the
`claude_ai_oauth_json` key that [claude-auth-sync](claude-auth-renew-workstation.md)
co-locates there. (The admin-only bugs were fixed 2026-06-27; the
`VAULT_ADDR`/token-precedence bugs above were fixed 2026-06-28.)

## Prerequisites (per user)

- The user is in `scripts/workstation/roster.yaml` and the **vault** stack has
  been applied → their `workstation-claude-<user>` policy exists.
- The user's workstation was provisioned (`setup-devvm.sh`) → their scoped Vault
  token exists at `~/.config/claude-auth-sync/vault-token`.
- `bw` is installed **system-wide** at `/usr/bin/bw` (see below).
- The user has a Vaultwarden account at `https://vaultwarden.viktorbarzin.me`
  (self-service signup is open; admin panel is disabled).

## One-time admin steps (devvm)

`bw` must be system-wide so every user resolves it (it is a Node script, and
`node` is already system-wide at `/usr/bin/node`). `setup-devvm.sh` installs it
to the npm `/usr` prefix; the guard checks the **system** path, not
`command -v bw` (an admin's own `~/.local/bin/bw` used to mask the system
install, leaving non-admins with no backend). To install on a running box:

```bash
sudo npm install -g --prefix /usr "@bitwarden/cli@^2024"
bw --version            # confirm /usr/bin/bw resolves
```

After landing a `cli/` change, rebuild the binary so users pick it up:

```bash
# version is stamped from cli/VERSION, exactly as setup-devvm.sh does it
sudo bash -c 'cd /home/wizard/code/infra/cli && \
  go build -ldflags "-X main.version=$(cat VERSION 2>/dev/null || echo dev)" \
  -o /usr/local/bin/homelab .'
```

(or just re-run `scripts/workstation/setup-devvm.sh` as root, which rebuilds it.)

## User onboarding

The user runs these as themselves. The master password / API key are entered
interactively (never on the command line) and stored only in the user's Vault
path.

1. In the Vaultwarden web vault → **Settings → Security → Keys → View API key**,
   copy the `client_id` (`user.xxxx`) and `client_secret`.
2. Configure:

   ```bash
   homelab vault setup        # prompts: VW email, API client_id/secret, master password
   homelab vault status       # → "vault: configured, unlocked, reachable ✓"
   homelab vault list         # item names (own vault + any shared Collections)
   ```

## Shared-Collection access (sharing passwords with a user)

`homelab vault` surfaces Organization Collection items automatically once the
user's Vaultwarden account is a confirmed member. These steps are done by the
vault owner in the **Vaultwarden web UI** (they need the owner's master
password — not an infra/Terraform operation):

1. Create or reuse an **Organization** and a **Collection** of shared logins.
2. **Invite** the user's Vaultwarden account to the Organization, granting
   **"Can view"** on that Collection (least privilege).
3. The user accepts the email invite and confirms membership.
4. The user runs `homelab vault list` — the shared items now appear alongside
   their own (a `homelab vault status` sync picks them up).

## Security model (the no-HITL trade)

Identity is the kernel UID. Anything running as the user can decrypt the user's
vault — this is the accepted trade for no-human-in-the-loop fetches. Secrets
never appear in `argv` (passed via env or stdin), core dumps are disabled, TOTP
fetches are logged to syslog/Loki, and on a TTY values go to the clipboard
(auto-clearing) rather than scrollback. The admin's Vault token is never used by
a non-admin: each user authenticates with their own scoped token.

## Verification

```bash
# the scoped token carries the right policy
VAULT_TOKEN="$(sudo cat /home/<user>/.config/claude-auth-sync/vault-token)" \
  vault token lookup -format=json | jq '.data.display_name, .data.policies'
#   → "token-devvm-claude-auth-<user>", [..., "workstation-claude-<user>"]

sudo -u <user> -i bw --version        # /usr/bin/bw resolves for the user
sudo -u <user> -i homelab vault status
```

## Troubleshooting

**`homelab vault setup` (or any verb) fails with `exit status 2`** — older
binaries swallowed the underlying `vault` error; the message now includes it.
Two historical causes (both fixed in-CLI 2026-06-28, kept here for diagnosis):

- `... connection refused` to `127.0.0.1:8200` → `VAULT_ADDR` wasn't set in the
  caller's shell. The CLI now self-defaults it, but if you see this on an old
  binary: `export VAULT_ADDR=https://vault.viktorbarzin.me`.
- `403 permission denied` on `PUT .../secret/data/workstation/claude-users/<user>`
  → a stale read-only `~/.vault-token` (e.g. from `vault login -method=oidc`,
  policy `default`, capability `deny` on that path) was shadowing the scoped
  token. The CLI now prefers the scoped token; on an old binary, `rm
  ~/.vault-token` (or `unset VAULT_TOKEN`) and retry. Confirm with
  `VAULT_TOKEN="$(sudo cat /home/<user>/.config/claude-auth-sync/vault-token)" vault token capabilities secret/data/workstation/claude-users/<user>`
  → must be `create, read, update`.
