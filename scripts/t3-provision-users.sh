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
# The browser-bridge server, for the per-user CLI token in 5d-quater. The
# public host rather than the in-cluster Service: the devvm is outside the
# cluster and the provisioning route carries a bearer, so it stays off the
# forward-auth router and survives the edge.
BB_BASE_URL="${BB_BASE_URL:-https://browser-bridge.viktorbarzin.me}"
# Who administers this box, one OS user per line, derived from roster.yaml's
# tier: admin. Read by terminal-lobby's act-as switch, which lets an admin work
# as another mapped user. Authentik groups cannot answer this — every devvm user
# is in "Home Server Admins", which is what gets them to the lobby host at all.
ADMINS=/etc/ttyd-admins
# The grant letting the service user become each other mapped user. Derived here
# since 2026-08-29; it was hand-maintained before, which meant it had no
# offboarding — a removed roster row left the grant behind. It is also the file
# that must never be installed unvalidated: a malformed one breaks sudo for
# everybody, so it goes through visudo on a temp path first.
TTYD_SUDOERS=/etc/sudoers.d/ttyd-users
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
# Per-user agent instructions (docs/agents/users/<user>/AGENTS.md), one file per
# person since 2026-09-22. They live in wizard's PRIVATE monorepo, not in this
# repo: a user's file may carry internal detail and this repo's GitHub mirror is
# public. Same reason ADMIN_KUBECONFIG points outside the repo. Step 0a reads
# them from the monorepo's origin/master, never from a working tree.
AGENTS_REPO="${AGENTS_REPO:-/home/wizard/code}"
AGENTS_USERS_PATH="docs/agents/users"

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
  [[ "$(runuser -u "$user" -- git -C "$dir" symbolic-ref --short -q HEAD)" == master ]] \
    || { log "refresh skipped for $user:$sub (not on master)"; return 0; }
  # Untracked files never block a fast-forward that doesn't touch them, and
  # .beads/metadata.json is rewritten by install_beads (5d) on every run, so
  # neither counts as a local change. Counting them froze emo's clone from
  # 2026-06-13 (75 untracked screenshots and notes) until 2026-09-22, and nothing
  # logged why. An ff that would overwrite either still refuses, below.
  if [[ -n "$(runuser -u "$user" -- git -C "$dir" status --porcelain --untracked-files=no -- . ':(exclude).beads/metadata.json')" ]]; then
    log "refresh skipped for $user:$sub (uncommitted changes to tracked files)"; return 0
  fi
  runuser -u "$user" -- git -C "$dir" rev-parse --verify -q 'master@{upstream}' >/dev/null \
    || { log "refresh skipped for $user:$sub (no upstream)"; return 0; }
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
  # MANAGED_SRC is origin/master's copy when step 0a could fetch one, and the
  # working tree otherwise — set there, defaulted here so this stays callable
  # on its own.
  local src="${MANAGED_SRC:-$WORKSTATION_DIR/managed-settings.json}" dst=/etc/claude-code/managed-settings.json
  [[ -r "$src" ]] || return 0
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$src" 2>/dev/null \
    || { log "WARN: $src is invalid JSON — managed-config sync skipped"; return 0; }
  cmp -s "$src" "$dst" 2>/dev/null && return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] managed-settings.json -> $dst"; return 0; fi
  install -D -m 0644 "$src" "$dst"
  log "deployed managed-settings.json -> /etc/claude-code (repo copy changed)"
}

# tmux-persist (web-terminal session save/restore) is authored in-repo and its
# units exec /usr/local/bin/tmux-persist. Keep the deployed binary current from the
# repo each reconcile — same rationale as sync_managed_config: it was previously only
# ever installed by a manual setup-devvm.sh run, so a committed edit could sit
# undeployed. bash -n gates a broken script; cmp avoids needless churn.
sync_tmux_persist() {
  local src="$WORKSTATION_DIR/../tmux-persist.sh" dst=/usr/local/bin/tmux-persist
  [[ -r "$src" ]] || return 0
  bash -n "$src" 2>/dev/null || { log "WARN: $src has a syntax error — tmux-persist sync skipped"; return 0; }
  cmp -s "$src" "$dst" 2>/dev/null && return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] tmux-persist -> $dst"; return 0; fi
  install -m 0755 "$src" "$dst"
  log "deployed tmux-persist -> /usr/local/bin (repo copy changed)"
}

# The org policy for Codex, machine-wide. Codex has no managed CLAUDE.md, but its
# root-owned requirements.toml (the enforced layer) takes
# additional_developer_instructions, so the same committed claudeMd text reaches
# both harnesses. Replaced refresh_codex_mirror on 2026-09-22: that copied the
# policy into every user's ~/.codex/AGENTS.md, the file each user's own
# instructions occupy now. Rewritten only when the text changes.
sync_codex_requirements() {
  local dst=/etc/codex/requirements.toml tmp
  tmp="$(mktemp)"
  if ! python3 - "$MANAGED_SRC" > "$tmp" 2>/dev/null <<'PY'
import json, sys, tomllib
text = json.load(open(sys.argv[1]))["claudeMd"].rstrip("\n")
if "'''" in text:
    sys.exit(1)  # cannot be a TOML literal string; keep the deployed file
out = ("# Deployed by t3-provision-users from infra scripts/workstation/managed-settings.json\n"
       "# (claudeMd), so Codex reads the same org policy as Claude Code. Edits here are\n"
       "# overwritten within the hour; change the repo copy instead.\n"
       "additional_developer_instructions = '''\n" + text + "\n'''\n")
tomllib.loads(out)  # never install a file Codex would fail to parse
sys.stdout.write(out)
PY
  then rm -f "$tmp"; log "WARN: codex requirements not generated from $MANAGED_SRC"; return 0; fi
  if cmp -s "$tmp" "$dst" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] codex org policy -> $dst"; rm -f "$tmp"; return 0; fi
  # A file Codex cannot parse makes it exit for every user, so the new copy is
  # staged next to the old one and renamed into place in one step.
  install -d -m 0755 /etc/codex && install -m 0644 "$tmp" "$dst.new" && mv -f "$dst.new" "$dst" \
    && log "deployed codex org policy -> $dst"
  rm -f "$tmp" "$dst.new"
  return 0
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

