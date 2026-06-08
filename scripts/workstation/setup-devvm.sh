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
command -v claude >/dev/null || { log "npm: installing @anthropic-ai/claude-code"; npm install -g @anthropic-ai/claude-code >/dev/null; }

# 3) kubelogin (kubectl oidc-login) system-wide — NOT the apt 'kubelogin' (= Azure tool)
if [[ ! -x /usr/local/bin/kubelogin ]]; then
  log "kubelogin: installing int128/kubelogin"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/kl.zip" https://github.com/int128/kubelogin/releases/latest/download/kubelogin_linux_amd64.zip
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

log "OK (idempotent)"
