#!/usr/bin/env bash
# Reconcile per-user t3 Workstation instances from roster.yaml (the single source
# of truth). roster_engine.py derives the desired state (accounts, per-tier groups,
# sticky ports, /etc/ttyd-user-map, dispatch.json); this script APPLIES it.
#
# ADDITIVE-ONLY for existing users: never removes a group, never replaces a home,
# never re-locks/re-chmods an existing account — so a routine (hourly) reconcile is
# always safe for live users. Destructive offboarding (userdel) is a SEPARATE, gated
# path, never here. Runs hourly as root via t3-provision-users.timer; root has no
# Vault token, so tier validation is best-effort (skipped when k8s_users is unreachable).
#
# DRY_RUN=1 prints actions without mutating. WORKSTATION_DIR overrides the roster/engine location.
set -euo pipefail

WORKSTATION_DIR="${WORKSTATION_DIR:-/home/wizard/code/infra/scripts/workstation}"
ENGINE="$WORKSTATION_DIR/roster_engine.py"
ROSTER="$WORKSTATION_DIR/roster.yaml"
ENVDIR=/etc/t3-serve
MAP=/etc/ttyd-user-map
DRY_RUN="${DRY_RUN:-0}"
# Public infra repo for the locked clone (no auth; the monorepo has no remote).
INFRA_REMOTE="${INFRA_REMOTE:-https://github.com/ViktorBarzin/infra.git}"
# Canonical push target for non-admin infra clones (AGENTS.md "Non-admin
# workstation users"), and the base URL for workspace-layout `repos` entries —
# those clone AS the user so their ~/.git-credentials PAT authenticates
# against private Forgejo repos.
FORGEJO_INFRA_REMOTE="${FORGEJO_INFRA_REMOTE:-https://forgejo.viktorbarzin.me/viktor/infra.git}"
REPO_REMOTE_BASE="${REPO_REMOTE_BASE:-https://forgejo.viktorbarzin.me/viktor}"
# Per-user OIDC kubeconfig (kubelogin/PKCE; cluster server+CA copied from the admin kubeconfig).
OIDC_ISSUER="${OIDC_ISSUER:-https://authentik.viktorbarzin.me/application/o/kubernetes/}"
ADMIN_KUBECONFIG="${ADMIN_KUBECONFIG:-/home/wizard/.kube/config}"

log() { echo "[t3-provision] $*"; }
run() { if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }

# Per-non-admin writable, git-crypt-LOCKED infra clone at ~/<subpath>. Keyless +
# filter=cat ⇒ code/docs are plaintext, git-crypt'd secret files stay ciphertext.
# Writable + ungated (push != apply; applies are admin-only). NEVER touches an
# existing target (so emo's symlink survives until the gated cutover). subpath
# is "code" (single layout) or "code/infra" (workspace layout).
install_locked_clone() {
  local user="$1" sub="$2" home dst
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -z "$home" ]] && return 0
  dst="$home/$sub"
  [[ -e "$dst" || -L "$dst" ]] && return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] locked infra clone -> $user:$dst"; return 0; fi
  log "clone locked infra -> $user:~/$sub"
  runuser -u "$user" -- git clone --quiet --no-checkout "$INFRA_REMOTE" "$dst"
  runuser -u "$user" -- git -C "$dst" config filter.git-crypt.smudge cat
  runuser -u "$user" -- git -C "$dst" config filter.git-crypt.clean cat
  runuser -u "$user" -- git -C "$dst" config filter.git-crypt.required false
  runuser -u "$user" -- git -C "$dst" checkout --quiet master
}