# Hands-off chrome-service browser credential. For a user who has a
# `<os_user>-browser` ServiceAccount in the chrome-service namespace (created in
# stacks/chrome-service/rbac.tf), install a DUAL-CONTEXT kubeconfig whose DEFAULT
# context authenticates with that SA's long-lived token — so `homelab browser`
# (which shells out to `kubectl port-forward -n chrome-service`) works
# non-interactively, even from a headless agent session (the user's interactive
# OIDC login can't authenticate a headless kubectl). The user's personal OIDC
# identity is retained as the `oidc@homelab` named context
# (`kubectl --context oidc@homelab`). TF (the SA's existence) is the source of
# truth for WHO gets this — there is no roster flag. Idempotent (cmp-guarded; SA
# tokens are stable) + best-effort (cluster/secret unreachable -> WARN, never aborts).
install_browser_kubeconfig() {
  local user="$1" home kc sa secret token server ca tmp
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -z "$home" ]] && return 0
  sa="${user}-browser"
  secret="${sa}-token"
  [[ -r "$ADMIN_KUBECONFIG" ]] || return 0
  # Gate: only users with a chrome-service browser SA (TF-driven). Best-effort read.
  KUBECONFIG="$ADMIN_KUBECONFIG" kubectl --request-timeout=10s -n chrome-service get serviceaccount "$sa" >/dev/null 2>&1 || return 0
  token="$(KUBECONFIG="$ADMIN_KUBECONFIG" kubectl --request-timeout=10s -n chrome-service get secret "$secret" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [[ -n "$token" ]] || { log "WARN: browser SA token not ready for $user (secret chrome-service/$secret) — skipped"; return 0; }
  server="$(KUBECONFIG="$ADMIN_KUBECONFIG" kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
  ca="$(KUBECONFIG="$ADMIN_KUBECONFIG" kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  [[ -n "$server" && -n "$ca" ]] || { log "WARN: could not read cluster server/CA -> skip browser kubeconfig for $user"; return 0; }
  kc="$home/.kube/config"
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: homelab
  cluster:
    server: $server
    certificate-authority-data: $ca
contexts:
- name: ${sa}@homelab
  context:
    cluster: homelab
    user: $sa
- name: oidc@homelab
  context:
    cluster: homelab
    user: oidc
current-context: ${sa}@homelab
users:
- name: $sa
  user:
    token: $token
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
  if cmp -s "$tmp" "$kc" 2>/dev/null; then rm -f "$tmp"; return 0; fi   # already current -> no churn
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] dual-context (SA default + OIDC) browser kubeconfig -> $user:$kc"; rm -f "$tmp"; return 0; fi
  install -d -o "$user" -g "$user" -m 0700 "$home/.kube"
  install -o "$user" -g "$user" -m 0600 "$tmp" "$kc" || { log "WARN: failed to write browser kubeconfig for $user"; rm -f "$tmp"; return 0; }
  rm -f "$tmp"
  log "wrote dual-context browser kubeconfig (SA default + OIDC) -> $user:~/.kube/config"
  return 0
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
  local user="$1" want="${2:-true}" home cfg token_file token policy
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -z "$home" ]] && return 0

  # roster.yaml `claude_auth: false` — the user has an account here but does
  # not use Claude on this box. The timer validates a credential that was
  # never created, so it fails every ~6h forever and raises
  # WorkstationClaudeAuthInvalid with nothing anyone can fix (ancamilea,
  # 2026-08-16: alerting since 2026-08-10). DISABLE rather than skip: this
  # reconcile runs hourly against users who may already have it enabled, so a
  # bare `return` would leave a previously-enabled timer running forever.
  # Nothing else is touched — account, clone, t3-serve, Vault token and policy
  # all stay, so flipping the flag back to true re-enables on the next pass.
  if [[ "$want" != "true" ]]; then
    run systemctl disable --now "claude-auth-sync@$user.timer" >/dev/null 2>&1 || true
    run systemctl reset-failed "claude-auth-sync@$user.service" >/dev/null 2>&1 || true
    log "claude-auth-sync DISABLED for $user (roster claude_auth: false)"
    return 0
  fi
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

  # (3) retire the hand-made `systemd --user` units the template unit replaced.
  #     Enabling the system instance is NOT enough on a box that predates it:
  #     the old user unit keeps running with its own HARDCODED --port, the new
  #     one cannot bind, and it crash-loops on EADDRINUSE forever. Found
  #     2026-08-14 with all three users broken and 184k-187k restarts each,
  #     wizard's and ancamilea's ports cross-wired (each holding the other's).
  #     The unit file is renamed rather than deleted so the retirement is
  #     visible and reversible.
  retire_legacy_playwright_units "$user"

  # (4) enable the system template instances. `enable --now` is idempotent and
  #     does NOT restart a running unit, so a live user is undisturbed.
  if [[ "${2:-false}" == "true" ]]; then
    # roster `parked: true` — stop the per-user browser MCP rather than skip it,
    # for the same reason as claude-auth-sync: this reconcile also runs against
    # users who already have it enabled, so a bare skip leaves it running.
    run systemctl disable --now "playwright-mcp@$user.service" >/dev/null 2>&1 || true
    run systemctl disable --now "playwright-snapshot-refresh@$user.timer" >/dev/null 2>&1 || true
    run systemctl reset-failed "playwright-mcp@$user.service" >/dev/null 2>&1 || true
    run systemctl reset-failed "playwright-snapshot-refresh@$user.service" >/dev/null 2>&1 || true
    log "playwright MCP DISABLED for $user (roster parked: true)"
    return 0
  fi
  run systemctl enable --now "playwright-mcp@$user.service" >/dev/null 2>&1 || true
  run systemctl enable --now "playwright-snapshot-refresh@$user.timer" >/dev/null 2>&1 || true
}

# Stop + disable + rename the pre-template per-user playwright units, if present.
# Idempotent: a user who never had them, or was already migrated, is a no-op.
retire_legacy_playwright_units() {
  local user="$1" home uid unit f
  home="$(getent passwd "$user" | cut -d: -f6)" || return 0
  uid="$(id -u "$user" 2>/dev/null)" || return 0
  for unit in playwright-mcp.service playwright-snapshot-refresh.timer playwright-snapshot-refresh.service; do
    f="$home/.config/systemd/user/$unit"
    [[ -f "$f" ]] || continue
    if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] retire legacy $unit -> $user"; continue; fi
    runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" \
      systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
    mv "$f" "$f.superseded-by-system-unit"
    log "retired legacy user unit $unit for $user (superseded by the system template)"
  done
}

