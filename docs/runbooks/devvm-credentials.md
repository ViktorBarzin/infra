# Runbook: devvm credentials and dotfiles on a rebuilt box

**Host:** `devvm` (10.0.10.10), users `wizard`, `emo`, `ancamilea`
**Plan:** [disposable devvm](../plans/2026-11-11-disposable-devvm.md), the "Credentials" and "Dotfiles" kept places
**Tool:** `scripts/workstation/workstation-creds.sh` (tests: `bash scripts/test-workstation-creds.sh`)
**Provisioner steps:** `restore_user_credentials`, `stage_shared_auth`, `install_admin_infra_clone`, `unlock_admin_infra_clone`, `install_vault_token_renew`, `install_user_dotfiles`, `install_forgejo_known_hosts`, `install_ios_rig_units`, `install_agent_api_keys`, `install_mcp_tools`, `fill_mcp_secrets` in `scripts/t3-provision-users.sh` (tests: `bash scripts/test-t3-provision-creds.sh`, `bash scripts/test-t3-provision-rebuild.sh`, `bash scripts/test-t3-provision-mcp-secrets.sh`, `bash scripts/test-t3-provision-infra-unlock.sh`)

## What is kept where

Each hand-made credential file in a user's home is one KV secret at
`secret/workstation/<user>/files/<slug>` with the fields `path` (relative to
the home), `mode`, and either `content_b64` or `ref`. A `ref`
(`secret/<path>#<field>`) points at a secret that already holds the file,
so a key with a canonical home elsewhere in Vault is stored once. The slug
is the path with `/` as `__`; only `path` says where the file goes.

Stored on 2026-11-11 (paths only; `workstation-creds list <user>` shows the
live set):

| User | Files | What they are |
|---|---|---|
| wizard | 44 | SSH keys and config (two as refs to `secret/viktor` and `secret/opnsense`), both GPG keys with keyring, trust DB, agent config and revocation certificates, `.gitconfig`, `.git-credentials`, gh, gcloud, docker, the OCI CLI config and API key, the admin `.kube/config`, the zsh secrets file (mode 0600 since 2026-11-11; it was 0664), `~/.venvs/claude/secrets.env`, the lobby-local env file, chezmoi's config, the ADB key `~/.android/adbkey` with its `.pub`, the iOS rig's isideload signing key and anisette state under `~/.local/state/ios-rig/isideload/`, `~/.config/tripit/config.json`, and the SOPS age key (a ref to `secret/viktor#sops_age_key_devvm`) |
| emo | 19 | SSH keys, config and authorized_keys, `.gitconfig`, `.git-credentials`, three service token files under `.config/`, the Bambu printer config beside its token, his own ADB key and `milka-adbkey`, each with its `.pub` |
| ancamilea | 7 | SSH key and authorized_keys, `.gitconfig`, `.git-credentials`, gh |

Notes on single entries:

- emo's `~/.android/milka-adbkey` and wizard's `~/.android/adbkey` are the
  same key, the one Milka's phone trusts (the Milka phone helpers in
  `playbooks/devvm.yml`). Without it the phone has to be paired again in
  person. It is stored as two entries, one per home.
- The isideload state is what Apple trusts after one 2FA code
  (`docs/runbooks/ios-test-rig.md`); without it the next signing asks for a
  code again.
- The SOPS key is restored as the bare key line. The live file also has
  `# created` and `# public key` comment lines, which sops does not need.

`.gitconfig` is stored because it is what says `credential.helper=store`:
without it the restored `.git-credentials` is never read, a user's private
clones fail with `could not read Username`, and step 4b's `devvm-setup.sh`
never runs. wizard's also carries his name, email and signing key.

## Who can read these paths

Only an admin token. `secret/data/workstation/+/files/*` and
`secret/data/workstation/+/loose/*` and `secret/data/workstation/+/mcp`, with their metadata paths, are denied in
the four policies that otherwise read all of `secret/data/*`:
`terraform-state` (the shared claude-agent pod), `openclaw-k8s`, `eso-reader`
(the `vault-kv` ClusterSecretStore, which serves any namespace) and `ci`
(`stacks/vault/main.tf`, 2026-11-11). Those readers can still reach
`secret/viktor`, `secret/infra` and the other shared paths, as before.