# Keep an EXISTING non-admin clone fresh (the admin's tree is never touched): fetch
# all remotes, then fast-forward master only when that is provably safe — on master,
# clean tree, upstream configured. Never rebases/merges; a non-ff master (local
# commits) is the user's to reconcile and is only WARNed about. Fetch failures
# (offline, missing credentials) are non-fatal: freshness is best-effort.
refresh_user_clone() {
  local user="$1" sub="$2" home dir
  home="$(getent passwd "$user" | cut -d: -f6)"
  dir="$home/$sub"
  [[ -n "$home" && -d "$dir/.git" ]] || return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] refresh clone -> $user:$dir"; return 0; fi
  runuser -u "$user" -- env GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch --all --prune --quiet 2>/dev/null \
    || { log "WARN: fetch failed for $user:$sub (offline/credentials?) — skipped"; return 0; }
  [[ "$(runuser -u "$user" -- git -C "$dir" symbolic-ref --short -q HEAD)" == master ]] || return 0
  [[ -z "$(runuser -u "$user" -- git -C "$dir" status --porcelain)" ]] || return 0
  runuser -u "$user" -- git -C "$dir" rev-parse --verify -q 'master@{upstream}' >/dev/null || return 0
  runuser -u "$user" -- git -C "$dir" merge --ff-only 'master@{upstream}' >/dev/null 2>&1 \
    || log "WARN: $user:$sub master not fast-forwardable (local commits?) — left as-is"
}

# Non-admin infra clones are documented to carry a `forgejo` remote (the
# canonical push target) with master tracking forgejo/master — see AGENTS.md
# "Non-admin workstation users". Clones made before that contract only have
# the GitHub origin; wire the remote + upstream idempotently. Best-effort: an
# offline fetch leaves the upstream as-is.
wire_forgejo_remote() {
  local user="$1" sub="$2" home dir
  home="$(getent passwd "$user" | cut -d: -f6)"
  dir="$home/$sub"
  [[ -n "$home" && -d "$dir/.git" ]] || return 0
  if ! runuser -u "$user" -- git -C "$dir" remote get-url forgejo >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] add forgejo remote -> $user:$sub"; return 0; fi
    log "add forgejo remote -> $user:~/$sub"
    runuser -u "$user" -- git -C "$dir" remote add forgejo "$FORGEJO_INFRA_REMOTE"
  fi
  [[ "$DRY_RUN" == 1 ]] && return 0
  [[ "$(runuser -u "$user" -- git -C "$dir" rev-parse --abbrev-ref -q 'master@{upstream}' 2>/dev/null)" == forgejo/master ]] && return 0
  runuser -u "$user" -- env GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch --quiet forgejo 2>/dev/null \
    || { log "WARN: forgejo fetch failed for $user — upstream left as-is"; return 0; }
  runuser -u "$user" -- git -C "$dir" branch --set-upstream-to=forgejo/master master >/dev/null 2>&1 \
    && log "set $user:~/$sub master upstream -> forgejo/master" \
    || log "WARN: could not set $user:~/$sub master upstream to forgejo/master"
}

# Workspace layout: ~/code is a plain directory of per-project clones. A user
# still on the single layout (~/code IS the infra clone) is migrated by moving
# the whole clone — local branches, dirty files, untracked state all survive —
# to ~/code/infra. Running processes follow the moved inode, so live sessions
# keep working (their cwd lands inside ~/code/infra).
ensure_workspace_layout() {
  local user="$1" home tmp
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -z "$home" ]] && return 0
  if [[ -d "$home/code/.git" ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] migrate $user:~/code (single clone) -> ~/code/infra"; return 0; fi
    log "migrate $user: ~/code (single infra clone) -> ~/code/infra"
    tmp="$home/.code-workspace-migrate.$$"
    mv "$home/code" "$tmp"
    install -d -o "$user" -g "$user" -m 0755 "$home/code"
    mv "$tmp" "$home/code/infra"
  elif [[ ! -e "$home/code" ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] create workspace dir $user:~/code"; return 0; fi
    install -d -o "$user" -g "$user" -m 0755 "$home/code"
  fi
}

# Single-layout clones often accumulated nested project clones (the old layout
# gave users nowhere else to put them — e.g. ancamilea's tripit inside ~/code).
# After migration such a clone would sit buried at ~/code/infra/<repo>; hoist a
# roster repo to its workspace home instead of stranding it + cloning fresh.
# Only untracked git dirs move — content the infra repo tracks is never touched.
hoist_nested_repo() {
  local user="$1" repo="$2" home src dst
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -z "$home" ]] && return 0
  src="$home/code/infra/$repo"; dst="$home/code/$repo"
  [[ -d "$src/.git" && ! -e "$dst" ]] || return 0
  runuser -u "$user" -- git -C "$home/code/infra" ls-files --error-unmatch "$repo" >/dev/null 2>&1 && return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] hoist nested $repo -> $user:$dst"; return 0; fi
  log "hoist nested $repo clone -> $user:~/code/$repo"
  mv "$src" "$dst"
}