# Per-user homelab-memory setup — migrate off the claude-memory MCP/plugin to the
# homelab CLI hooks (auto-recall + auto-learn + compaction backup/recovery).
# Idempotent, if-absent, ADDITIVE: never clobbers `env` (the per-user
# MEMORY_API_KEY) or other MCP servers; removes ONLY the `claude_memory` MCP.
# Reuses the user's existing key — does NOT mint one (per-user isolation stays
# deferred, design 2026-06-08). The homelab CLI (/usr/local/bin/homelab) hits the
# same remote HTTP API the MCP used. Hook scripts: $WORKSTATION_DIR/claude-hooks.
# --- shared beads task DB (all users) ---------------------------------------
# `bd` in a user's ~/code needs .beads/metadata.json pointing at the SHARED
# Dolt server, carrying the shared project's identity. Left to itself, `bd`
# self-initialises a NEW project on a local port, and that config can never
# reach the team's issues.
#
# Found on emo 2026-09-02 (infra#31, PRD task 2.3): his metadata read
# host=127.0.0.1 port=23209 database="in" with its own project_id, so `bd list`
# died with "Dolt server unreachable ... auto-start is suppressed". Repointing
# it at the shared server then failed a second, better check — PROJECT IDENTITY
# MISMATCH — because a locally-initialised project_id cannot open a database
# belonging to another project. Both have to match, which is why this writes
# the identity too and not just the address.
#
# The shared facts are read from the ADMIN's metadata rather than hardcoded, so
# a future server move or re-init needs no edit here. If the admin's file is
# missing this is skipped with a warning rather than guessing.
install_beads() {
  local user="$1" home admin_meta user_meta
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home/code" ]] || return 0
  admin_meta="/home/wizard/code/.beads/metadata.json"
  user_meta="$home/code/.beads/metadata.json"
  [[ -r "$admin_meta" ]] || { log "WARN: no admin beads metadata -> skip beads for $user"; return 0; }
  [[ "$user" == "wizard" ]] && return 0
  [[ -f "$user_meta" ]] || return 0   # no .beads in their workspace: nothing to point

  if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry-run] point $user's beads at the shared Dolt server + project identity"
    return 0
  fi

  # Rewrite only the server + identity keys; everything else in their metadata
  # is theirs to keep. Idempotent: a correct file is left byte-identical.
  python3 - "$admin_meta" "$user_meta" <<'PYEOF' || { log "WARN: beads metadata rewrite failed for $user"; return 0; }
import json, sys
admin, target = sys.argv[1], sys.argv[2]
a = json.load(open(admin))
t = json.load(open(target))
keys = ("dolt_mode", "dolt_server_host", "dolt_server_port",
        "dolt_server_user", "dolt_database", "project_id")
before = {k: t.get(k) for k in keys}
for k in keys:
    if k in a:
        t[k] = a[k]
if {k: t.get(k) for k in keys} != before:
    json.dump(t, open(target, "w"), indent=2)
    print("changed")
PYEOF
  chown "$user":"$user" "$user_meta" 2>/dev/null || true
  chmod 700 "$home/code/.beads" 2>/dev/null || true
  # bd refuses to write without a role. contributor, not maintainer: a
  # non-admin should not be closing other people's issues by default.
  runuser -u "$user" -- bash -lc 'cd ~/code 2>/dev/null && git config beads.role >/dev/null 2>&1 || git config beads.role contributor' 2>/dev/null || true
  log "beads pointed at the shared Dolt server -> $user"
}

# Per-user browser-bridge CLI token -> ~/.config/browser-bridge/token, 0600.
#
# Every one of the 30 `homelab browser bridge` commands reads that file before
# it touches the network, so without it the whole verb exits 2 with "no
# browser-bridge token at ...". Nothing wrote it: the server's only minting
# route was POST /v1/admin/tokens, which sits behind Authentik forward-auth,
# and the outpost answers a request with no SSO cookie with a 302 to a login
# page. A script on this box has no cookie and cannot get one, so the only way
# to mint a token was a human hand-crafting a curl out of their own browser
# session.
#
# POST /v1/provision/tokens is the machine half. One bearer, from Vault, on
# the router that runs no forward-auth.
#
# The minted token is written BACK to Vault under
# secret/browser-bridge/tokens, keyed by OS user, because the server returns
# it once and never again: without that copy a rebuilt devvm would mint a
# second token per user and leave the first live in Redis forever.
#
# Best-effort throughout. browser-bridge is one service among many and a
# server that is down, unreachable or not yet deployed must not stop the
# hourly reconcile.
install_browser_bridge_token() {
  local user="$1" home dir dst authentik_user
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0
  dir="$home/.config/browser-bridge"
  dst="$dir/token"

  # Already provisioned. The file is the contract; nothing re-mints over it.
  [[ -s "$dst" ]] && return 0

  authentik_user="$2"
  [[ -n "$authentik_user" && "$authentik_user" != "-" ]] || {
    log "WARN: no authentik_user for $user -> skip browser-bridge token"; return 0; }

  if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry-run] mint + install browser-bridge CLI token -> $dst"
    return 0
  fi

  local token=""
  # 1) A token this box (or its predecessor) already minted for this user.
  token="$(vault kv get -field="$user" secret/browser-bridge/tokens 2>/dev/null || true)"

  # 2) Otherwise mint one, and keep the copy.
  if [[ -z "$token" ]]; then
    local provision_token
    provision_token="$(vault kv get -field=provision_token secret/browser-bridge 2>/dev/null || true)"
    [[ -n "$provision_token" ]] || {
      log "WARN: secret/browser-bridge has no provision_token -> no browser-bridge token for $user"; return 0; }

    local body
    body="$(curl -fsS --max-time 15 \
      -H "Authorization: Bearer $provision_token" \
      -H 'Content-Type: application/json' \
      -X POST "$BB_BASE_URL/v1/provision/tokens" \
      -d "$(jq -cn --arg o "$user" --arg a "$authentik_user" '{osUser:$o,authentikUser:$a}')" 2>/dev/null || true)"
    token="$(printf '%s' "$body" | jq -r '.token // empty' 2>/dev/null || true)"
    [[ -n "$token" ]] || {
      log "WARN: browser-bridge did not mint a token for $user (server down, or not deployed yet) -- retries next reconcile"
      return 0; }

    # patch, never put: the path is one secret holding every user's token.
    vault kv patch "secret/browser-bridge/tokens" "$user=$token" >/dev/null 2>&1 \
      || vault kv put "secret/browser-bridge/tokens" "$user=$token" >/dev/null 2>&1 \
      || log "WARN: minted a browser-bridge token for $user but could not store it in Vault"
  fi

  install -d -o "$user" -g "$user" -m 0700 "$dir"
  # umask, not a chmod afterwards: the token must never exist world-readable,
  # not even for the instant between the write and the mode change.
  ( umask 077 && printf '%s\n' "$token" > "$dst" )
  chown "$user":"$user" "$dst"
  chmod 600 "$dst"
  log "browser-bridge CLI token installed -> $user"
  return 0  # best-effort tail must never return non-zero under set -euo pipefail
}

