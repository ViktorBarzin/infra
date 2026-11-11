# Runbook: devvm credentials and dotfiles on a rebuilt box

**Host:** `devvm` (10.0.10.10), users `wizard`, `emo`, `ancamilea`
**Plan:** [disposable devvm](../plans/2026-11-11-disposable-devvm.md), the "Credentials" and "Dotfiles" kept places
**Tool:** `scripts/workstation/workstation-creds.sh` (tests: `bash scripts/test-workstation-creds.sh`)
**Provisioner steps:** `restore_user_credentials`, `install_vault_token_renew`, `install_user_dotfiles` in `scripts/t3-provision-users.sh` (tests: `bash scripts/test-t3-provision-creds.sh`)

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
| wizard | 33 | SSH keys and config (two as refs to `secret/viktor` and `secret/opnsense`), both GPG keys with keyring, trust DB, agent config and revocation certificates, `.git-credentials`, gh, gcloud, docker, the admin `.kube/config`, the zsh secrets file, the lobby-local env file, chezmoi's config |
| emo | 13 | SSH keys, config and authorized_keys, `.git-credentials`, three service token files under `.config/` |
| ancamilea | 6 | SSH key and authorized_keys, `.git-credentials`, gh |

Not stored here, because something else already brings them back:

- `~/.vault-token`: minted by `install_vault_token_renew` (see [vault-token-renew-devvm](vault-token-renew-devvm.md)).
- `~/.config/claude-auth-sync/vault-token`: minted by `install_claude_auth_sync`; the Claude credential itself is backed up by `claude-auth-sync@` to `secret/workstation/claude-users/<user>`.
- wizard's `~/.ssh/authorized_keys`: the playbook writes it from `secret/devvm-authorized-keys`.
- The Bitwarden CLI login in `~/.config/Bitwarden CLI/data.json`: its server, account and API key are the `vaultwarden_*` keys in `secret/workstation/claude-users/wizard`, which `homelab vault` logs in with on its own. The 1.9 MB file is the CLI's encrypted cache. emo's copy holds no account.
- rclone: no config exists on the box and the binary is not installed.

Loose secrets moved out of wizard's home on 2026-11-11, each checked by hash
against Vault first and then deleted:

| Was | Now |
|---|---|
| `~/code/keys.txt` (61 `sk-` API keys, none already in Vault) | `secret/workstation/wizard/loose/keys-txt`, field `content_b64` |
| `~/code/infra-git-crypt-key` (the infra repo's git-crypt key; until then it existed only there, in the clone's `.git` and in the `woodpecker/git-crypt-key` ConfigMap) | `secret/infra`, field `git_crypt_key_b64` |
| `~/meshcentral-data/*-private.key` (5 keys, byte-identical to the live meshcentral pod's) | `secret/meshcentral`, one field per key |
| `~/code/tmp_id` (a single newline, no secret) | deleted |

The nightly devvm-home backup on the Proxmox host still holds the deleted
copies until its 14 generations roll over.

## Rebuild: put a user's credentials back

The hourly provisioner run has no Vault token, so it only logs
`credential restore skipped`. On a new box, once the admin account and the
infra clone exist (playbook), run it once with an admin token:

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me
vault login -method=oidc            # or export VAULT_TOKEN=<an admin token>
export VAULT_TOKEN="$(cat ~/.vault-token)"
sudo --preserve-env=VAULT_TOKEN,VAULT_ADDR t3-provision-users
```

Order inside that run: credentials for every existing account (step 3d: the
admin kubeconfig is what the other users' kubeconfigs copy the cluster
address from), then per account: dotfiles, clones, kubeconfigs, and
`vault-token-renew` with a first `~/.vault-token`. A file that is already
there is never replaced, so running it again, or on the live box, writes
nothing.

To unlock wizard's infra clone on the new box:

```bash
k=$(mktemp); vault kv get -field=git_crypt_key_b64 secret/infra | base64 -d > "$k"
(cd ~/code/infra && git-crypt unlock "$k"); rm -f "$k"
```

## Dotfiles

A roster row with `dotfiles: owner/name` (wizard: `viktor/dot_files`) gets
`chezmoi init --apply --force --no-tty --keep-going --exclude=encrypted`
from that Forgejo repo, once, when `~/.local/share/chezmoi` does not exist;
chezmoi itself is installed into `~/.local/bin` at `CHEZMOI_VERSION` when
missing. An existing source is never touched, because the live home has
drifted from the repo and a whole-tree apply would overwrite work there.

The two GPG-encrypted entries in the dotfiles (`.kube/config` and
`.oh-my-zsh/custom/secrets.zsh`) are skipped by `--exclude=encrypted` and,
on hosts whose name starts with `devvm`, by the repo's `.chezmoiignore`; on
the devvm both come from the credential restore above. That also makes a
whole-tree `chezmoi status` or `apply` finish there without a passphrase.

wizard's user units live in the dotfiles since 2026-11-11, with the
`*.target.wants` links that enable them: `lobby-local.service` (devvm only),
`tmux-plugin-update.{service,timer}` with `~/.local/bin/tmux-plugin-update`,
and the link for the existing `agents-sync.timer`. `tmux.service` was left
out: it was retired on 2026-11-02 and is disabled.

## Add or refresh a credential

When a token is rotated or a new hand-made credential appears, store it
again (each `put` is a new KV version):

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me VAULT_TOKEN="$(cat ~/.vault-token)"
C=~/code/infra/scripts/workstation/workstation-creds.sh
sudo --preserve-env=VAULT_TOKEN,VAULT_ADDR bash $C capture <user> .config/gh/hosts.yml
bash $C capture-ref <user> .ssh/some_key 'secret/<path>#<field>'   # already in Vault elsewhere
bash $C list <user>                                                # paths and modes, no values
```

`.git-credentials` and `.docker/config.json` hold copies of tokens that also
live in `secret/viktor` (`github_pat`) and other paths, so a rotation of
those needs a `capture` of the file too.

## Check a restore without touching a home

```bash
d=$(mktemp -d)
bash $C restore <user> --into "$d"
(cd "$d" && find . -type f -printf '%m %P\n' | sort)   # compare with the live home's modes
rm -rf "$d"                                             # it holds the secrets
```

On 2026-11-11 this restored 33, 13 and 6 files for wizard, emo and
ancamilea, each with the live home's names and modes and byte-identical
content; the restored GPG home listed both secret keys, the SSH keys had
the live fingerprints, and `kubectl get nodes` worked with the restored
kubeconfig.

## Open questions

- ancamilea is not in `roster.yaml` (commented out 2026-08-17), so the
  provisioner restores nothing for her; her files are stored and
  `workstation-creds restore ancamilea` puts them back by hand.