# Extra per-project repos for workspace-layout users, cloned from Forgejo AS
# the user (their ~/.git-credentials PAT authenticates against private repos).
# A failed clone (no access yet, offline) is a WARN — the reconcile must never
# abort over a single repo; the next hourly run retries.
install_user_repo() {
  local user="$1" repo="$2" home dst
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -z "$home" ]] && return 0
  dst="$home/code/$repo"
  [[ -e "$dst" || -L "$dst" ]] && return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] clone $REPO_REMOTE_BASE/$repo.git -> $user:$dst"; return 0; fi
  log "clone $repo -> $user:~/code/$repo"
  runuser -u "$user" -- env GIT_TERMINAL_PROMPT=0 git clone --quiet "$REPO_REMOTE_BASE/$repo.git" "$dst" 2>/dev/null \
    || log "WARN: clone of $repo failed for $user (access/offline?) — skipped"
}

# Machine-wide Claude managed config: the repo file (in the admin tree, like the
# roster) is the authoring surface; deploying it here means a plain infra commit
# propagates claudeMd/model edits to /etc — and thus every user's NEXT session —
# within one reconcile cycle. No manual install step.
sync_managed_config() {
  local src="$WORKSTATION_DIR/managed-settings.json" dst=/etc/claude-code/managed-settings.json
  [[ -r "$src" ]] || return 0
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$src" 2>/dev/null \
    || { log "WARN: $src is invalid JSON — managed-config sync skipped"; return 0; }
  cmp -s "$src" "$dst" 2>/dev/null && return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] managed-settings.json -> $dst"; return 0; fi
  install -D -m 0644 "$src" "$dst"
  log "deployed managed-settings.json -> /etc/claude-code (repo copy changed)"
}

# ~/.codex/AGENTS.md is a STATIC mirror of the managed claudeMd (codex has no
# machine-wide managed layer). Regenerate stale mirrors so codex sessions inherit
# claudeMd edits the same way Claude sessions do. Never clobbers a user-customized
# file: only touches files carrying the mirror header (or creates absent ones).
refresh_codex_mirror() {
  local user="$1" home dst tmp
  home="$(getent passwd "$user" | cut -d: -f6)"
  dst="$home/.codex/AGENTS.md"
  [[ -n "$home" && -d "$home/.codex" ]] || return 0
  if [[ -f "$dst" ]] && ! head -1 "$dst" | grep -q '^# Codex global instructions (devvm)'; then return 0; fi
  tmp="$(mktemp)"
  { printf '# Codex global instructions (devvm)\n\n_Mirrors the machine-wide Claude managed policy._\n\n---\n\n'
    python3 -c 'import json; print(json.load(open("/etc/claude-code/managed-settings.json"))["claudeMd"])'
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  if cmp -s "$tmp" "$dst" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] codex AGENTS.md mirror -> $user"; rm -f "$tmp"; return 0; fi
  install -o "$user" -g "$user" -m 0644 "$tmp" "$dst"; rm -f "$tmp"
  log "refreshed codex AGENTS.md mirror -> $user"
}

# Per-user OIDC kubeconfig (kubelogin/PKCE — the `kubernetes` Authentik client is
# public, no secret). Identical for all users: identity comes from each user's own
# interactive OIDC login, which the apiserver maps (email claim) to their RBAC.
# Cluster server + CA are copied from the admin kubeconfig. If-absent, never clobber.
install_user_kubeconfig() {
  local user="$1" home kc server ca
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -z "$home" ]] && return 0
  kc="$home/.kube/config"
  [[ -f "$kc" ]] && return 0
  [[ -r "$ADMIN_KUBECONFIG" ]] || { log "WARN: $ADMIN_KUBECONFIG unreadable -> skip kubeconfig for $user"; return 0; }
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] OIDC kubeconfig -> $user:$kc"; return 0; fi
  server="$(KUBECONFIG="$ADMIN_KUBECONFIG" kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
  ca="$(KUBECONFIG="$ADMIN_KUBECONFIG" kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  [[ -n "$server" && -n "$ca" ]] || { log "WARN: could not read cluster server/CA -> skip kubeconfig for $user"; return 0; }
  install -d -o "$user" -g "$user" -m 0700 "$home/.kube"
  cat > "$kc" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: homelab
  cluster:
    server: $server
    certificate-authority-data: $ca