install_memory() {
  local user="$1" home
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0
  local src="$WORKSTATION_DIR/claude-hooks" hooks_dst="$home/.claude/hooks" settings="$home/.claude/settings.json"
  [[ -d "$src" ]] || { log "WARN: $src missing -> skip memory setup for $user"; return 0; }

  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] memory: hooks + settings wire + claude_memory MCP removal -> $user"; return 0; fi

  # (1) (re)install the hook scripts, owned by the user (refreshed each reconcile so fixes land)
  install -d -o "$user" -g "$user" -m 0755 "$hooks_dst"
  local h
  for h in homelab-memory-recall.py auto-learn.py pre-compact-backup.sh post-compact-recovery.sh zsh-guard.py fixer-suggest.py unslop-check.py; do
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
  [[ -f "$settings" ]] && chmod 600 "$settings" || true

  # (2b) reuse the user's existing key; warn (do NOT mint — needs an admin vault write) if absent.
  if [[ -f "$settings" ]] && ! grep -q 'MEMORY_API_KEY' "$settings"; then
    log "WARN: $user has no MEMORY_API_KEY in settings.json — homelab memory no-ops until an admin mints one"
  fi

  # (3) remove the now-superseded claude_memory MCP (AS the user, if-present) + the plugin dir.
  if runuser -u "$user" -- bash -lc 'command -v claude >/dev/null 2>&1 && claude mcp get claude_memory >/dev/null 2>&1'; then
    runuser -u "$user" -- bash -lc 'claude mcp remove claude_memory >/dev/null 2>&1' && log "removed claude_memory MCP -> $user" || true
  fi
  if [[ -d "$home/.claude/plugins/claude-memory" ]]; then
    rm -rf "$home/.claude/plugins/claude-memory" && log "removed claude-memory plugin dir -> $user"
  fi
  return 0  # best-effort tail must never return non-zero, else set -euo pipefail aborts the whole reconcile
}

# Each user's own agent instructions -> ~/.agents/AGENTS.md, linked from both
# harnesses: ~/.claude/CLAUDE.md (Claude Code) and ~/.codex/AGENTS.md (Codex).
# Replaced install_shared_rules on 2026-09-22, when one shared set copied into
# every home gave way to one file per person (docs/agents/users/README.md in the
# monorepo). Only users with a file there are touched; wizard's comes from his
# dotfiles and is left alone.
#
# Every write into the home runs AS THE USER (runuser), never as root, so a
# symlink the user planted cannot turn this into a root write elsewhere: the
# /etc/skel case found 2026-09-22 was exactly that, `install -d -o <user>`
# following a link into another user's home.
#
# 99-personal.md is created once and NEVER overwritten — it is the per-user slot
# for what the person adds themselves. Claude Code reads it; Codex does not,
# since Codex loads a single global file.
# Best-effort tail: must return 0 or set -euo pipefail aborts the whole reconcile.
install_user_agents() {
  local user="$1" home src hub personal f
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0
  src="$AGENTS_SRC_DIR/$user.md"
  [[ -s "$src" ]] || return 0
  hub="$home/.agents/AGENTS.md"
  for f in "$home/.agents" "$home/.claude" "$home/.claude/rules"; do
    # A link here would aim every write below somewhere else (the /etc/skel
    # links pointed .claude/rules into the admin's home). Refuse rather than follow.
    [[ -L "$f" ]] && { log "WARN: $f is a symlink -> agent instructions for $user skipped"; return 0; }
  done
  if [[ "$DRY_RUN" == 1 ]]; then
    cmp -s "$src" "$hub" 2>/dev/null || echo "[dry-run] agent instructions -> $user"
    return 0
  fi
  runuser -u "$user" -- mkdir -p "$home/.agents" "$home/.claude/rules" || return 0
  if ! cmp -s "$src" "$hub" 2>/dev/null; then
    # root opens the source (its directory is 0700), the user writes the file,
    # and the rename makes a session starting mid-copy see the old or new text.
    # Read-only for the user, so an agent editing it fails loudly instead of
    # having its edit reverted within the hour; the first line points at
    # 99-personal.md.
    if runuser -u "$user" -- sh -c 'cat > "$1.tmp" && chmod 0444 "$1.tmp" && mv -f "$1.tmp" "$1"' _ "$hub" < "$src"; then
      log "agent instructions -> $user (source changed)"
    else
      log "WARN: could not write $hub"; return 0
    fi
  fi
  link_agents_file "$user" "$home/.claude/CLAUDE.md"
  [[ -d "$home/.codex" ]] && link_agents_file "$user" "$home/.codex/AGENTS.md"

  personal="$home/.claude/rules/99-personal.md"
  if [[ ! -e "$personal" && ! -L "$personal" ]]; then
    runuser -u "$user" -- sh -c 'cat > "$1"' _ "$personal" <<'PERSONAL' && log "created personal rules slot for $user"
# Personal notes — yours alone

The provisioner never writes this file, so anything here survives every
reconcile. Your main instructions (~/.agents/AGENTS.md) are written for you
and WILL be overwritten, so put what you want to keep here.
PERSONAL
  fi

  # The shared rules (2026-08-15 to 2026-09-22) retire once this user's own
  # file is provably what Claude Code loads, or the same rules load twice.
  # "Provably": ~/.claude/CLAUDE.md resolves to the hub and the hub matches the
  # source. Retiring on the hub merely existing would leave a user with no rules
  # at all if the link step had failed. (wizard's were retired by hand when his
  # dotfiles took over; nothing re-creates them.)
  [[ "$(readlink -f "$home/.claude/CLAUDE.md")" == "$(readlink -f "$hub")" ]] && cmp -s "$src" "$hub" || return 0
  [[ ! -L "$home/.claude/rules" && "$(readlink -f "$home/.claude/rules")" == "$home/.claude/rules" ]] || return 0
  for f in 10-homelab 20-execution 30-planning 40-style; do
    [[ -f "$home/.claude/rules/$f.md" && ! -L "$home/.claude/rules/$f.md" ]] || continue
    runuser -u "$user" -- rm -f "$home/.claude/rules/$f.md" && log "retired shared rule $f.md -> $user"
  done
  return 0
}

# link_agents_file <user> <path>: make <path> a symlink to ../.agents/AGENTS.md,
# as the user. A regular file there is the old hand-edited CLAUDE.md or the old
# Codex mirror; its content now lives in the monorepo, and it is kept beside the
# link as <path>.pre-agents-md.
link_agents_file() {
  local user="$1" path="$2" want="../.agents/AGENTS.md"
  [[ -L "$path" && "$(readlink "$path")" == "$want" ]] && return 0
  if [[ -e "$path" && ! -L "$path" ]]; then
    runuser -u "$user" -- mv -f "$path" "$path.pre-agents-md" || { log "WARN: could not move $path aside"; return 0; }
  fi
  if runuser -u "$user" -- ln -sfn "$want" "$path"; then log "linked $path -> $want"
  else log "WARN: could not link $path for $user"; fi
  return 0
}

