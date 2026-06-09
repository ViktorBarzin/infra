#!/usr/bin/env bash
# Idempotent machine-wide host base for the devvm Claude Code Workstation.
# Run as root. Sets up ONLY machine-wide state: the apt toolset, node + claude-code,
# kubelogin, the ENFORCED managed Claude config, and /etc/skel defaults (launcher,
# tmux UX, and live config-inheritance symlinks into the shared config base).
#
# PER-USER provisioning (accounts, per-tier groups, kubeconfig, secrets, infra
# clone) lives in t3-provision-users.sh — NOT here. Safe to re-run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The shared config base every user inherits from (live, chezmoi-versioned).
# Coupled to the admin's home today; override to relocate to a neutral path.
CONFIG_BASE="${WORKSTATION_CONFIG_BASE:-/home/wizard/.claude}"
[[ $EUID -eq 0 ]] || { echo "setup-devvm.sh: must run as root" >&2; exit 1; }
log() { echo "[setup-devvm] $*"; }

# 1) apt toolset (declarative manifest; comments/blank lines stripped)
mapfile -t PKGS < <(grep -vE '^[[:space:]]*(#|$)' "$HERE/packages.txt")
log "apt: ensuring ${#PKGS[@]} packages present"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y "${PKGS[@]}" >/dev/null

# 2) node >= 18 + claude-code (claude-code requires node >= 18)
need_node=1
if command -v node >/dev/null; then
  [[ "$(node -v | sed 's/^v\([0-9]*\).*/\1/')" -ge 18 ]] && need_node=0
fi
if [[ $need_node -eq 1 ]]; then
  log "node: installing NodeSource 22.x"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y nodejs >/dev/null
fi
# Detect the GLOBAL npm package, NOT whatever `claude` resolves to on PATH: the admin's
# personal ~/.local/bin/claude shadows it, so `command -v claude` silently skipped the
# system-wide install — leaving /usr/lib/node_modules/@anthropic-ai empty and fresh
# non-admins with no claude (they only worked because the admin's install was on PATH).
if ! npm ls -g --depth=0 @anthropic-ai/claude-code >/dev/null 2>&1; then
  log "npm: installing @anthropic-ai/claude-code (system-wide)"
  npm install -g @anthropic-ai/claude-code >/dev/null
fi

# 2b) t3 (the per-user coding surface) — PINNED, never nightly/latest. t3 is pre-1.0 and
#     ships breaking auth-schema + bootstrap-API changes our t3-dispatch can't follow blind
#     (2026-06-09 outage: a nightly auto-update broke pairing for ALL users). The daily
#     t3-autoupdate ENFORCER re-asserts this same pin; install it here so a fresh box has t3
#     immediately. Keep T3_PIN in sync with t3-autoupdate.sh.
T3_PIN="${T3_PIN:-0.0.26}"
if [[ "$(t3 --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//')" != "$T3_PIN" ]]; then
  log "npm: installing pinned t3@$T3_PIN"; npm install -g "t3@$T3_PIN" >/dev/null
fi

# 3) kubelogin (kubectl oidc-login) system-wide — NOT the apt 'kubelogin' (= Azure tool).
#    PINNED (not 'latest/download') so two fresh boxes built weeks apart are byte-identical.
KUBELOGIN_VER="${KUBELOGIN_VER:-v1.36.2}"
if [[ ! -x /usr/local/bin/kubelogin ]]; then
  log "kubelogin: installing int128/kubelogin $KUBELOGIN_VER"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/kl.zip" "https://github.com/int128/kubelogin/releases/download/${KUBELOGIN_VER}/kubelogin_linux_amd64.zip"
  ( cd "$tmp" && { unzip -o kl.zip kubelogin >/dev/null 2>&1 || python3 -m zipfile -e kl.zip .; } )
  install -m 0755 "$tmp/kubelogin" /usr/local/bin/kubelogin
  ln -sf /usr/local/bin/kubelogin /usr/local/bin/kubectl-oidc_login
  rm -rf "$tmp"
fi

