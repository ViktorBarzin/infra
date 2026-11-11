# Runbook: devvm credentials and dotfiles on a rebuilt box

**Host:** `devvm` (10.0.10.10), users `wizard`, `emo`, `ancamilea`
**Plan:** [disposable devvm](../plans/2026-11-11-disposable-devvm.md), the "Credentials" and "Dotfiles" kept places
**Tool:** `scripts/workstation/workstation-creds.sh` (tests: `bash scripts/test-workstation-creds.sh`)
**Provisioner steps:** `restore_user_credentials`, `stage_shared_auth`, `install_admin_infra_clone`, `install_vault_token_renew`, `install_user_dotfiles`, `install_forgejo_known_hosts`, `install_ios_rig_units`, `install_agent_api_keys`, `fill_mcp_secrets` in `scripts/t3-provision-users.sh` (tests: `bash scripts/test-t3-provision-creds.sh`, `bash scripts/test-t3-provision-rebuild.sh`, `bash scripts/test-t3-provision-mcp-secrets.sh`)

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
| The rest of `~/meshcentral-data` (a 2024 copy of the live server's data volume: `config.json` with the `sessionKey` that signs MeshCentral's web login cookie, `meshcentral.db` with the live login-cookie and invitation-link encryption keys, public certs and stale agent builds; mode 664 in a 755 folder until 2026-11-11, so every devvm user could read it) | Deleted 2026-11-11. The pod now reads its `sessionKey` from `secret/meshcentral` field `session_key` (ExternalSecret `meshcentral-secrets`, written into `config.json` by the `fix-config` init container), and that key was replaced with a new one the same day, so the copy in the devvm-home backups is dead. The database keys stay only in the pod's `meshcentral.db`; they were not rotated. |

The nightly devvm-home backup on the Proxmox host still holds the deleted
copies until its 14 generations roll over.

## Rebuild: put a user's credentials back

The hourly provisioner run has no Vault token, so it only logs
`credential restore skipped`. On a new box the bootstrap's own provisioner run
(`scripts/devvm-bootstrap`, step 5) clones the admin's `~/code/infra` from
Forgejo (`install_admin_infra_clone`), which is what the hourly run and the
command below read. After that, run it once with an admin token:

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me
vault login -method=oidc            # writes ~/.vault-token; skip if it holds an admin token
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
`~/.ssh/known_hosts`, the admin's infra clone, groups (the tier's plus the
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

To unlock wizard's infra clone on the new box:

```bash
k=$(mktemp); vault kv get -field=git_crypt_key_b64 secret/infra | base64 -d > "$k"
(cd ~/code/infra && git-crypt unlock "$k"); rm -f "$k"
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
`~/.local/bin/t`, and clones oh-my-tmux into `~/.tmux` through
`.chezmoiexternal.toml`. Its `.zshenv` sources `~/.zshenv.local`, which holds
`HA_MCP_URL` and is one of his credential files in Vault
(`secret/workstation/emo/files`), restored before the dotfiles apply.

## A repo's own setup (step 4b)

After the clones, the provisioner runs `devvm-setup.sh` from the root of each
roster repo that has one, as the user, with an emptied environment (so the
admin `VAULT_TOKEN` of a rebuild run never reaches the user's code), and turns
on linger for that user. The script must be idempotent and print nothing when
everything is in place. Today only emo's `ebarzin/vermont-device-configs` ships
one: it restores his `~/bin` links, the Hikvision SDK and the B4 intercom
watchdog's user units (`docs/runbooks/cameras-nvr-intercom.md`).

## MCP server secrets

The session store keeps `~/.claude.json` (reduced to project trust, MCP
servers and the onboarding flags) and `~/.codex/config.toml`, both redacted:
header values, env keys and tokens inside a URL, such as the `ha` server's
secret path, are blanked. Their kept place is one KV secret per user,
`secret/workstation/<user>/mcp`, written by `homelab claude-sessions
mcp-secrets capture` and read back by `mcp-secrets fill`
(`docs/architecture/claude-session-store.md`). Provisioning step 4a2
(`fill_mcp_secrets`) runs the fill for every roster user on a pass that holds
an admin token, after their session-store restore; on the live box it changes
nothing.

Capture again after adding an MCP server with a secret or rotating one. It
merges, and refuses a file that still holds `<redacted>`:

```bash
homelab claude-sessions mcp-secrets capture --user wizard     # your own files, your ~/.vault-token
sudo bash -c 'VAULT_TOKEN="$(cat "/home/$SUDO_USER/.vault-token")" exec homelab claude-sessions mcp-secrets capture --user emo'
homelab claude-sessions mcp-secrets list --user emo           # entry names, no values
```

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