contexts:
- name: oidc@homelab
  context:
    cluster: homelab
    user: oidc
current-context: oidc@homelab
users:
- name: oidc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: kubectl
      args:
      - oidc-login
      - get-token
      - --oidc-issuer-url=$OIDC_ISSUER
      - --oidc-client-id=kubernetes
      - --oidc-extra-scope=email
      - --oidc-extra-scope=profile
      - --oidc-extra-scope=groups
      interactiveMode: IfAvailable
EOF
  chown "$user:$user" "$kc"; chmod 0600 "$kc"
  log "wrote OIDC kubeconfig -> $user:~/.kube/config"
}

# Idempotently set KEY=VALUE in a t3-serve env file, PRESERVING other lines — so writing
# T3_PORT never clobbers an injected CLAUDE_CODE_OAUTH_TOKEN, and vice-versa. Mode 0600.
env_set() {
  local file="$1" key="$2" val="$3"
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] set $key -> $file"; return 0; fi
  install -d -m 0755 "$(dirname "$file")"
  if [[ -f "$file" ]] && grep -q "^${key}=" "$file"; then
    grep -qx "${key}=${val}" "$file" || sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
  chmod 600 "$file"
}

env_unset() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep -q "^${key}=" "$file" || return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] unset $key -> $file"; return 0; fi
  sed -i "/^${key}=.*/d" "$file"
  chmod 600 "$file"
  log "removed legacy shared $key -> $(basename "$file")"
}

# Install one user's isolated Claude credential renewal flow. The scoped periodic
# Vault token is minted only when this reconcile has admin Vault access (normal
# onboarding/deployment); routine token renewal is performed by the user service.
install_claude_auth_sync() {
  local user="$1" home cfg token_file token policy
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -z "$home" ]] && return 0
  cfg="$home/.config/claude-auth-sync"
  token_file="$cfg/vault-token"
  policy="workstation-claude-$user"

  # The service sandbox makes the rest of $HOME read-only. Pre-create every
  # writable path before systemd enters that sandbox; ReadWritePaths cannot
  # create a missing child beneath a read-only parent.
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry-run] ensure Claude-auth state dirs -> $user"
  else
    install -d -o "$user" -g "$user" -m 0700 "$cfg" "$home/.local/state/claude-auth-sync"
  fi

  if [[ ! -s "$token_file" ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then
      echo "[dry-run] mint scoped Claude-auth Vault token -> $user"
    elif vault token lookup >/dev/null 2>&1 && \
      token="$(vault token create -orphan -period=768h -policy="$policy" \
        -display-name="devvm-claude-auth-$user" -field=token 2>/dev/null)"; then
      install -d -o "$user" -g "$user" -m 0700 "$cfg"
      install -o "$user" -g "$user" -m 0600 /dev/stdin "$token_file" <<<"$token"
      log "minted isolated Claude-auth Vault token -> $user"
    else
      log "WARN: scoped Claude-auth Vault token missing for $user (run provisioner with admin VAULT_TOKEN after vault stack apply)"
    fi
  fi
  run systemctl enable --now "claude-auth-sync@$user.timer" >/dev/null 2>&1 || true
}

# Re-deploy the managed per-user Claude launcher to ~/start-claude.sh. /etc/skel only
# seeds it at account creation (setup-devvm.sh), so without this a launcher edit never
# reaches EXISTING users — they keep running a stale copy. Copy-if-changed from the repo's
# skel/, owned by the user, 0755. (We deliberately do NOT re-copy .tmux.conf: terminal-lobby
# appends a managed persistence section to each user's ~/.tmux.conf that a re-copy would clobber.)
deploy_user_launcher() {
  local user="$1" home src dst
  src="$WORKSTATION_DIR/skel/start-claude.sh"
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" && -f "$src" ]] || return 0
  dst="$home/start-claude.sh"
  cmp -s "$src" "$dst" 2>/dev/null && return 0          # already current -> no churn
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] deploy launcher -> $dst"; return 0; fi
  install -m 0755 "$src" "$dst"
  chown "$user:$user" "$dst"
  log "deployed start-claude.sh -> $user"
}

