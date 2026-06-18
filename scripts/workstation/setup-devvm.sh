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

# 2) node >= 18 — needed for the t3 CLI (npm-global, below). NOT for claude-code:
#    claude-code is the per-user NATIVE install (the recommended, self-updating
#    ~/.local/bin/claude), provisioned per user by t3-provision-users
#    (install_user_claude_native) and self-bootstrapped by start-claude.sh on first launch.
#    We deliberately do NOT `npm install -g @anthropic-ai/claude-code` — npm/npx is not the
#    recommended runtime, and a system-wide npm copy just shadows/duplicates the per-user
#    native installs everyone auto-migrates to anyway.
need_node=1
if command -v node >/dev/null; then
  [[ "$(node -v | sed 's/^v\([0-9]*\).*/\1/')" -ge 18 ]] && need_node=0
fi
if [[ $need_node -eq 1 ]]; then
  log "node: installing NodeSource 22.x"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y nodejs >/dev/null
fi

# 2a) ~/.local/bin on PATH for all LOGIN shells (machine-wide). The native claude install
#     lives at ~/.local/bin; this guarantees login shells (SSH, etc.) find it regardless of
#     whether the per-user native-installer rc edit ran. (The terminal launcher sets PATH
#     itself, and t3-serve@.service hard-sets PATH in the unit.)
install -d -m 0755 /etc/profile.d
cat > /etc/profile.d/10-local-bin.sh <<'PROFILE_EOF'
# Native per-user installs (e.g. claude-code) live in ~/.local/bin — put it on PATH.
# Guarded so it never duplicates. Sourced by login shells (bash via /etc/profile; zsh
# login via /etc/zsh/zprofile -> /etc/profile).
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
PROFILE_EOF
chmod 0644 /etc/profile.d/10-local-bin.sh
log "/etc/profile.d/10-local-bin.sh (~/.local/bin on PATH for login shells)"

# 2b) t3 (the per-user coding surface) — GATED NIGHTLY TRACKER (2026-06-16; was pinned).
#     t3 is pre-1.0 and ships breaking auth-schema + bootstrap-API changes (2026-06-09
#     outage: a blind nightly auto-update broke pairing for ALL users). The daily
#     t3-autoupdate now FOLLOWS t3@nightly but GATES each bump (populated-DB health-check
#     + canary + auto-rollback + self-freeze) so a bad nightly self-heals. A fresh box has
#     no user state to migrate or sessions to break, so install the current nightly
#     directly; the gated tracker owns it thereafter. Keep T3_TRACK in sync with
#     t3-autoupdate.sh. To freeze/revert: `touch /etc/t3-autoupdate.freeze`.
T3_TRACK="${T3_TRACK:-nightly}"
want_t3="$(npm view "t3@$T3_TRACK" version 2>/dev/null | tail -1)"
if [[ -n "$want_t3" && "$(t3 --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//')" != "$want_t3" ]]; then
  log "npm: installing t3@$T3_TRACK ($want_t3)"; npm install -g "t3@$want_t3" >/dev/null
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
  # 8c) chrome-service snapshot bearer token -> root file the provisioner copies
  #     per-user (if-absent) to ~/.config/playwright/token, which the per-user
  #     playwright-snapshot-refresh reads. One token for all users (single shared
  #     warm profile, by design). 0600: the snapshot it fetches holds cookies.
  if cs_tok="$(vault kv get -field=api_bearer_token secret/chrome-service 2>/dev/null)"; then
    install -m 0600 /dev/stdin /etc/t3-serve/chrome-service-token <<<"$cs_tok"
    log "staged /etc/t3-serve/chrome-service-token (playwright snapshot auth)"
  else
    log "WARN: secret/chrome-service api_bearer_token absent -> playwright snapshot refresh will 401"
  fi
fi

