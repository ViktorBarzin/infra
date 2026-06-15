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

# Share the admin's Claude subscription with a non-admin: inject CLAUDE_CODE_OAUTH_TOKEN
# (the staged long-lived token) into their t3-serve env — ONLY if they have neither their
# own ~/.claude/.credentials.json (own login) nor an existing token. Never clobbers. The
# agent picks it up when its t3-serve@ instance (re)starts.
install_user_claude_token() {
  local user="$1" home envf tok
  local token_file="${CLAUDE_TOKEN_FILE:-/etc/t3-serve/claude-oauth-token}"
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -z "$home" ]] && return 0
  [[ -f "$home/.claude/.credentials.json" ]] && return 0      # has own login -> leave it
  [[ -r "$token_file" ]] || return 0
  envf="${ENVDIR:-/etc/t3-serve}/$user.env"
  grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$envf" 2>/dev/null && return 0   # already shared
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] share Claude token -> $envf"; return 0; fi
  tok="$(cat "$token_file")"
  env_set "$envf" CLAUDE_CODE_OAUTH_TOKEN "$tok"
  log "shared Claude token -> $user (t3-serve env; restart needed to take effect)"
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

[[ $EUID -eq 0 ]] || { echo "t3-provision-users: must run as root" >&2; exit 1; }
for bin in python3 jq; do command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }; done
[[ -f "$ROSTER" && -f "$ENGINE" ]] || { echo "roster/engine not under $WORKSTATION_DIR" >&2; exit 1; }
install -d -m 0755 "$ENVDIR"

# 1) current sticky ports from existing .env files -> {os_user: port}
ports_file="$(mktemp)"; trap 'rm -f "$ports_file" "${desired_file:-}"' EXIT
{ echo "{}"; for f in "$ENVDIR"/*.env; do
    [[ -e "$f" ]] || continue
    u="$(basename "$f" .env)"; p="$(grep -oE 'T3_PORT=[0-9]+' "$f" | cut -d= -f2)"
    [[ -n "$p" ]] && jq -n --arg u "$u" --argjson p "$p" '{($u): $p}'
  done; } | jq -s 'add' > "$ports_file"

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
python3 "$ENGINE" derive --roster "$ROSTER" --ports-json "$ports_file" > "$desired_file"
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
  if [[ "$tier" != admin ]]; then            # non-admins: locked clone(s) (kept fresh) + kubeconfig + shared Claude token
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
    install_user_claude_token "$os_user"
    deploy_user_launcher "$os_user"          # keep ~/start-claude.sh current (skel only seeds new accounts)
  fi
  refresh_codex_mirror "$os_user"            # all tiers — mirror of the managed claudeMd
done < <(jq -r '.accounts[] | [.os_user, .tier, .shell, (if (.groups|length)==0 then "-" else (.groups|join(",")) end), .code_layout, (if (.repos|length)==0 then "-" else (.repos|join(",")) end)] | @tsv' "$desired_file")

# 5) per-user .env (sticky port) + enable t3-serve@
while IFS=$'\t' read -r os_user port; do
  envf="$ENVDIR/$os_user.env"
  env_set "$envf" T3_PORT "$port"   # update-or-append; preserves CLAUDE_CODE_OAUTH_TOKEN
  id "$os_user" >/dev/null 2>&1 && run systemctl enable --now "t3-serve@$os_user.service" >/dev/null 2>&1 || true
done < <(jq -r '.ports | to_entries[] | [.key, .value] | @tsv' "$desired_file")

# 5b) machine-wide (once, not per-user): keep the t3 pinned-version ENFORCER enabled (it
#     re-asserts T3_PIN daily; a no-op when already correct). NOT --now: with Persistent=true
#     a `--now` enable fires the missed daily job IMMEDIATELY, which on 2026-06-09 pulled a
#     breaking nightly mid-day and took out auth for everyone. `enable` (no --now) just arms
#     the 04:00 schedule; fresh boxes get t3 from setup-devvm.sh's pinned install, not here.
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