# Ensure the per-user NATIVE claude install (the recommended runtime: ~user/.local/bin/claude,
# self-updating) — used by BOTH the terminal launcher AND the user's t3-serve instance. We do
# NOT npm-install claude system-wide (npm/npx isn't the recommended runtime); each user gets
# their own native install. Idempotent: skip if already present. Runs the official native
# installer AS the user (into their ~/.local). Best-effort: a failure WARNs and retries next
# reconcile (start-claude.sh also self-bootstraps the terminal path).
install_user_claude_native() {
  local user="$1" home
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0
  [[ -x "$home/.local/bin/claude" ]] && return 0          # already native -> done
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] native claude install -> $user"; return 0; fi
  if runuser -u "$user" -- bash -lc 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null 2>&1; then
    log "installed native claude -> $user"
  else
    log "WARN: native claude install failed for $user (retries next reconcile)"
  fi
}

# Per-user playwright-mcp browser MCP — ALL tiers incl. admin (every user's Claude
# sessions connect to their OWN isolated server; a user's concurrent sessions are
# kept apart by the unit's --isolated). Idempotent + if-absent, so a routine
# reconcile never disturbs a live user: (1) seed the chrome-service snapshot token
# if the user has none; (2) wire the user-scope `playwright` MCP entry by running
# `claude mcp add` AS the user (writes THEIR ~/.claude.json, never reads another's;
# the CLI merges one key and REFUSES to clobber an existing one, so it's safe on a
# populated config), guarded by `claude mcp get`; (3) `enable --now` the system
# template instances (idempotent — does NOT restart an already-running server).
# Needs PLAYWRIGHT_PORT already in the per-user playwright env (written by the
# section-5c loop) + the token staged by setup-devvm.sh (section 8c).
install_playwright() {
  local user="$1" home port token_staged=/etc/t3-serve/chrome-service-token
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0
  port="$(grep -oE 'PLAYWRIGHT_PORT=[0-9]+' "$ENVDIR/playwright-$user.env" 2>/dev/null | cut -d= -f2 || true)"
  [[ -n "$port" ]] || { log "WARN: no PLAYWRIGHT_PORT for $user -> skip playwright"; return 0; }

  # (1) chrome-service snapshot token, if-absent (0600, owned by the user)
  if [[ ! -f "$home/.config/playwright/token" && -r "$token_staged" ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] seed playwright token -> $user"; else
      install -d -o "$user" -g "$user" -m 0700 "$home/.config/playwright"
      install -o "$user" -g "$user" -m 0600 "$token_staged" "$home/.config/playwright/token"
      log "seeded playwright snapshot token -> $user"
    fi
  fi

  # (2) wire user-scope ~/.claude.json (AS the user, login shell so the native
  #     ~/.local/bin/claude is on PATH; clobber-proof + if-absent via `mcp get`)
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry-run] wire playwright MCP (:$port) if-absent -> $user"
  elif runuser -u "$user" -- bash -lc 'command -v claude >/dev/null 2>&1'; then
    if ! runuser -u "$user" -- bash -lc 'claude mcp get playwright >/dev/null 2>&1'; then
      runuser -u "$user" -- bash -lc "claude mcp add --scope user --transport http playwright 'http://localhost:$port/mcp' >/dev/null 2>&1" \
        && log "wired playwright MCP (user scope, :$port) -> $user" \
        || log "WARN: claude mcp add playwright failed for $user (retries next run)"
    fi
  else
    log "WARN: claude not found for $user -> playwright MCP not wired (retries next run)"
  fi

  # (3) enable the system template instances. `enable --now` is idempotent and
  #     does NOT restart a running unit, so a live user is undisturbed.
  run systemctl enable --now "playwright-mcp@$user.service" >/dev/null 2>&1 || true
  run systemctl enable --now "playwright-snapshot-refresh@$user.timer" >/dev/null 2>&1 || true
}