# Claude settings every user should START on, written ONCE per key.
#
# Today that is one key: fastMode. Fast mode runs Opus 5 / Opus 4.8 at up to
# 2.5x the output speed for 2x the per-token price ($10/$50 per MTok against
# $5/$25), billed from the org's usage credits rather than the plan allowance,
# so it is a deliberate spend Viktor asked for on 2026-09-12 — for both users,
# not just whoever happened to type /fast. It only reaches a session at process
# start, and only an Opus model honours it; picking Sonnet or Haiku turns it off
# by itself.
#
# IF-ABSENT, and that is the whole design. `/fast` writes this same key, so a
# reconcile that set it every hour would quietly undo a user who turned fast
# mode off and hand them the bill. Present, at any value, means the user has an
# opinion and we leave it alone. Same contract as the 99-personal.md slot above.
#
# Best-effort tail: must return 0 or set -euo pipefail aborts the whole reconcile.
install_claude_defaults() {
  local user="$1" home settings added
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home/.claude" ]] || return 0
  settings="$home/.claude/settings.json"
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] claude defaults (fastMode) -> $user"; return 0; fi

  # Runs as ROOT, like the memory wiring, then hands the file back: it holds the
  # per-user MEMORY_API_KEY and must stay 0600 and user-owned.
  added="$(python3 - "$settings" <<'PYEOF'
import json, os, sys

path = sys.argv[1]
DEFAULTS = {"fastMode": True}

if os.path.exists(path) and os.path.getsize(path) > 0:
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (json.JSONDecodeError, OSError) as e:
        print(f"ERROR: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(1)
else:
    data = {}

missing = {k: v for k, v in DEFAULTS.items() if k not in data}
if missing:
    data.update(missing)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
    print(" ".join(sorted(missing)))
PYEOF
  )" || { log "WARN: claude defaults failed for $user (retries next reconcile)"; return 0; }

  chown "$user:$user" "$settings" 2>/dev/null || true
  chmod 600 "$settings" 2>/dev/null || true
  [[ -n "$added" ]] && log "claude default set -> $user ($added)"
  return 0
}

[[ $EUID -eq 0 ]] || { echo "t3-provision-users: must run as root" >&2; exit 1; }
for bin in python3 jq; do command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }; done
[[ -f "$ROSTER" && -f "$ENGINE" ]] || { echo "roster/engine not under $WORKSTATION_DIR" >&2; exit 1; }

# 0a) run what is COMMITTED, not what happens to be in a working tree.
#
# $WORKSTATION_DIR is the admin's own checkout. refresh_user_clone runs only for
# tier != admin and bails on any dirty tree, so a pushed change to the roster, to
# this script, or to the engine reached this box only when someone synced the file
# by hand. With membership driven from Authentik through a CI commit, that gap
# would stop the chain with no error anywhere: CI reports success, the box keeps
# the previous state, and a removed user stays provisioned.
#
# So fetch once, as the checkout's owner (their git credentials, not root's), and
# materialise the three inputs from origin/master. EVERY failure path falls back
# to the working-tree copy — today's behaviour — because a network blip must
# degrade to "slightly stale" rather than to "no users at all". The re-exec flag
# skips the fetch on the second pass, so a self-deploy costs one fetch, not two.
STATEDIR="${STATEDIR:-/var/lib/t3-provision}"
if [[ "$DRY_RUN" != 1 ]]; then install -d -m 0755 "$STATEDIR"; fi
clone_root="$(cd "$WORKSTATION_DIR/../.." && pwd)"
clone_owner="$(stat -c %U "$clone_root" 2>/dev/null || echo root)"
gitc=(-c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false)
committed() {  # committed <repo-path> <dest>; 0 when dest now holds origin/master's copy
  local src="$1" dst="$2"
  runuser -u "$clone_owner" -- git -C "$clone_root" "${gitc[@]}" show "origin/master:$src" > "$dst.tmp" 2>/dev/null \
    && [[ -s "$dst.tmp" ]] && mv "$dst.tmp" "$dst" && return 0
  rm -f "$dst.tmp"; return 1
}
if [[ -z "${T3_PROVISION_SELF_DEPLOYED:-}" ]]; then
  if runuser -u "$clone_owner" -- env GIT_TERMINAL_PROMPT=0 git -C "$clone_root" "${gitc[@]}" \
       fetch --quiet origin master 2>/dev/null; then
    committed scripts/t3-provision-users.sh "$STATEDIR/t3-provision-users.committed.sh" || true
    committed scripts/workstation/roster_engine.py "$STATEDIR/roster_engine.committed.py" || true
    committed scripts/workstation/managed-settings.json "$STATEDIR/managed-settings.committed.json" || true
    if committed scripts/workstation/roster.yaml "$STATEDIR/roster.committed.yaml" &&
       python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])) or {}; sys.exit(0 if d.get("users") else 1)' \
         "$STATEDIR/roster.committed.yaml" 2>/dev/null; then
      cmp -s "$STATEDIR/roster.committed.yaml" "$ROSTER" || log "roster: using origin/master (working tree differs)"
    else
      log "WARN: no usable roster from origin/master — falling back to $ROSTER"
      rm -f "$STATEDIR/roster.committed.yaml"
    fi
  else
    log "WARN: git fetch failed — running from the working tree at $WORKSTATION_DIR"
  fi
fi
# Point the three inputs at whatever we managed to materialise; each falls back
# independently, so a partial failure still runs with the rest committed.
[[ -s "$STATEDIR/roster.committed.yaml" ]] && ROSTER="$STATEDIR/roster.committed.yaml"
[[ -s "$STATEDIR/roster_engine.committed.py" ]] && ENGINE="$STATEDIR/roster_engine.committed.py"
# The org-wide Claude config is an input like the others, and it was the one
# still read from the working tree. On this box that tree carries other people's
# in-flight edits and sits behind origin/master for days at a time, so a landed
# rule or hook change reached the repo and stopped there — which is the same gap
# step 0 closes for this script itself.
MANAGED_SRC="$WORKSTATION_DIR/managed-settings.json"
[[ -s "$STATEDIR/managed-settings.committed.json" ]] && MANAGED_SRC="$STATEDIR/managed-settings.committed.json"