# 9) service layer: install + enable the machine-wide systemd units (sources in
#    infra/scripts/) so a rebuild reproduces them — previously hand-scp'd, they would
#    NOT survive a fresh box. Per-user t3-serve@ INSTANCES are enabled by the
#    provisioner; the ttyd terminal-lobby chain ships from its own repo
#    (forgejo viktor/terminal-lobby, scripts/deploy.sh) — not duplicated here.
SCRIPTS="$HERE/.."
# 9a) scripts the units exec (t3-provision-users already deployed in section 6)
install -m 0755 "$SCRIPTS/t3-autoupdate.sh"   /usr/local/bin/t3-autoupdate
install -m 0755 "$SCRIPTS/t3-backup-state.sh" /usr/local/bin/t3-backup-state
install -m 0755 "$SCRIPTS/t3-mint"            /usr/local/bin/t3-mint
# 9b) t3-dispatch: unprivileged system account + compiled Go binary (build-if-absent)
id -u t3-dispatch >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin t3-dispatch
if [[ ! -x /usr/local/bin/t3-dispatch ]]; then
  if command -v go >/dev/null; then
    log "building t3-dispatch (Go)"; ( cd "$SCRIPTS/t3-dispatch" && go build -o /usr/local/bin/t3-dispatch . )
  else
    log "WARN: go absent -> cannot build t3-dispatch; install golang-go or deploy the binary"
  fi
fi
# 9b2) homelab: unified infra-ops CLI (agent-facing verbs + the in-cluster
#      infra-cli webhook image). Rebuilt from cli/ each run so it tracks the
#      repo; version stamped from cli/VERSION. See cli/README.md + docs/adr/0004-0006.
if command -v go >/dev/null; then
  _hl_src="$SCRIPTS/../cli"
  _hl_ver="$(cat "$_hl_src/VERSION" 2>/dev/null || echo dev)"
  log "building homelab CLI ($_hl_ver)"
  ( cd "$_hl_src" && go build -ldflags "-X main.version=$_hl_ver" -o /usr/local/bin/homelab . ) \
    || log "WARN: homelab CLI build failed"
else
  log "WARN: go absent -> cannot build homelab CLI"
fi
# 9c) sudoers: t3-dispatch may run ONLY t3-mint as root. A malformed file in
#     /etc/sudoers.d breaks ALL sudo, so validate with visudo when available.
if ! command -v visudo >/dev/null || visudo -cf "$SCRIPTS/sudoers-t3-autopair" >/dev/null; then
  install -m 0440 "$SCRIPTS/sudoers-t3-autopair" /etc/sudoers.d/t3-autopair
else
  log "WARN: sudoers-t3-autopair failed visudo validation -> NOT installed"
fi
# 9d) unit files + enablement. Timers self-heal; t3-dispatch is long-running.
#     t3-serve@ is a TEMPLATE (enabled per-user by the provisioner, not here).
for u in t3-serve@.service \
         t3-autoupdate.service t3-autoupdate.timer \
         t3-backup-state.service t3-backup-state.timer \
         t3-provision-users.service t3-provision-users.timer \
         t3-dispatch.service; do
  install -m 0644 "$SCRIPTS/$u" "/etc/systemd/system/$u"
done
# 9e) per-user playwright-mcp browser MCP: system-level TEMPLATE units (one
#     instance per OS user) + the snapshot-refresh script. Reproducible-from-git
#     replacement for the hand-made ~/.config/systemd/user/playwright-* units
#     (no systemd --user / linger needed). Enabled per-user by the provisioner;
#     PLAYWRIGHT_PORT (roster_engine) + the chrome-service token (8c) feed them.
install -m 0755 "$HERE/playwright/playwright-snapshot-refresh" /usr/local/bin/playwright-snapshot-refresh
for u in playwright-mcp@.service playwright-snapshot-refresh@.service playwright-snapshot-refresh@.timer; do
  install -m 0644 "$HERE/playwright/$u" "/etc/systemd/system/$u"
done
log "playwright: template units + snapshot-refresh script installed (per-user enable in provisioner)"
systemctl daemon-reload
systemctl enable --now t3-dispatch.service \
  t3-autoupdate.timer t3-backup-state.timer t3-provision-users.timer >/dev/null 2>&1 || \
  log "WARN: some units failed to enable (check: systemctl status t3-dispatch t3-*.timer)"
log "service units installed + enabled (t3-dispatch + 3 timers; t3-serve@ per-user)"

log "OK (idempotent)"