# Per-user homelab-memory setup — migrate off the claude-memory MCP/plugin to the
# homelab CLI hooks (auto-recall + auto-learn + compaction backup/recovery).
# Idempotent, if-absent, ADDITIVE: never clobbers `env` (the per-user
# MEMORY_API_KEY) or other MCP servers; removes ONLY the `claude_memory` MCP.
# Reuses the user's existing key — does NOT mint one (per-user isolation stays
# deferred, design 2026-06-08). The homelab CLI (/usr/local/bin/homelab) hits the
# same remote HTTP API the MCP used. Hook scripts: $WORKSTATION_DIR/claude-hooks.
install_memory() {
  local user="$1" home
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0
  local src="$WORKSTATION_DIR/claude-hooks" hooks_dst="$home/.claude/hooks" settings="$home/.claude/settings.json"
  [[ -d "$src" ]] || { log "WARN: $src missing -> skip memory setup for $user"; return 0; }

  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] memory: hooks + settings wire + claude_memory MCP removal -> $user"; return 0; fi

  # (1) (re)install the 4 hook scripts, owned by the user (refreshed each reconcile so fixes land)
  install -d -o "$user" -g "$user" -m 0755 "$hooks_dst"
  local h
  for h in homelab-memory-recall.py auto-learn.py pre-compact-backup.sh post-compact-recovery.sh; do
    install -o "$user" -g "$user" -m 0755 "$src/$h" "$hooks_dst/$h"
  done

  # (2) wire the hooks in settings.json, if-absent + additive. Run the helper as ROOT:
  #     it must read $src under the admin's hardened home (mode 700), which a
  #     runuser-as-$user CANNOT traverse — so chown the result back to the user and
  #     enforce 0600 (it holds the per-user MEMORY_API_KEY).
  if python3 "$src/wire-memory-hooks.py" "$home" >/dev/null 2>&1; then
    [[ -f "$settings" ]] && chown "$user:$user" "$settings" 2>/dev/null || true
    log "memory hooks wired -> $user"
  else
    log "WARN: memory hook wiring failed for $user (retries next reconcile)"
  fi
  [[ -f "$settings" ]] && chmod 600 "$settings"

  # (2b) reuse the user's existing key; warn (do NOT mint — needs an admin vault write) if absent.
  if [[ -f "$settings" ]] && ! grep -q 'MEMORY_API_KEY' "$settings"; then
    log "WARN: $user has no MEMORY_API_KEY in settings.json — homelab memory no-ops until an admin mints one"
  fi

  # (3) remove the now-superseded claude_memory MCP (AS the user, if-present) + the plugin dir.
  if runuser -u "$user" -- bash -lc 'command -v claude >/dev/null 2>&1 && claude mcp get claude_memory >/dev/null 2>&1'; then
    runuser -u "$user" -- bash -lc 'claude mcp remove claude_memory >/dev/null 2>&1' && log "removed claude_memory MCP -> $user" || true
  fi
  [[ -d "$home/.claude/plugins/claude-memory" ]] && rm -rf "$home/.claude/plugins/claude-memory" && log "removed claude-memory plugin dir -> $user"
}

[[ $EUID -eq 0 ]] || { echo "t3-provision-users: must run as root" >&2; exit 1; }
for bin in python3 jq; do command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }; done
[[ -f "$ROSTER" && -f "$ENGINE" ]] || { echo "roster/engine not under $WORKSTATION_DIR" >&2; exit 1; }
install -d -m 0755 "$ENVDIR"