# Each user's agent instructions are an input too, read from the private
# monorepo's origin/master (docs/agents/users/<user>/AGENTS.md) as that clone's
# owner. The shared rules this replaced were copied from a working tree, so a
# landed change sat undeployed until someone pulled. On any failure the last
# good copies in $STATEDIR/agents stay in use, so a network blip leaves everyone
# on the instructions they already have rather than none.
AGENTS_SRC_DIR="$STATEDIR/agents"
materialise_user_agents() {
  local owner names dest u f
  [[ -d "$AGENTS_REPO/.git" ]] || { log "WARN: $AGENTS_REPO is not a git clone -> per-user agent files unchanged"; return 0; }
  owner="$(stat -c %U "$AGENTS_REPO")"
  if ! runuser -u "$owner" -- env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
       git -C "$AGENTS_REPO" fetch --quiet origin master 2>/dev/null; then
    log "WARN: fetch of $AGENTS_REPO failed -> per-user agent files unchanged"; return 0
  fi
  names="$(runuser -u "$owner" -- git -C "$AGENTS_REPO" ls-tree -d --name-only "origin/master:$AGENTS_USERS_PATH" 2>/dev/null)" \
    || { log "WARN: no $AGENTS_USERS_PATH on $AGENTS_REPO origin/master -> per-user agent files unchanged"; return 0; }
  dest="$AGENTS_SRC_DIR"
  if [[ "$DRY_RUN" == 1 ]]; then dest="$(mktemp -d)"; AGENTS_SRC_DIR="$dest"; fi
  install -d -m 0700 "$dest"   # root only: one user's file is not another's to read
  for u in $names; do
    # The first line tells that user's agent this file is managed, so it puts
    # the user's own notes in 99-personal.md instead of editing the hub.
    if { printf '<!-- Installed by the devvm provisioner from %s/%s/AGENTS.md in Viktor'"'"'s monorepo and overwritten within the hour. Keep your own notes in ~/.claude/rules/99-personal.md. -->\n\n' "$AGENTS_USERS_PATH" "$u"
         runuser -u "$owner" -- git -C "$AGENTS_REPO" show "origin/master:$AGENTS_USERS_PATH/$u/AGENTS.md" 2>/dev/null
       } > "$dest/$u.md.tmp" && [[ "$(wc -l < "$dest/$u.md.tmp")" -gt 2 ]]; then
      mv "$dest/$u.md.tmp" "$dest/$u.md"
    else
      rm -f "$dest/$u.md.tmp"
    fi
  done
  # A user whose directory was removed stops being managed: their home keeps
  # the last file it received, and nothing overwrites it afterwards.
  for f in "$dest"/*.md; do
    [[ -e "$f" ]] || continue
    grep -qxF "$(basename "$f" .md)" <<<"$names" || rm -f "$f"
  done
  return 0
}
# Not behind the self-deploy guard: the run that self-deploys re-execs with it
# set, so a guarded call would skip the monorepo on the first run after a landing.
materialise_user_agents

# 0) self-deploy: the repo is the authoring surface (like sync_managed_config /
#    deploy_user_launcher below). Historically nothing else redeployed
#    /usr/local/bin (only the manual setup-devvm.sh did) — so a committed edit
#    silently never reached the hourly run (the homelab-memory rollout sat
#    undeployed for a day); this step + the homelab CLI rebuild in 0b close that.
#    If the repo copy differs, install it and re-exec the fresh binary. Guarded:
#    re-exec flag (no loop), bash -n (never deploy a broken script), DRY_RUN (no
#    mutation), cmp (no churn when unchanged).
SELF_SRC="$WORKSTATION_DIR/../t3-provision-users.sh"
# Prefer origin/master's copy (0a) so landing a change to this script is
# enough to deploy it; the working tree remains the fallback.
[[ -s "$STATEDIR/t3-provision-users.committed.sh" ]] && SELF_SRC="$STATEDIR/t3-provision-users.committed.sh"
SELF_DST=/usr/local/bin/t3-provision-users
if [[ -z "${T3_PROVISION_SELF_DEPLOYED:-}" && -r "$SELF_SRC" ]] && ! cmp -s "$SELF_SRC" "$SELF_DST"; then
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry-run] self-deploy $SELF_DST from repo (changed)"
  elif bash -n "$SELF_SRC" 2>/dev/null; then
    install -m 0755 "$SELF_SRC" "$SELF_DST"
    log "self-deployed $SELF_DST from repo (changed) — re-exec"
    exec env T3_PROVISION_SELF_DEPLOYED=1 "$SELF_DST" "$@"
  else
    log "WARN: repo t3-provision-users.sh fails 'bash -n' — keeping deployed copy"
  fi
fi

# 0b) homelab CLI: rebuild /usr/local/bin/homelab from the repo's cli/ when the
#     deployed binary's stamped version differs from cli/VERSION (or is absent).
#     The memory hooks install_memory refreshes EVERY run (5d) call this binary
#     with current flags/verbs (recall --json, store --link, get) — hooks and
#     CLI must ride the SAME hourly deploy clock or a newer hook degrades
#     against an older binary (auto-learn additionally capability-gates --link
#     for the go-absent/build-failed remainder). Before 0b only a manual
#     setup-devvm.sh run ever rebuilt the binary. Version-compare keeps the
#     hourly run cheap: no go compile unless cli/VERSION moved. -buildvcs=false:
#     root building in the admin-owned clone must not depend on git ownership
#     checks; the version is stamped via -ldflags from cli/VERSION anyway.
build_homelab_cli() {
  local src="$WORKSTATION_DIR/../../cli" dst=/usr/local/bin/homelab
  local semver srchash want have="" tmp
  semver="$(cat "$src/VERSION" 2>/dev/null || true)"
  [[ -n "$semver" ]] || { log "WARN: $src/VERSION unreadable -> skip homelab CLI rebuild"; return 0; }
  # The rebuild trigger is a HASH OF THE SOURCE, not the hand-written VERSION.
  # Gating on VERSION alone meant a code change with an unbumped file silently
  # never reached anyone's PATH -- master looked correct, tests passed, and the
  # box kept running the old binary. That bit us three times on 2026-08-15
  # alone, the last found only when a test agent ran a flag the machine did not
  # have. A content hash cannot be forgotten, so VERSION goes back to being
  # what it should be: a human-facing label, free to lag without breaking
  # deployment.
  #
  # The hash covers the EMBEDDED ASSETS too, not just the Go sources. Half the
  # binary's behaviour is //go:embed content -- browser_runner.js,
  # browser_stealth.js, the two message_*.js, and the whole ios_assets tree --
  # and hashing only *.go reproduced the exact bug this comment describes, one
  # file type over. Measured 2026-09-19: appending a line to browser_runner.js
  # left the hash at 9c21f82614a1, so the browser fix for infra #98 would have
  # sat on master and never reached a single PATH. The rule is now the honest
  # one: if it goes into the binary, it goes into the hash.
  #
  # bridge/ is in the find for the same reason: it is a nested Go module the
  # `browser bridge` verb is compiled against (cli/bridge/README.md says why it
  # is vendored), and `cat "$src"/*.go` does not recurse into it.
  srchash="$( { cat "$src"/*.go "$src"/*.js "$src"/go.mod "$src"/go.sum 2>/dev/null
                find "$src/ios_assets" "$src/bridge" -type f -print0 2>/dev/null | sort -z | xargs -0 cat 2>/dev/null
              } | sha256sum | cut -c1-12 )"
  [[ -n "$srchash" ]] || { log "WARN: cannot hash $src -> skip homelab CLI rebuild"; return 0; }
  want="${semver}+${srchash}"
  [[ -x "$dst" ]] && have="$("$dst" --version 2>/dev/null | awk '{print $2}')" || true
  [[ "$have" == "$want" ]] && return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] rebuild homelab CLI (${have:-absent} -> $want)"; return 0; fi
  if ! command -v go >/dev/null; then
    log "WARN: go absent -> cannot rebuild homelab CLI (${have:-absent} -> $want); memory hooks degrade until setup-devvm runs"
    return 0
  fi
  tmp="$(mktemp /usr/local/bin/.homelab.XXXXXX)" || { log "WARN: mktemp failed -> skip homelab CLI rebuild"; return 0; }
  # build to a same-fs temp then rename: a mid-flight caller never sees a torn binary
  # Build entirely off /tmp and off $HOME. Both bite here (found 2026-08-16):
  #   * /tmp is a 2 GB tmpfs SHARED BY EVERY USER on this box, and it sat at 99%
  #     full -- go writes its work tree there, so every rebuild died with
  #     "no space left on device" while the root filesystem had 29 GB free. The
  #     script swallows build output, so this surfaced only as the generic
  #     "build failed" warning and the box quietly kept an old binary for a day.
  #   * systemd runs this unit with HOME=[], so an unqualified `go build` cannot
  #     resolve its module/build caches either (`go env GOCACHE` reports "off").
  # Pinning all three to root-owned paths on disk makes the hourly run and a
  # manual run build identically, and immune to whatever else fills /tmp.
  mkdir -p /var/cache/homelab-go/{build,mod,tmp} 2>/dev/null || true
  if (cd "$src" && HOME=/root TMPDIR=/var/cache/homelab-go/tmp \
        GOCACHE=/var/cache/homelab-go/build \
        GOMODCACHE=/var/cache/homelab-go/mod \
        go build -buildvcs=false -ldflags "-X main.version=$want" -o "$tmp" .) \
      && chmod 0755 "$tmp" && mv -f "$tmp" "$dst"; then
    log "homelab CLI rebuilt (${have:-absent} -> $want)"
  else
    rm -f "$tmp"
    log "WARN: homelab CLI build failed (${have:-absent} -> $want); keeping deployed binary"
  fi
  return 0
}
build_homelab_cli

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

# 3b) machine-wide org policy (repo -> /etc), for Claude Code and for Codex
sync_managed_config
sync_codex_requirements
# 3c) machine-wide tmux-persist binary (repo -> /usr/local/bin; units enabled in step 5b)
sync_tmux_persist

# 4) per-account: create-if-absent + ADDITIVE tier groups (never strip) + locked clone
# NB: empty @tsv fields collapse under tab-IFS read (tab is IFS whitespace), so
# the jq below emits "-" for empty groups/repos and we map it back here.
while IFS=$'\t' read -r os_user tier shell groups_csv code_layout repos_csv claude_auth; do
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
    install_browser_kubeconfig "$os_user"    # hands-off chrome-service CLI cred (no-op unless the user has a browser SA)
    deploy_user_launcher "$os_user"          # keep ~/start-claude.sh current (skel only seeds new accounts)
  fi
  install_user_claude_native "$os_user"      # all tiers — per-user native claude (terminal + t3); no npm/npx
  install_claude_auth_sync "$os_user" "$claude_auth"   # all tiers unless roster claude_auth: false
done < <(jq -r '.accounts[] | [.os_user, .tier, .shell, (if (.groups|length)==0 then "-" else (.groups|join(",")) end), .code_layout, (if (.repos|length)==0 then "-" else (.repos|join(",")) end), (.claude_auth|tostring)] | @tsv' "$desired_file")

# 5) per-user .env (sticky port) + enable t3-serve@
while IFS=$'\t' read -r os_user port; do
  envf="$ENVDIR/$os_user.env"
  env_set "$envf" T3_PORT "$port"
  # Per-user Enterprise login is authoritative. A legacy shared setup-token has
  # higher credential precedence and would silently defeat user isolation.
  env_unset "$envf" CLAUDE_CODE_OAUTH_TOKEN
  if [[ "$(jq -r --arg u "$os_user" '.accounts[$u].parked // false' "$desired_file")" == "true" ]]; then
    # roster `parked: true` — the T3 Code server is the largest per-user daemon
    # on this shared box; stop it (not just skip) so an already-running instance
    # actually goes away. The .env, sticky port and state are left alone, so
    # unparking restores the same instance on the same port.
    run systemctl disable --now "t3-serve@$os_user.service" >/dev/null 2>&1 || true
    # `t3 serve` exits 130 (SIGINT) when stopped and the unit does not declare
    # that as success, so a clean stop still lands the unit in `failed` and
    # shows up red in `systemctl --failed`. Clear it; the stop was deliberate.
    run systemctl reset-failed "t3-serve@$os_user.service" >/dev/null 2>&1 || true
    log "t3-serve DISABLED for $os_user (roster parked: true)"
    continue
  fi
  id "$os_user" >/dev/null 2>&1 && run systemctl enable --now "t3-serve@$os_user.service" >/dev/null 2>&1 || true
done < <(jq -r '.ports | to_entries[] | [.key, .value] | @tsv' "$desired_file")

# 5c) per-user playwright-mcp (ALL tiers incl. admin): write the sticky
#     PLAYWRIGHT_PORT to the per-user playwright env, then seed token + wire
#     ~/.claude.json + enable the system template instances. if-absent /
#     idempotent — never disturbs a live user's running server or existing config.
while IFS=$'\t' read -r os_user pw_port; do
  id "$os_user" >/dev/null 2>&1 || continue
  env_set "$ENVDIR/playwright-$os_user.env" PLAYWRIGHT_PORT "$pw_port"
  install_playwright "$os_user" "$(jq -r --arg u "$os_user" '.accounts[$u].parked // false' "$desired_file")"
done < <(jq -r '.playwright_ports | to_entries[] | [.key, .value] | @tsv' "$desired_file")

# 5d) per-user homelab-memory (ALL users): replace the claude-memory MCP/plugin with the
#     homelab CLI memory hooks. Idempotent + additive + if-absent; never touches the
#     per-user MEMORY_API_KEY or other MCP servers (removes ONLY claude_memory).
while IFS=$'\t' read -r os_user; do
  id "$os_user" >/dev/null 2>&1 || continue
  install_memory "$os_user"
  install_beads "$os_user"
done < <(jq -r '.accounts[].os_user' "$desired_file")

# 5d-quater) per-user browser-bridge CLI token (ALL users). Install-if-absent:
#     the file is the contract and nothing re-mints over one that is there.
#     Best effort per user, because the server may not be deployed yet.
while IFS=$'\t' read -r os_user authentik_user; do
  id "$os_user" >/dev/null 2>&1 || continue
  install_browser_bridge_token "$os_user" "$authentik_user"
done < <(jq -r '.accounts[] | [.os_user, (.authentik_user // "-")] | @tsv' "$desired_file")

# 5d-bis) each user's own agent instructions -> ~/.agents/AGENTS.md + the two
#     harness links, for users with a file in the monorepo. Retires the old shared
#     rules in every home that has its own file. Personal slot created once, never rewritten.
while IFS=$'\t' read -r os_user; do
  id "$os_user" >/dev/null 2>&1 || continue
  install_user_agents "$os_user"
done < <(jq -r '.accounts[].os_user' "$desired_file")

# 5d-ter) per-user Claude defaults (ALL users): settings.json keys everyone should
#     start on — currently fastMode. Written once per key, never re-asserted, so a
#     user's own /fast stands. Runs after 5d, which is what creates ~/.claude.
while IFS=$'\t' read -r os_user; do
  id "$os_user" >/dev/null 2>&1 || continue
  install_claude_defaults "$os_user"
done < <(jq -r '.accounts[].os_user' "$desired_file")

# 5e) per-user agent skills: RETIRED 2026-08-19. The reconcile used to vendor a
#     snapshot from scripts/workstation/claude-skills into ~/.agents/skills plus
#     ~/.claude/skills symlinks, install-if-absent and allowlisted to one user via
#     SKILL_USERS. That got a starter set onto the box reliably, and it did two
#     things we now want differently: a copy never refreshed after its first
#     install, and the set was chosen centrally rather than by each person.
#     Distribution is now the lobby's Skills settings group (terminal-lobby
#     ADR-0011, skills-api :7688), where each user sees every other user's skills
#     and installs the ones they want. Existing copies on disk were left exactly
#     as they were, so nobody lost a skill in the switch.

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

# 6) regenerate /etc/ttyd-user-map + /etc/ttyd-admins + the sudo grant +
#    dispatch.json from the
#    desired state (SSoT: a roster entry removed here DISAPPEARS, which is what
#    the offboarding cut relies on — and a demotion from tier: admin drops that
#    user out of $ADMINS on the next reconcile, within the hour)
if [[ "$DRY_RUN" == 1 ]]; then
  log "[dry-run] would regenerate $MAP + $ADMINS + $TTYD_SUDOERS + $ENVDIR/dispatch.json"
else
  jq -r '.ttyd_user_map' "$desired_file" > "$MAP.tmp" && install -m 0644 "$MAP.tmp" "$MAP" && rm -f "$MAP.tmp"
  jq -r '.ttyd_admins' "$desired_file" > "$ADMINS.tmp" && install -m 0644 "$ADMINS.tmp" "$ADMINS" && rm -f "$ADMINS.tmp"
  # The sudo grant, validated before it is installed. visudo -cf on the temp
  # file is the whole safety net: an invalid sudoers file is not a degraded
  # feature, it locks every user out of every sudo call on the box, including
  # the one needed to repair it.
  jq -r '.ttyd_sudoers' "$desired_file" > "$TTYD_SUDOERS.tmp"
  if visudo -cf "$TTYD_SUDOERS.tmp" >/dev/null 2>&1; then
    if ! cmp -s "$TTYD_SUDOERS.tmp" "$TTYD_SUDOERS" 2>/dev/null; then
      log "sudo grant changed; installing $TTYD_SUDOERS"
      diff -u "$TTYD_SUDOERS" "$TTYD_SUDOERS.tmp" 2>/dev/null | grep -E '^[-+]wizard' || true
    fi
    install -m 0440 -o root -g root "$TTYD_SUDOERS.tmp" "$TTYD_SUDOERS"
  else
    log "ERROR: derived sudo grant is malformed; keeping the existing $TTYD_SUDOERS"
    visudo -cf "$TTYD_SUDOERS.tmp" 2>&1 | sed 's/^/  /' || true
  fi
  rm -f "$TTYD_SUDOERS.tmp"
  jq -c '.dispatch' "$desired_file" > "$ENVDIR/dispatch.json.tmp" && install -m 0644 "$ENVDIR/dispatch.json.tmp" "$ENVDIR/dispatch.json" && rm -f "$ENVDIR/dispatch.json.tmp"
fi

# 7) the REVERSIBLE CUT for anyone who left the roster since the last reconcile.
#
# roster_engine.offboard_plan has computed these five actions since the feature
# was designed and nothing has ever applied them, so a removal left half its
# work — the map and dispatch dropped the user (step 6), while their daemons kept
# running and their login stayed open, waiting for someone to remember the
# runbook. This closes that.
#
# The diff is against a SNAPSHOT of the roster this script last applied, so each
# cut fires exactly once, on the transition, rather than every hour forever. No
# snapshot (first run after this shipped) means nothing to compare: record one and
# do nothing, which is also what makes this safe to deploy while people are using
# the box.
#
# unmap_dispatch is already done by step 6. remove_from_t3_group belongs to the
# Authentik side, which is where the removal STARTS now, so there is nothing to
# do here. revoke_cluster_rbac is deliberately not applied: T3 Users means devvm
# access, and someone off this box may still legitimately own a namespace.
# userdel_archive is never applied here, by design.
applied_snapshot="$STATEDIR/roster.applied.yaml"
if [[ -s "$applied_snapshot" ]]; then
  # Through the engine's CLI, like validate/derive — never by importing this
  # module from an inline heredoc: a module executed outside sys.modules cannot
  # resolve its own dataclass annotations, and the first cut of this failed
  # exactly that way. The failure is LOGGED rather than swallowed; a cut that
  # cannot be computed must not read as "nobody left".
  if ! cut_plan="$(python3 "$ENGINE" deprovision --old "$applied_snapshot" --new "$ROSTER")"; then
    log "WARN: could not compute the offboard diff — no cut applied this run"
    cut_plan=""
  fi
  for gone in $cut_plan; do
    # Never cut an account that is not there, and never cut root by a typo.
    id "$gone" >/dev/null 2>&1 || { log "cut: $gone has no account — nothing to do"; continue; }
    [[ "$gone" != "root" ]] || continue
    # Named in the log rather than left to `run`'s echo: every call below sends
    # its output to /dev/null (systemctl is noisy about units that were never
    # enabled), which would take the dry-run echo with it — and a dry run that
    # cannot show what it would do is not worth having.
    cut_units=("t3-serve@$gone.service" "playwright-mcp@$gone.service"
               "playwright-snapshot-refresh@$gone.timer" "claude-auth-sync@$gone.timer"
               "tl-t3-sync@$gone.service")
    log "cut: $gone left the roster — disable ${cut_units[*]}; passwd -l $gone (data untouched)"
    for unit in "${cut_units[@]}"; do
      run systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done
    run passwd -l "$gone" >/dev/null 2>&1 || true
    log "cut: $gone done — account, home, clones, ports and Vault backups all kept"
  done
fi
# Record what this run applied, for the next run's diff. Written LAST so a failed
# reconcile does not claim credit for a state it never reached.
if [[ "$DRY_RUN" == 1 ]]; then
  log "[dry-run] would snapshot the applied roster -> $applied_snapshot"
else
  install -m 0644 "$ROSTER" "$applied_snapshot"
fi

log "reconcile complete ($([[ "$DRY_RUN" == 1 ]] && echo DRY-RUN || echo applied))"
