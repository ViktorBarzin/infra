# Workstation Claude authentication renewal

## Scope

Every roster user authenticates Claude Code with their own Enterprise identity.
Credentials are never shared between OS users. Claude refreshes its normal OAuth
access token; `claude-auth-sync@<user>.timer` verifies that refresh using real
inference every six hours and backs up only the `claudeAiOauth` object to:

```text
secret/workstation/claude-users/<os-user>
```

The backup **merges** into that path (`vault kv patch -method=rw`, falling back to
`kv put` only when the path does not exist yet), so keys that other tools
co-locate there — notably `homelab vault`'s `vaultwarden_*` credentials — survive.
A blind `kv put` here silently wiped them on every six-hourly run (fixed 2026-06-26).

The user's unrelated `mcpOAuth` credentials never leave their home directory.
Each renewal service has a distinct 32-day periodic Vault token, mode `0600`, at
`~/.config/claude-auth-sync/vault-token`. Its policy can access only that user's
path. The service renews the Vault token on every run.

## Normal lifecycle

1. Add the user to `scripts/workstation/roster.yaml` and apply the Vault stack.
2. Run `scripts/workstation/setup-devvm.sh` as root with the admin Vault token.
   Its foreground provisioner mints the isolated periodic token and enables the
   user's timer. Routine hourly provisioning never needs an admin token.
3. The user completes one initial Enterprise login:

   ```bash
   claude auth login --claudeai --sso --email <enterprise-email>
   ```

4. Start the first sync immediately instead of waiting for the timer:

   ```bash
   systemctl start claude-auth-sync@<os-user>.service
   systemctl status claude-auth-sync@<os-user>.service
   ```

Success writes no secrets to the journal. The user's private log records `OK` in
`~/.local/state/claude-auth-sync/sync.log`; journald receives the same status with
`identifier=claude-auth-sync` for Loki alerting.

## Automatic recovery

`claude auth status` is not a sufficient health check: it can report logged in
while inference returns HTTP 401. The service therefore runs a minimal Haiku
inference with no session persistence. On failure it:

1. reads the user's latest OAuth object from Vault;
2. atomically merges it into `.credentials.json`, preserving MCP OAuth state;
3. retries inference once;
4. stores the newly refreshed OAuth object back in Vault on success.

Vault KV version history remains available for audit, but the service deliberately
does not cycle through old refresh tokens: providers commonly invalidate rotated
refresh tokens, so replaying old versions can make recovery less deterministic.

## Recovery requiring a person

If both local state and the latest Vault copy fail, the refresh token was revoked,
invalidated, or the Enterprise session requires reauthorization. Run the login as
the affected OS user, then rerun the service:

```bash
claude auth login --claudeai --sso --email <enterprise-email>
systemctl start claude-auth-sync@$(id -un).service
```

If the scoped Vault token expired or drift protection rejected it, rerun the root
provisioner with an admin Vault token after confirming the matching policy exists:

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me
export VAULT_TOKEN="$(cat /home/wizard/.vault-token)"
sudo --preserve-env=VAULT_ADDR,VAULT_TOKEN /usr/local/bin/t3-provision-users
```

Never copy another user's `.credentials.json` or scoped Vault token. Never restore
the old shared `CLAUDE_CODE_OAUTH_TOKEN`; environment credentials outrank per-user
login and would silently collapse all users onto one identity.

## Verification

```bash
systemctl list-timers 'claude-auth-sync@*'
systemctl status claude-auth-sync@<os-user>.service
journalctl -t claude-auth-sync --since today
```

Inspect Vault metadata, not secret values:

```bash
vault kv metadata get secret/workstation/claude-users/<os-user>
```

Alert `WorkstationClaudeAuthInvalid` fires when any renewal agent logs `FAIL`.