# 1) current sticky ports from existing .env files -> {os_user: port}
ports_file="$(mktemp)"; pw_ports_file="$(mktemp)"
trap 'rm -f "$ports_file" "$pw_ports_file" "${desired_file:-}"' EXIT
{ echo "{}"; for f in "$ENVDIR"/*.env; do
    [[ -e "$f" ]] || continue
    case "$(basename "$f")" in playwright-*) continue;; esac   # not a t3-serve env (handled below)
    # `|| true`: grep returns non-zero on no-match, which would abort under `set -e -o pipefail`.
    u="$(basename "$f" .env)"; p="$(grep -oE 'T3_PORT=[0-9]+' "$f" | cut -d= -f2 || true)"
    [[ -n "$p" ]] && jq -n --arg u "$u" --argjson p "$p" '{($u): $p}'
  done; } | jq -s 'add' > "$ports_file"
# sticky PLAYWRIGHT ports from playwright-<os_user>.env (skipped by the loop above).
# Seeds roster_engine so the live per-user assignments stick across reconciles.
{ echo "{}"; for f in "$ENVDIR"/playwright-*.env; do
    [[ -e "$f" ]] || continue
    u="$(basename "$f" .env)"; u="${u#playwright-}"
    p="$(grep -oE 'PLAYWRIGHT_PORT=[0-9]+' "$f" | cut -d= -f2 || true)"
    [[ -n "$p" ]] && jq -n --arg u "$u" --argjson p "$p" '{($u): $p}'
  done; } | jq -s 'add' > "$pw_ports_file"

# 2) tier validation vs live k8s_users (best-effort; aborts only on a real conflict)
if command -v vault >/dev/null; then
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.viktorbarzin.me}"
  if k8s_raw="$(vault kv get -field=k8s_users secret/platform 2>/dev/null)"; then
    k8s_file="$(mktemp)"; echo "$k8s_raw" | jq -c 'map_values(.role)' > "$k8s_file"
    if ! python3 "$ENGINE" validate --roster "$ROSTER" --k8s-users-json "$k8s_file"; then
      rm -f "$k8s_file"; echo "[t3-provision] ABORT: roster tier conflicts with k8s_users" >&2; exit 1
    fi
    rm -f "$k8s_file"
  else
    log "WARN: k8s_users unreachable (no Vault token?) -> skipping tier validation"
  fi
fi

# 3) derive desired state
desired_file="$(mktemp)"
python3 "$ENGINE" derive --roster "$ROSTER" --ports-json "$ports_file" --playwright-ports-json "$pw_ports_file" > "$desired_file"
jq -e . "$desired_file" >/dev/null || { echo "[t3-provision] derive produced invalid JSON" >&2; exit 1; }

# 3b) machine-wide Claude managed config (repo -> /etc; per-user codex mirrors in the loop below)
sync_managed_config

# 4) per-account: create-if-absent + ADDITIVE tier groups (never strip) + locked clone
# NB: empty @tsv fields collapse under tab-IFS read (tab is IFS whitespace), so
# the jq below emits "-" for empty groups/repos and we map it back here.
while IFS=$'\t' read -r os_user tier shell groups_csv code_layout repos_csv; do
  [[ "$groups_csv" == "-" ]] && groups_csv=""
  [[ "$repos_csv" == "-" ]] && repos_csv=""
  if ! id "$os_user" >/dev/null 2>&1; then
    log "create account: $os_user (shell $shell)"
    run useradd -m -s "$shell" "$os_user"
    run passwd -l "$os_user"           # SSO/t3 only — no local password
    run chmod 700 "/home/$os_user"
  fi
  if [[ -n "$groups_csv" ]]; then
    current="$(id -nG "$os_user" 2>/dev/null | tr ' ' '\n')"
    IFS=',' read -ra want <<< "$groups_csv"
    for g in "${want[@]}"; do
      grep -qx "$g" <<< "$current" && continue         # already a member -> skip
      getent group "$g" >/dev/null 2>&1 || continue     # group must exist
      log "add $os_user -> group $g"; run gpasswd -a "$os_user" "$g" >/dev/null
    done
  fi
  if [[ "$tier" != admin ]]; then            # non-admins: locked clone(s) (kept fresh) + kubeconfig
    if [[ "$code_layout" == workspace ]]; then
      ensure_workspace_layout "$os_user"
      install_locked_clone "$os_user" code/infra
      wire_forgejo_remote  "$os_user" code/infra   # before refresh: ff targets the canonical upstream same-pass
      refresh_user_clone   "$os_user" code/infra
      IFS=',' read -ra extra_repos <<< "$repos_csv"
      for repo in "${extra_repos[@]}"; do
        [[ -n "$repo" ]] || continue
        hoist_nested_repo  "$os_user" "$repo"
        install_user_repo  "$os_user" "$repo"
        refresh_user_clone "$os_user" "code/$repo"
      done
    else
      install_locked_clone "$os_user" code
      wire_forgejo_remote  "$os_user" code         # before refresh: ff targets the canonical upstream same-pass
      refresh_user_clone   "$os_user" code
    fi
    install_user_kubeconfig "$os_user"
    deploy_user_launcher "$os_user"          # keep ~/start-claude.sh current (skel only seeds new accounts)
  fi
  refresh_codex_mirror "$os_user"            # all tiers — mirror of the managed claudeMd
  install_user_claude_native "$os_user"      # all tiers — per-user native claude (terminal + t3); no npm/npx
  install_claude_auth_sync "$os_user"        # all tiers — own Claude identity + isolated Vault recovery
done < <(jq -r '.accounts[] | [.os_user, .tier, .shell, (if (.groups|length)==0 then "-" else (.groups|join(",")) end), .code_layout, (if (.repos|length)==0 then "-" else (.repos|join(",")) end)] | @tsv' "$desired_file")

# 5) per-user .env (sticky port) + enable t3-serve@
while IFS=$'\t' read -r os_user port; do
  envf="$ENVDIR/$os_user.env"
  env_set "$envf" T3_PORT "$port"
  # Per-user Enterprise login is authoritative. A legacy shared setup-token has
  # higher credential precedence and would silently defeat user isolation.
  env_unset "$envf" CLAUDE_CODE_OAUTH_TOKEN
  id "$os_user" >/dev/null 2>&1 && run systemctl enable --now "t3-serve@$os_user.service" >/dev/null 2>&1 || true
done < <(jq -r '.ports | to_entries[] | [.key, .value] | @tsv' "$desired_file")

# 5c) per-user playwright-mcp (ALL tiers incl. admin): write the sticky
#     PLAYWRIGHT_PORT to the per-user playwright env, then seed token + wire
#     ~/.claude.json + enable the system template instances. if-absent /
#     idempotent — never disturbs a live user's running server or existing config.
while IFS=$'\t' read -r os_user pw_port; do
  id "$os_user" >/dev/null 2>&1 || continue
  env_set "$ENVDIR/playwright-$os_user.env" PLAYWRIGHT_PORT "$pw_port"
  install_playwright "$os_user"
done < <(jq -r '.playwright_ports | to_entries[] | [.key, .value] | @tsv' "$desired_file")

# 5d) per-user homelab-memory (ALL users): replace the claude-memory MCP/plugin with the
#     homelab CLI memory hooks. Idempotent + additive + if-absent; never touches the
#     per-user MEMORY_API_KEY or other MCP servers (removes ONLY claude_memory).
while IFS=$'\t' read -r os_user; do
  id "$os_user" >/dev/null 2>&1 || continue
  install_memory "$os_user"
done < <(jq -r '.accounts[].os_user' "$desired_file")

# 5b) machine-wide (once, not per-user): keep the t3 gated nightly TRACKER timer enabled (it
#     follows t3@nightly daily, gated; see t3-autoupdate.sh / docs/runbooks/t3-version-bump.md).
#     NEVER --now: the tracker installs a NEW build + migrates DBs + restarts serves, so firing
#     a missed run mid-day with users active is exactly the 2026-06-09 shape. `enable` (no --now)
#     just arms the 04:00 schedule (the timer also dropped Persistent=true so a boot can't fire a
#     missed bump). Fresh boxes get t3 from setup-devvm.sh's nightly install, not here.
run systemctl enable t3-autoupdate.timer >/dev/null 2>&1 || true
#     tmux session persistence: periodic snapshot + boot-time restore (reboot
#     survival for users' named claude sessions). Safe to --now: save is a
#     read-only snapshot; restore is per-session idempotent.
run systemctl enable --now tmux-persist-save.timer >/dev/null 2>&1 || true
run systemctl enable tmux-persist-restore.service >/dev/null 2>&1 || true

# 6) regenerate /etc/ttyd-user-map + dispatch.json from the desired state (SSoT:
#    a roster entry removed here DISAPPEARS, which is what the offboarding cut relies on)
if [[ "$DRY_RUN" == 1 ]]; then
  log "[dry-run] would regenerate $MAP + $ENVDIR/dispatch.json"
else
  jq -r '.ttyd_user_map' "$desired_file" > "$MAP.tmp" && install -m 0644 "$MAP.tmp" "$MAP" && rm -f "$MAP.tmp"
  jq -c '.dispatch' "$desired_file" > "$ENVDIR/dispatch.json.tmp" && install -m 0644 "$ENVDIR/dispatch.json.tmp" "$ENVDIR/dispatch.json" && rm -f "$ENVDIR/dispatch.json.tmp"
fi

log "reconcile complete ($([[ "$DRY_RUN" == 1 ]] && echo DRY-RUN || echo applied))"