Not stored here, because something else already brings them back:

- The agent-tool keys in `~/.claude/settings.json` (`MEMORY_API_KEY`,
  `CLAUDE_MEMORY_API_KEY`, `PAGES_API_KEY`): each is the user's entry in
  `secret/claude-memory` `api_keys` or `secret/pages-publish` `api_keys`,
  the maps the two services check. `install_agent_api_keys` writes any that
  are absent, with the memory URL, on a run that holds an admin token.
  chezmoi leaves `settings.json` alone on the devvm and the session store
  does not keep env values, so nothing else would.

- `~/.vault-token`: minted by `install_vault_token_renew` (see [vault-token-renew-devvm](vault-token-renew-devvm.md)).
- `~/.config/claude-auth-sync/vault-token`: minted by `install_claude_auth_sync`; the Claude credential itself is backed up by `claude-auth-sync@` to `secret/workstation/claude-users/<user>`.
- wizard's `~/.ssh/authorized_keys`: the playbook writes it from `secret/devvm-authorized-keys`.
- The Bitwarden CLI login in `~/.config/Bitwarden CLI/data.json`: its server, account and API key are the `vaultwarden_*` keys in `secret/workstation/claude-users/wizard`, which `homelab vault` logs in with on its own. The 1.9 MB file is the CLI's encrypted cache. emo's copy holds no account.
- rclone: no config exists on the box and the binary is not installed.
- The shared ChatGPT login for codex, `/opt/codex-shared/auth.json`: every
  user's `~/.codex/auth.json` is a link to it, made by the `codex` wrapper.
  `codex-auth-backup` copies it to `secret/workstation`
  `codex_shared_auth_json` whenever it changes, so the Vault copy follows the
  rotating refresh token. `stage_shared_auth` (step 3e) writes it back when
  it is absent, on a run with an admin token; the wrapper, the
  `codex-shared` group and the directory are in `playbooks/devvm.yml`, and
  the roster puts admins and power users in the group.
- Each person's chrome hub config, `/etc/t3-serve/chrome-hub-<user>.json`:
  `stage_shared_auth` runs `stage-chrome-hubs.sh` when one is missing, and
  `install_chrome_hub` copies it to `~/.config/chrome-hub/hub.json`.

Not brought back at all, by choice:

- wizard's other agent-tool tokens: `~/.pi/agent/auth.json`,
  `~/.mcporter/credentials.json`, `~/.agent-conductor` grid-token,
  `~/.config/orca/*` and `~/.config/homelab/agent-api-token`. Capture any
  that should survive a rebuild with `workstation-creds capture`.

Loose secrets moved out of wizard's home on 2026-11-11, each checked by hash
against Vault first and then deleted:

| Was | Now |
|---|---|
| `~/code/keys.txt` (61 `sk-` API keys, none already in Vault) | `secret/workstation/wizard/loose/keys-txt`, field `content_b64` |
| `~/code/infra-git-crypt-key` (the infra repo's git-crypt key; until then it was in no Vault path, only there, in the clone's `.git` and in three ConfigMaps: `woodpecker/git-crypt-key` and the `git_crypt_key` ones in `stacks/claude-agent-service` and `stacks/openclaw`) | `secret/infra`, field `git_crypt_key_b64` |
| `~/meshcentral-data/*-private.key` (5 keys, byte-identical to the live meshcentral pod's) | `secret/workstation/wizard/loose/meshcentral`, one field per key. First stored at `secret/meshcentral`, which every `secret/data/*` reader above could read, and moved here the same day; the agent-server key would let its holder pose as the server to agents that run as root. Nothing reads it: the pod keeps its own copy on its volume. |
| `~/code/tmp_id` (a single newline, no secret) | deleted |
| The rest of `~/meshcentral-data` (a 2024 copy of the live server's data volume: `config.json` with the `sessionKey` that signs MeshCentral's web login cookie, `meshcentral.db` with the live login-cookie and invitation-link encryption keys, public certs and stale agent builds; mode 664 in a 755 folder until 2026-11-11, so every devvm user could read it) | Deleted 2026-11-11. The pod now reads its `sessionKey` from `secret/meshcentral` field `session_key` (ExternalSecret `meshcentral-secrets`, written into `config.json` by the `fix-config` init container), and that key was replaced with a new one the same day. The three keys in `meshcentral.db` (login cookie, invitation link, AMT event secret) were still the live ones, and the login-cookie key forged a working admin `/control.ashx` session (tested 2026-11-11). They were rotated the same day by the `DB_KEY_GENERATION` label in `stacks/meshcentral/main.tf` (see `docs/agents/service-notes.md`). Since then the backed-up copy holds no key the server accepts, except the five certificate private keys, which were not re-keyed, and the users' password hashes. |

Copies of the deleted files remain in the devvm-home backup generations on
the Proxmox host (`/mnt/backup/devvm-home/`; the backup was retired on
2026-11-12, so these no longer roll over and stay until deleted by hand), in the retired vzdump images of VM 102 in `/mnt/backup/vzdump/` (full
disk images; they never roll over), and in the Synology copy of `/mnt/backup`.
The server's own data has more copies on the host: MeshCentral's nightly
autobackup zips in `/srv/nfs/meshcentral/meshcentral-backups` (the pod's
backups volume), a stale 2026-04 copy of the data volume in
`/srv/nfs/meshcentral/meshcentral-data` that nothing mounts, and nfs-mirror's
copy of both in `/mnt/backup/meshcentral`, then the Synology. Each zip and
the stale copy hold `meshcentral.db` (the database keys and every user's
password hash), `config.json` (the `sessionKey`) and the five certificate
private keys.

What still holds what, as of 2026-11-12:

- The login-cookie, invitation and AMT keys and the `sessionKey` in every
  copy above are the pre-rotation ones, which the server no longer accepts.
  No plain copy of the current ones exists: the last plain zip was written
  2026-11-11 22:21 UTC, before both rotations.
- From 2026-11-12 the zips are AES-256 encrypted with Vault
  `secret/meshcentral` field `backup_zip_password` (`fix-config` writes it into
  `settings.AutoBackup.zippassword`; see `docs/agents/service-notes.md`).
- Still live in the old copies: the five certificate private keys, which were
  not re-keyed, and the users' password hashes, which work against
  `/control.ashx` on the auth=none ingress for anyone who cracks one.

Who can read them. `pve-host.yml --tags backup-perms` keeps
`/srv/nfs/meshcentral`, `/mnt/backup/meshcentral` and `/mnt/backup/vzdump`
root-only (700), and `devvm-home-backup` does the same for
`/mnt/backup/devvm-home`; all four were readable by the host's uid 1000, the
local account emo, until 2026-11-11/12 (devvm-home's generations keep the
devvm's numeric uids). That is the whole scope: it keeps out non-root host
logins. It does not keep out root. emo's agent holds a root SSH key to the
host by design (`emo-pve-agent@devvm`, `docs/architecture/monitoring.md`),
and the `/srv/nfs` export (`scripts/pve-nfs-exports`) admits any client with
`no_root_squash,insecure`, so a LAN host that claims uid 0 reads
`/srv/nfs/meshcentral` whatever its mode. Against that only the zip
encryption helps, and only for zips written from 2026-11-12. The Synology copy
is pushed with `--chmod Fog=r`.

## Rebuild: put a user's credentials back

The hourly provisioner run has no Vault token, so it only logs
`credential restore skipped`. On a new box the bootstrap's own provisioner run
(`scripts/devvm-bootstrap`, step 5) clones the admin's `~/code/infra` from
Forgejo (`install_admin_infra_clone`), which is what the hourly run and the
command below read. After that, run it once with an admin token:

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me
vault login -method=oidc            # writes ~/.vault-token; skip if it holds an admin token
cd /                                # chezmoi runs as each user here; another user's home stops it
sudo VAULT_ADDR=https://vault.viktorbarzin.me bash -c 'VAULT_TOKEN="$(cat "/home/$SUDO_USER/.vault-token")" exec t3-provision-users'
```

sudo writes every `VAR=value` on its command line, and every variable named
in `--preserve-env=`, into `/var/log/auth.log` as `ENV=...`, and promtail ships
that to Loki for 26 weeks. So root reads the token from the admin's
`~/.vault-token` inside the command; the logged line holds only the path.

Order inside that run: credentials for every existing account (step 3d: the
admin kubeconfig is what the other users' kubeconfigs copy the cluster
address from), the shared Codex login and chrome hub configs (step 3e), then
per account: dotfiles, Forgejo's pinned SSH host key in
`~/.ssh/known_hosts`, the admin's infra clone and its git-crypt unlock, groups (the tier's plus the
row's `extra_groups`; emo keeps `docker`), clones, kubeconfigs,
`vault-token-renew` with a first `~/.vault-token`, and for an admin on the
live box's address whose token reads `secret/ios-rig`, the iOS rig's user
units (`homelab ios bootstrap --units-only`, `ios-test-rig.md`); later the
agent-tool keys in `settings.json`, and once per box, when every user's
`~/.claude` is back, a start of `claude-skills-update` (marker
`/var/lib/t3-provision/skills-update.started`). A file or key that is already
there is never replaced, so a second run writes only what has gone missing.

An hourly run that fires before the admin's `~/code/infra` exists (during
the first boot's playbook) logs `the infra checkout ... is not there yet` and
exits 0. The agent-instruction fetches under
`/var/lib/t3-provision/agent-repos` belong to the admin
(`resolve_agents_owner`), even when the run reads its roster from the
bootstrap's root-owned clone, and a fetch owned by anyone else is made again.

The admin token never reaches a user's code. The script takes `VAULT_TOKEN`
out of its environment before it runs anything as a user
(`take_admin_vault_token`) and hands it only to the vault CLI it runs as root
(`vault_admin`), and `workstation-creds` drops it before each `runuser`. This
matters because `runuser` passes the caller's environment on, and a user can
read the environment of any process running as them; before 2026-11-11 every
`runuser` step (git in a user's clones, `bash -lc` with the user's
`~/.profile`, chezmoi) carried it.

The same run unlocks wizard's infra clone (`unlock_admin_infra_clone`,
since 2026-11-12; before that it was a hand step after the run). For an
admin whose `~/code/infra` has no git-crypt key yet, root reads
`secret/infra` field `git_crypt_key_b64` with the admin token and pipes it,
decoded, into a 0600 file in a 0700 directory under `/tmp` that the admin
owns. `git-crypt unlock` then runs as the admin in the clone, the directory
is deleted, and the three git-crypt filters get `--key-file
<clone>/.git/git-crypt/keys/default`, as on the live clone, so plain
worktrees of it decrypt (`docs/agents/known-issues.md`). The key never
appears on a command line or in a log line. The step leaves the clone alone
when:

- it already holds `.git/git-crypt/keys/default`: the live box's clone, or
  a second run. Nothing ever locks it again;
- the box is not on 10.0.10.10, unless root opted the drill in with
  `touch /var/lib/t3-provision/drill-unlock-infra` (drills keep the key off
  throwaway disks; `devvm-drill.md`);
- the token cannot read `secret/infra`: the hourly run has none, and the
  bootstrap's own run cannot (log `infra unlock skipped: ...`);
- the tree has local changes, which `git-crypt unlock` refuses (`WARN:
  git-crypt unlock of wizard:~/code/infra failed: Error: Working directory
  not clean.`).

Check it as wizard. `git-crypt status` lists `encrypted: config.tfvars`
whether the clone is locked or not, because it reports the attribute. So
read the file's first bytes too:

```bash
cd ~/code/infra
git-crypt status config.tfvars          # "    encrypted: config.tfvars"
head -c 10 config.tfvars | grep -qa GITCRYPT && echo locked || echo unlocked
ls -l .git/git-crypt/keys/default       # the key, mode 0600
git status --porcelain                  # empty
```

## Dotfiles

A roster row with `dotfiles: owner/name` (wizard: `viktor/dot_files`, emo:
`ebarzin/dotfiles`) gets `chezmoi init --no-tty` from that Forgejo repo,
once, when `~/.local/share/chezmoi` does not exist or is empty (a failed
first init leaves it empty, and the next hourly run retries), then an apply
(`dotfiles_apply`); chezmoi itself is installed into `~/.local/bin` at
`CHEZMOI_VERSION` when missing. An existing source is never touched, because
the live home may have drifted from the repo and a whole-tree apply would
overwrite work there.

The apply has two parts, both `--force --no-tty --keep-going
--exclude=encrypted`: every top-level entry except `~/.claude` and `~/.codex`
whole, then those two with `--exclude=encrypted,files`, so only their links
(`CLAUDE.md`, `AGENTS.md`, skill links) and directories come from the
dotfiles. Every regular file there is the session store's (step 4a,
`restore-claude-sessions.md`). Until 2026-11-11 one `chezmoi init --apply`
wrote the dotfiles' copies first; the restore then kept them (it never
replaces a file) and the ingest sent them back to the store as the newest.
wizard's repo also ignores `.claude/*` except those links on `devvm*` hosts,
so a hand-run `chezmoi apply` there leaves the store's files alone too.

The two GPG-encrypted entries in the dotfiles (`.kube/config` and
`.oh-my-zsh/custom/secrets.zsh`) are skipped by `--exclude=encrypted` and,
on hosts whose name starts with `devvm`, by the repo's `.chezmoiignore`; on
the devvm both come from the credential restore above. That also makes a
whole-tree `chezmoi status` or `apply` finish there without a passphrase.

wizard's user units live in the dotfiles since 2026-11-11, with the
`*.target.wants` links that enable them: `lobby-local.service` (devvm only),
`tmux-plugin-update.{service,timer}` with `~/.local/bin/tmux-plugin-update`,
and the link for the existing `agents-sync.timer`. `tmux.service` was left
out: it was retired on 2026-11-02 and is disabled. The repo was brought up to
the live home the same day (`.tmux.conf.local` without resurrect and
continuum, the merged `.zshrc`, `.zshenv` and `.bash_aliases`), so `chezmoi
diff` on those files is empty on the live box.

emo's `ebarzin/dotfiles` (private, his own, viktor a collaborator) holds his
`.zshrc`, `.zshenv`, `.zprofile`, `.tmux.conf`, `.tmux.conf.local` and
`~/.local/bin/t`, and puts oh-my-tmux into `~/.tmux` from an archive pinned
in `.chezmoiexternal.toml` (a git-repo external ran `git pull` in his existing
`~/.tmux` on the first apply, which failed on its untracked files). Its `.zshenv` sources `~/.zshenv.local`, which holds
`HA_MCP_URL` and is one of his credential files in Vault
(`secret/workstation/emo/files`), restored before the dotfiles apply.

## A repo's own setup (step 4b)

After the clones, the provisioner runs `devvm-setup.sh` from the root of each
roster repo that has one, as the user, with an emptied environment (so the
admin `VAULT_TOKEN` of a rebuild run never reaches the user's code), and turns
on linger for that user. The script must be idempotent and print nothing when
everything is in place. Today only emo's `ebarzin/vermont-device-configs` ships
one: it restores his `~/bin` links and the Hikvision SDK for his hand tools
(`docs/runbooks/cameras-nvr-intercom.md`). The B4 intercom watchdog it used to
install as a user timer runs on ha-sofia as an add-on since 2026-11-12.

## MCP server secrets

The session store keeps `~/.claude.json` (reduced to project trust, MCP
servers and the onboarding flags) and `~/.codex/config.toml`, both redacted:
header values, env keys and tokens inside a URL, such as the `ha` server's
secret path, are blanked. Their kept place is one KV secret per user,
`secret/workstation/<user>/mcp`, written by `homelab claude-sessions
mcp-secrets capture` and read back by `mcp-secrets fill`
(`docs/architecture/claude-session-store.md`). Provisioning step 4a2
(`fill_mcp_secrets`) runs the fill once per roster user per box: on the first
pass that holds an admin token after their session-store restore. A marker,
`/var/lib/claude-sessions-ingest/mcp-filled/<user>`, records that it ran, so a
later pass cannot put back a secret the user has removed since. A failed fill
leaves no marker and runs again on the next admin pass. To fill a user again
by hand, delete their marker or run `mcp-secrets fill` yourself. Fill prints a
`WARN` line, by name, for an entry that differs from the Vault copy and for
one Vault keeps that the file lacks (a server lost to the `~/.claude.json`
clobber race); both go back by hand.

Step 4a3 (`install_mcp_tools`) installs the home-local programs a restored
config starts, as the user, pinned, and only when the config names them and
they are absent: uv 0.11.19 into `~/.local/bin` (wizard's `google_workspace`
server runs `~/.local/bin/uvx workspace-mcp`), `workspace-mcp` 2.4.2 as a uv
tool on Python 3.14.5 with every package it pulls in pinned to what wizard's
live servers ran on 2026-11-12 (the config names no version, and `uvx` uses
an installed tool before it resolves the newest release; skipped in a home
whose uv cache already has `workspace-mcp`), and the phpipam MCP server
0.2.1, with the exact packages of the live venv, into
`~/.local/share/phpipam-mcp` (wizard's Codex `phpipam` server). The
`google_workspace` OAuth files are credential files in Vault
(`secret/workstation/wizard/files`, stored 2026-11-11):
`.config/google-drive-mcp/gcp-oauth.keys.json` and
`.google_workspace_mcp/credentials/vbarzin@gmail.com.json`. The second
holds the refresh token. When Google is re-authorised (`start_google_auth`),
capture it again with `workstation-creds capture wizard
'.google_workspace_mcp/credentials/vbarzin@gmail.com.json'`.

Capture again after adding an MCP server with a secret or rotating one. It
merges, and refuses a file that still holds `<redacted>`. It also writes a
SHA-256 of each entry it stored to `~/.claude/mcp-captured.json`. The
ingest compares the live entries with that file every 15 minutes and logs
`claude-sessions-ingest WARN user=<u>: N MCP server entries ...` naming the
new or changed ones. The count is the metric
`claude_sessions_ingest_mcp_entries_uncaptured`, and the alert
`ClaudeSessionsMCPSecretsUncaptured` fires once it has stayed above 0 for
6 hours. The other direction is counted too: an entry `mcp-captured.json`
names that the live files lack, or hold without its secret, is
`claude_sessions_ingest_mcp_entries_unfilled`, and
`ClaudeSessionsMCPSecretsUnfilled` fires after 6 hours above 0. After a
rebuild that means fill never ran (no admin provisioning pass) or named the
entry in a `WARN` line: run `mcp-secrets fill --user <u>` with an admin
token, or put the entry back by hand. On the live box it means a server was
removed since the capture; capture again and the record forgets it. The
ingest has no Vault access, so it can only point at a capture or a fill:

```bash
homelab claude-sessions mcp-secrets capture --user wizard     # your own files, your ~/.vault-token
sudo bash -c 'VAULT_TOKEN="$(cat "/home/$SUDO_USER/.vault-token")" exec homelab claude-sessions mcp-secrets capture --user emo'
homelab claude-sessions mcp-secrets list --user emo           # entry names, no values
```

Stored on 2026-11-11 at 23:10 (`mcp-secrets list <user>` shows the live
set): wizard 5 entries, the `google_workspace` server of `~/.claude.json`
(its env names two paths whose names read as secrets) and the Codex tables
`claude_memory`, `ha`, `paperless-mcp` and `phpipam.env`; emo 3 entries, the
`paperless` server and the Codex tables `claude_memory` and `ha`; ancamilea
none (her files hold no MCP secret). Checked the same night: both users'
files restored with `restore --path` into scratch homes and filled came
back with `mcpServers` and every `[mcp_servers.*]` table identical to the
live files, `claude mcp list` there showed every server `Connected`, and
`claude` in a trusted folder (`~/code/infra`, `/home/emo/code`) opened
straight to the prompt, with no onboarding and no trust question. A fill on
the live homes printed nothing and changed nothing.

Captured again at 23:42 with the digest file (same entries), and checked
as a rebuild in a private mount namespace on the live box. Empty tmpfs
mounts hid wizard's `~/.local/bin`, `~/.local/share/{uv,phpipam-mcp}`,
`~/.cache/uv` and both Google folders. In that state `install_mcp_tools
wizard` installed uv and the phpipam server, and `workstation-creds
restore` brought the two Google files back from Vault. `restore --path`
and `fill` gave a HOME whose `claude mcp list` showed `google_workspace`
and `playwright` `Connected`. A `claude -p` call to `list_calendars`, with
only the restored `google_workspace` entry, returned calendars, and the new
phpipam server answered an MCP `initialize`. A first install without the
venv pins failed: a fresh resolve brings a version that the 0.2.1 server
cannot import.

## Add or refresh a credential

When a token is rotated or a new hand-made credential appears, store it
again (each `put` is a new KV version):

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me VAULT_TOKEN="$(cat ~/.vault-token)"
C=~/code/infra/scripts/workstation/workstation-creds.sh
sudo VAULT_ADDR=$VAULT_ADDR bash -c 'VAULT_TOKEN="$(cat "/home/$SUDO_USER/.vault-token")" exec bash "$@"' _ \
  $C capture <user> .config/gh/hosts.yml    # token read inside sudo, never on its command line
bash $C capture-ref <user> .ssh/some_key 'secret/<path>#<field>'   # already in Vault elsewhere
bash $C list <user>                                                # paths and modes, no values
```

`.git-credentials` and `.docker/config.json` hold copies of tokens that also
live in `secret/viktor` (`github_pat`) and other paths, so a rotation of
those needs a `capture` of the file too. So does wizard's `.kube/config`: its
`kubernetes-admin` client certificate expires on 2027-04-17, and a kubeadm
certificate renewal or a re-issue leaves the stored copy with a dead
certificate that a rebuild would restore. After either, run
`bash $C capture wizard .kube/config`.

## Check a restore without touching a home

```bash
d=$(mktemp -d)
bash $C restore <user> --into "$d"
(cd "$d" && find . -type f -printf '%m %P\n' | sort)   # compare with the live home's modes
rm -rf "$d"                                             # it holds the secrets
```

On 2026-11-11 at 14:40 this restored 44, 19 and 7 files for wizard, emo and
ancamilea, each with the live home's names and modes. Contents were
byte-identical except wizard's SOPS key, which comes back without its two
comment lines (above). An earlier run that day had shown the restored GPG
home with both secret keys, the SSH keys with the live fingerprints, and
`kubectl get nodes` working with the restored kubeconfig.

## The main checkout no longer follows master

wizard's hourly `git pull` cron on `~/code/infra` was dropped on 2026-11-11.
The unattended readers of that checkout take `origin/master` instead: the
provisioner (each deployed file is extracted from it on every pass) and
`k8s-node-drift-check` (fetches, then runs from an export of it). Anyone
running a local `homelab tf apply` or the devvm playbook from the main
checkout pulls first. agentmd's `/etc/agentmd/config.toml` names the
checkout's `managed-settings.json` only as the file to edit; it deploys
nothing from it.

## Open questions

- ancamilea is not in `roster.yaml` (commented out 2026-08-17), so the
  provisioner restores nothing for her and installs no `vault-token-renew`
  (that covers roster users that `vtr_resolve_config` has a case for, today
  wizard and emo). Her files are stored and `workstation-creds restore
  ancamilea` puts them back by hand. The plan puts all three users in scope;
  whether an offboarded user's rebuild path is that manual restore is for
  Viktor to confirm.