# 4) machine-wide ENFORCED Claude config (org claudeMd; top precedence; NO secrets)
install -d -m 0755 /etc/claude-code
install -m 0644 "$HERE/managed-settings.json" /etc/claude-code/managed-settings.json
log "managed-settings.json -> /etc/claude-code/ (enforced org claudeMd)"

# 5) /etc/skel for NEW accounts: launcher + tmux UX + live-inheritance symlinks.
#    A symlink placed in /etc/skel is copied (as a symlink) into each new home by
#    `useradd -m`, so new users' ~/.claude/{skills,rules,...} resolve to the shared
#    base and pick up the admin's edits live. Secrets + hooks are per-user (written
#    by the provisioner), NEVER symlinked here.
install -d -m 0755 /etc/skel
install -m 0755 "$HERE/skel/start-claude.sh" /etc/skel/start-claude.sh
install -m 0644 "$HERE/skel/tmux.conf" /etc/skel/.tmux.conf
install -d -m 0755 /etc/skel/.claude
for d in skills rules agents commands; do
  [[ -d "$CONFIG_BASE/$d" ]] && ln -sfn "$CONFIG_BASE/$d" "/etc/skel/.claude/$d"
done
log "skel: launcher + tmux + inheritance symlinks (base=$CONFIG_BASE)"

# 6) deploy the roster-driven provisioner to /usr/local/bin (run hourly by
#    t3-provision-users.timer). Re-deployed here so its logic is reproducible.
install -m 0755 "$HERE/../t3-provision-users.sh" /usr/local/bin/t3-provision-users
log "t3-provision-users -> /usr/local/bin/ (roster-driven)"

# 7) harden the admin's unlocked tree: it holds git-crypt-DECRYPTED secrets, so it
#    must NOT be world-readable — only the admin + code-shared. Without this, ANY
#    devvm user (even outside code-shared) could read decrypted secrets by path.
ADMIN_CODE="${ADMIN_CODE:-/home/wizard/code}"
if [[ -d "$ADMIN_CODE" ]]; then
  chmod o-rx "$ADMIN_CODE"
  log "hardened $ADMIN_CODE (o-rx — not world-readable)"
fi

# 8) /etc/t3-serve (per-user .env + dispatch config dir; also holds the staged tokens
#    below) + shared service auth pulled from Vault. install -m alone does NOT create the
#    parent dir, so a fresh box needs this mkdir before the token writes below.
install -d -m 0755 /etc/t3-serve
if command -v vault >/dev/null; then
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.viktorbarzin.me}"
  # setup-devvm runs as root (no ~/.vault-token); borrow the admin's token to read Vault.
  if [[ -z "${VAULT_TOKEN:-}" && -r /home/wizard/.vault-token ]]; then
    VAULT_TOKEN="$(cat /home/wizard/.vault-token)"; export VAULT_TOKEN
  fi
  # 8a) Shared Claude subscription OAuth token (long-lived sk-ant-oat01) -> root file the
  #     provisioner injects into non-admins' t3-serve env (only those without their own login).
  if claude_tok="$(vault kv get -field=claude_oauth_token secret/workstation 2>/dev/null)"; then
    install -m 0600 /dev/stdin /etc/t3-serve/claude-oauth-token <<<"$claude_tok"
    log "staged /etc/t3-serve/claude-oauth-token (shared Claude subscription)"
  else
    log "WARN: secret/workstation claude_oauth_token absent -> non-admins won't share Claude auth"
  fi
  # 8b) Shared Codex auth -> /opt/codex-shared/auth.json (the codex wrapper symlinks each
  #     user's ~/.codex/auth.json here). Previously a manual host change that did NOT survive
  #     a rebuild even though the Vault key existed — now reproducible from Vault.
  if codex_auth="$(vault kv get -field=codex_shared_auth_json secret/workstation 2>/dev/null)"; then
    getent group codex-shared >/dev/null || groupadd codex-shared
    install -d -m 2770 -g codex-shared /opt/codex-shared
    install -m 0660 -g codex-shared /dev/stdin /opt/codex-shared/auth.json <<<"$codex_auth"
    log "staged /opt/codex-shared/auth.json (shared Codex auth)"
  else
    log "WARN: secret/workstation codex_shared_auth_json absent -> shared Codex auth not staged"
  fi
fi

log "OK (idempotent)"
