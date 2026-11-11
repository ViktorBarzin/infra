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
# The admin Vault token, if any, is taken out of the environment at the top
# (take_admin_vault_token, below the helpers).

WORKSTATION_DIR="${WORKSTATION_DIR:-/home/wizard/code/infra/scripts/workstation}"
ENGINE="$WORKSTATION_DIR/roster_engine.py"
ROSTER="$WORKSTATION_DIR/roster.yaml"
ENVDIR=/etc/t3-serve
# The shared ChatGPT login for codex (stage_shared_auth; the wrapper, group and
# directory are in playbooks/devvm.yml).
CODEX_SHARED_DIR="${CODEX_SHARED_DIR:-/opt/codex-shared}"
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
# Public infra repo for the locked clone. It is public, so the clone needs no
# credentials.
INFRA_REMOTE="${INFRA_REMOTE:-https://github.com/ViktorBarzin/infra.git}"
# Canonical push target for non-admin infra clones (AGENTS.md "Non-admin
# workstation users"), and the base URLs for workspace-layout `repos` entries —
# those clone AS the user so their ~/.git-credentials PAT authenticates
# against private Forgejo repos. A plain `name` entry is viktor/<name>; an
# `owner/name` entry is that repo under FORGEJO_BASE.
FORGEJO_BASE="${FORGEJO_BASE:-https://forgejo.viktorbarzin.me}"
FORGEJO_INFRA_REMOTE="${FORGEJO_INFRA_REMOTE:-$FORGEJO_BASE/viktor/infra.git}"
REPO_REMOTE_BASE="${REPO_REMOTE_BASE:-$FORGEJO_BASE/viktor}"
# Per-user OIDC kubeconfig (kubelogin/PKCE; cluster server+CA copied from the admin kubeconfig).
OIDC_ISSUER="${OIDC_ISSUER:-https://authentik.viktorbarzin.me/application/o/kubernetes/}"
ADMIN_KUBECONFIG="${ADMIN_KUBECONFIG:-/home/wizard/.kube/config}"
# Per-user agent instructions, one file per person since 2026-09-22. Since
# 2026-11-03 each file is AGENTS.md at the root of that person's own PRIVATE
# Forgejo repo, named by their roster row's `agents_repo` (emo: ebarzin/agents),
# so one user cannot read another's. Until then they sat together under
# docs/agents/users/ in wizard's monorepo, which was dissolved. Not in this repo:
# a user's file carries personal detail and this repo is public. Step 5d-bis
# reads each file from its repo's master, never from a working tree.
# terminal-lobby's extension for pi, which the terminal-lobby package installs.
# Step 5d-quinquies links it into every roster user's ~/.pi/agent/extensions.
PI_EXTENSION="${PI_EXTENSION:-/usr/share/terminal-lobby/pi-extension.js}"
# chezmoi release install_user_dotfiles installs when a user with `dotfiles`
# has none; the one the live devvm runs.
CHEZMOI_VERSION="${CHEZMOI_VERSION:-v2.69.3}"

log() { echo "[t3-provision] $*"; }
# A rebuild runs this script with an admin VAULT_TOKEN
# (docs/runbooks/devvm-credentials.md). runuser hands the caller's environment
# to the user's command, and a user can read the environment of any process
# running as them, so the token must not stay in this script's environment:
# every `runuser -u <user>` below would carry it into code that user controls
# (their ~/.profile, git config, claude). take_admin_vault_token moves it into
# a variable that is never exported, before anything runs as a user, and
# vault_admin hands it to the vault CLI alone, which runs as root.
take_admin_vault_token() {
  ADMIN_VAULT_TOKEN="${VAULT_TOKEN:-}"
  unset VAULT_TOKEN
}
vault_admin() {
  VAULT_TOKEN="$ADMIN_VAULT_TOKEN" vault "$@"
}
run() { if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }
take_admin_vault_token

# ---- writing inside a user's home -------------------------------------------
# Root never creates, writes, chowns or chmods a path inside a user's home. The
# user controls every name in it, so a directory or file they swapped for a
# symlink would make root act on whatever the link points at: root running
# `install -d -o <user> ~/.kube` would hand a linked /etc/sudoers.d to the user.
# The /etc/skel links found on 2026-09-22 were one case of this pattern. These
# helpers run the operation AS the user, so a planted link reaches only what that
# user could reach anyway, and it fails as a permission error, not an escalation.
mkdir_as() {  # mkdir_as USER MODE DIR...
  local user="$1" mode="$2"; shift 2
  runuser -u "$user" -- install -d -m "$mode" "$@"
}
write_as() {  # write_as USER MODE DEST < content: atomic, never world-readable
  local user="$1" mode="$2" dst="$3"
  runuser -u "$user" -- sh -c 'umask 077; t="$1.tmp.$$"
    if cat > "$t" && chmod "$2" "$t" && mv -f "$t" "$1"; then exit 0; fi
    rm -f "$t"; exit 1' _ "$dst" "$mode"
}

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
    runuser -u "$user" -- mv "$home/code" "$tmp" \
      && mkdir_as "$user" 0755 "$home/code" \
      && runuser -u "$user" -- mv "$tmp" "$home/code/infra" \
      || log "WARN: workspace migration for $user stopped part way; check ~/code and $tmp"
  elif [[ ! -e "$home/code" ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] create workspace dir $user:~/code"; return 0; fi
    mkdir_as "$user" 0755 "$home/code" || log "WARN: could not create $user:~/code"
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
# A roster entry is `name` (viktor/<name>) or `owner/name`, such as the user's
# own ebarzin/agents; either clones to ~/code/<name>.
# A failed clone (no access yet, offline) is a WARN — the reconcile must never
# abort over a single repo; the next hourly run retries.
repo_url() {  # repo_url <name|owner/name>
  if [[ "$1" == */* ]]; then echo "$FORGEJO_BASE/$1.git"; else echo "$REPO_REMOTE_BASE/$1.git"; fi
}
install_user_repo() {
  local user="$1" repo="$2" home dst url
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -z "$home" ]] && return 0
  dst="$home/code/${repo##*/}"; url="$(repo_url "$repo")"
  [[ -e "$dst" || -L "$dst" ]] && return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] clone $url -> $user:$dst"; return 0; fi
  log "clone $repo -> $user:~/code/${repo##*/}"
  runuser -u "$user" -- env GIT_TERMINAL_PROMPT=0 git clone --quiet "$url" "$dst" 2>/dev/null \
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
  local src="${TMUX_PERSIST_SRC:-$WORKSTATION_DIR/../tmux-persist.sh}" dst=/usr/local/bin/tmux-persist
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

# The org policy for pi, machine-wide, from the same committed claudeMd. Pi has
# no managed layer of its own: terminal-lobby's pi extension (PI_EXTENSION)
# reads this file and appends it to pi's system prompt on every turn. The file
# is the policy text and nothing else, since every byte in it reaches the model;
# the provenance note that Codex's copy carries in a TOML comment lives here
# instead. Rewritten only when the text changes, and renamed into place so a
# turn starting mid-write reads the old text or the new.
sync_pi_org_policy() {
  local dst=/etc/pi/org-policy.md tmp
  tmp="$(mktemp)"
  if ! python3 - "$MANAGED_SRC" > "$tmp" 2>/dev/null <<'PY'
import json, sys
text = json.load(open(sys.argv[1], encoding="utf-8"))["claudeMd"].rstrip("\n")
if not text.strip():
    sys.exit(1)  # an empty policy means a broken source; keep the deployed file
sys.stdout.buffer.write((text + "\n").encode("utf-8"))
PY
  then rm -f "$tmp"; log "WARN: pi org policy not generated from $MANAGED_SRC"; return 0; fi
  if cmp -s "$tmp" "$dst" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] pi org policy -> $dst"; rm -f "$tmp"; return 0; fi
  install -d -m 0755 -o root -g root /etc/pi \
    && install -m 0644 -o root -g root "$tmp" "$dst.new" && mv -f "$dst.new" "$dst" \
    && log "deployed pi org policy -> $dst"
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
  mkdir_as "$user" 0700 "$home/.kube" || { log "WARN: could not create $user:~/.kube"; return 0; }
  write_as "$user" 0600 "$kc" <<EOF || { log "WARN: could not write $user:~/.kube/config"; return 0; }
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
  { mkdir_as "$user" 0700 "$home/.kube" && write_as "$user" 0600 "$kc" < "$tmp"; } \
    || { log "WARN: failed to write browser kubeconfig for $user"; rm -f "$tmp"; return 0; }
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
    mkdir_as "$user" 0700 "$cfg" "$home/.local/state/claude-auth-sync" \
      || log "WARN: could not create the Claude-auth state dirs for $user"
  fi

  if [[ ! -s "$token_file" ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then
      echo "[dry-run] mint scoped Claude-auth Vault token -> $user"
    elif vault_admin token lookup >/dev/null 2>&1 && \
      token="$(vault_admin token create -orphan -period=768h -policy="$policy" \
        -display-name="devvm-claude-auth-$user" -field=token 2>/dev/null)"; then
      if mkdir_as "$user" 0700 "$cfg" && write_as "$user" 0600 "$token_file" <<<"$token"; then
        log "minted isolated Claude-auth Vault token -> $user"
      else
        log "WARN: minted a Claude-auth Vault token for $user but could not write $token_file"
      fi
    else
      log "WARN: scoped Claude-auth Vault token missing for $user (run provisioner with admin VAULT_TOKEN after vault stack apply)"
    fi
  fi
  run systemctl enable --now "claude-auth-sync@$user.timer" >/dev/null 2>&1 || true
}

# ---- a rebuilt box gets each user's own state back (2026-11-11) --------------
# docs/plans/2026-11-11-disposable-devvm.md: the devvm is rebuilt from code, and
# what a user made by hand comes back from a kept place. These three steps are
# that half for credentials, the Vault renewer and dotfiles. Each writes only
# what is absent, so on the live box they are no-ops.

# The user's hand-made credential files (SSH and GPG keys, Git PATs, gh, gcloud,
# docker, the admin kubeconfig) from Vault, secret/workstation/<user>/files,
# via workstation-creds. Reading those needs an admin Vault token, which the
# hourly run does not have, so this restores only when the provisioner is run
# with one: on a rebuild, read from the admin's ~/.vault-token inside sudo and
# never passed on the sudo line, which sudo logs
# (docs/runbooks/devvm-credentials.md). A file already there is never replaced.
restore_user_credentials() {  # restore_user_credentials USER
  local user="$1"
  [[ -s "$CREDS_SRC" ]] || { log "WARN: $CREDS_SRC missing -> credential restore skipped for $user"; return 0; }
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] restore Vault-held credential files -> $user"; return 0; fi
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.viktorbarzin.me}"
  if ! vault_admin token lookup >/dev/null 2>&1; then
    [[ -n "${CREDS_NO_VAULT_LOGGED:-}" ]] || log "credential restore skipped: no admin Vault token (expected on the hourly run)"
    CREDS_NO_VAULT_LOGGED=1
    return 0
  fi
  local out
  if out="$(VAULT_TOKEN="$ADMIN_VAULT_TOKEN" bash "$CREDS_SRC" restore "$user" 2>&1)"; then
    log "$(tail -n 1 <<<"$out")"
  else
    log "WARN: credential restore failed for $user: $(tail -n 1 <<<"$out")"
  fi
}

# vault-token-renew for every user it has a token scope for (vtr_resolve_config
# in the script itself decides that, so the two cannot disagree): the script in
# ~/.local/bin, its user units, linger so the timer fires logged out, and a
# first periodic token when ~/.vault-token is absent and this run holds admin
# Vault access. Installed by hand before 2026-11-11
# (docs/runbooks/vault-token-renew-devvm.md).
install_vault_token_renew() {  # install_vault_token_renew USER
  local user="$1" home uid policies flags=() p token changed=0 f
  [[ -s "$VTR_SRC" && -s "$VTR_SERVICE" && -s "$VTR_TIMER" ]] || return 0
  if ! policies="$(bash -c 'source "$1"; vtr_resolve_config "$2" && echo "${VTR_MINT_POLICIES[*]}"' _ "$VTR_SRC" "$user" 2>/dev/null)"; then
    log "vault-token-renew: no token scope for $user in vault-token-renew.sh -> skipped"
    return 0
  fi
  home="$(getent passwd "$user" | cut -d: -f6)"
  uid="$(id -u "$user" 2>/dev/null)" || return 0
  [[ -n "$home" && -d "$home" ]] || return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] vault-token-renew script + units + timer -> $user"; return 0; fi
  for f in "$home/.local/bin" "$home/.config/systemd/user"; do
    [[ -d "$f" ]] || mkdir_as "$user" 0755 "$f" || { log "WARN: could not create $f"; return 0; }
  done
  if ! cmp -s "$VTR_SRC" "$home/.local/bin/vault-token-renew"; then
    write_as "$user" 0755 "$home/.local/bin/vault-token-renew" < "$VTR_SRC" && changed=1
  fi
  for f in service timer; do
    p="VTR_${f^^}"
    if ! cmp -s "${!p}" "$home/.config/systemd/user/vault-token-renew.$f"; then
      write_as "$user" 0644 "$home/.config/systemd/user/vault-token-renew.$f" < "${!p}" && changed=1
    fi
  done
  [[ "$(loginctl show-user "$user" -p Linger 2>/dev/null)" == "Linger=yes" ]] || loginctl enable-linger "$user" >/dev/null 2>&1 || true
  local sysu=(runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user)
  if (( changed )) || ! "${sysu[@]}" is-enabled --quiet vault-token-renew.timer 2>/dev/null; then
    "${sysu[@]}" daemon-reload >/dev/null 2>&1 || true
    "${sysu[@]}" enable --now vault-token-renew.timer >/dev/null 2>&1 \
      || log "WARN: could not enable vault-token-renew.timer for $user (user manager not up?)"
    log "installed vault-token-renew -> $user"
  fi
  [[ -s "$home/.vault-token" ]] && return 0
  for p in $policies; do flags+=("-policy=$p"); done
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.viktorbarzin.me}"
  if vault_admin token lookup >/dev/null 2>&1 && \
     token="$(vault_admin token create -orphan -period=768h "${flags[@]}" -display-name="devvm-$user" -field=token 2>/dev/null)" && \
     [[ -n "$token" ]] && write_as "$user" 0600 "$home/.vault-token" <<<"$token"; then
    log "minted periodic Vault token -> $user:~/.vault-token"
  else
    log "WARN: no ~/.vault-token for $user (run the provisioner with an admin VAULT_TOKEN to mint one)"
  fi
}

# The user's dotfiles: `chezmoi init --apply` from the roster row's `dotfiles`
# Forgejo repo (wizard: viktor/dot_files), ONCE per box: an existing
# ~/.local/share/chezmoi is the user's live source and is never touched, since
# a whole-tree apply over a home that drifted from the repo would overwrite
# work. --exclude=encrypted skips the GPG-encrypted entries, which need a
# passphrase; on the devvm the files they hold (the admin kubeconfig among
# them) come from Vault through restore_user_credentials, which runs first.
# chezmoi itself is installed into ~/.local/bin, pinned, when absent.
install_user_dotfiles() {  # install_user_dotfiles USER REPO|-
  local user="$1" repo="$2" home uid bin src
  [[ -n "$repo" && "$repo" != "-" ]] || return 0
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0
  src="$home/.local/share/chezmoi"
  # A first init that failed (Forgejo or the network down) leaves an empty
  # source directory behind. rmdir removes only an empty one, so that case is
  # retried and a real source, which always has files, is left alone.
  if [[ -e "$src" || -L "$src" ]]; then
    [[ "$DRY_RUN" != 1 && ! -L "$src" ]] && runuser -u "$user" -- rmdir "$src" 2>/dev/null || return 0
    log "retrying dotfiles for $user: ~/.local/share/chezmoi was left empty"
  fi
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] chezmoi init --apply $repo -> $user"; return 0; fi
  bin="$home/.local/bin/chezmoi"
  if [[ ! -x "$bin" ]]; then
    runuser -u "$user" -- sh -c 'cd "$1" && curl -fsSL https://get.chezmoi.io | sh -s -- -b "$1/.local/bin" -t "$2"' \
      _ "$home" "$CHEZMOI_VERSION" >/dev/null 2>&1 || { log "WARN: could not install chezmoi for $user"; return 0; }
  fi
  if runuser -u "$user" -- env HOME="$home" "$bin" init --apply --force --no-tty --keep-going --exclude=encrypted \
       "$(repo_url "$repo")" >/dev/null 2>&1; then
    log "applied dotfiles $repo -> $user"
  else
    log "WARN: chezmoi init --apply $repo for $user finished with errors (some entries may be missing)"
    runuser -u "$user" -- rmdir "$src" 2>/dev/null || true   # nothing cloned: let the next run retry
  fi
  uid="$(id -u "$user" 2>/dev/null)" && \
    runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user daemon-reload >/dev/null 2>&1 || true
}

# The admin's own infra checkout at ~/code/infra. Non-admins get a locked clone
# from install_locked_clone; the admin's was made by hand, so on a new box there
# was none, and both the hourly run (whose WORKSTATION_DIR is that checkout) and
# the rebuild command in docs/runbooks/devvm-credentials.md stopped at "roster/
# engine not under ...". The bootstrap's own run, from its clone in /opt, makes
# it. Cloned over HTTPS from Forgejo, where infra is public, as the admin; it
# stays git-crypt locked until the admin unlocks it with the key in
# secret/infra (same runbook). An existing ~/code/infra, or a ~/code that is
# itself the clone, is never touched.
install_admin_infra_clone() {  # install_admin_infra_clone USER
  local user="$1" home dst
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0
  dst="$home/code/infra"
  [[ -e "$dst" || -L "$dst" || -e "$home/code/.git" ]] && return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] clone infra -> $user:~/code/infra"; return 0; fi
  if [[ ! -d "$home/code" ]]; then
    mkdir_as "$user" 2770 "$home/code" || { log "WARN: could not create $user:~/code"; return 0; }
    runuser -u "$user" -- chgrp code-shared "$home/code" 2>/dev/null || true
  fi
  log "clone infra -> $user:~/code/infra (locked; unlock with secret/infra git_crypt_key_b64)"
  if runuser -u "$user" -- env GIT_TERMINAL_PROMPT=0 git clone --quiet "$FORGEJO_INFRA_REMOTE" "$dst" 2>/dev/null; then
    runuser -u "$user" -- git -C "$dst" remote add forgejo "$FORGEJO_INFRA_REMOTE" 2>/dev/null || true
  else
    log "WARN: clone of infra failed for $user (offline?); the next run retries"
  fi
}

# Shared logins that live outside any home (setup-devvm.sh section 8, which a
# rebuilt box never ran): the one ChatGPT login every codex user shares, at
# /opt/codex-shared/auth.json (codex-auth-backup keeps secret/workstation
# codex_shared_auth_json current), and each person's chrome hub config,
# /etc/t3-serve/chrome-hub-<user>.json, which install_chrome_hub copies into
# their home. Only with an admin Vault token, and only what is missing: the
# live Codex file is newer than Vault between two backups.
stage_shared_auth() {
  local need=0 u auth t out   # need: 2 = the Codex login, 1 = a hub config
  [[ -s "$CODEX_SHARED_DIR/auth.json" ]] || need=2
  if [[ -s "$HUBS_MAP" ]]; then
    for u in $(jq -r 'keys[]' "$HUBS_MAP" 2>/dev/null); do
      [[ -s "$ENVDIR/chrome-hub-$u.json" ]] || { need=$((need | 1)); break; }
    done
  fi
  (( need )) || return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] stage the shared Codex login and chrome hub configs from Vault"; return 0; fi
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.viktorbarzin.me}"
  if ! vault_admin token lookup >/dev/null 2>&1; then
    log "shared login staging skipped: no admin Vault token (expected on the hourly run)"
    return 0
  fi
  if (( need & 2 )); then
    if auth="$(vault_admin kv get -field=codex_shared_auth_json secret/workstation 2>/dev/null)" && [[ -n "$auth" ]]; then
      getent group codex-shared >/dev/null 2>&1 || groupadd codex-shared
      install -d -m 2770 "$CODEX_SHARED_DIR" && chgrp codex-shared "$CODEX_SHARED_DIR" && chmod 2770 "$CODEX_SHARED_DIR"
      # Group members can write in this directory, so the temp file is made
      # with mktemp (exclusive create) rather than a name they could plant.
      if t="$(mktemp "$CODEX_SHARED_DIR/.auth.json.XXXXXX")" && printf '%s\n' "$auth" > "$t" &&
         chgrp codex-shared "$t" && chmod 0660 "$t" && mv -f "$t" "$CODEX_SHARED_DIR/auth.json"; then
        log "staged the shared Codex login -> $CODEX_SHARED_DIR/auth.json"
      else
        rm -f "$t"; log "WARN: could not write $CODEX_SHARED_DIR/auth.json"
      fi
    else
      log "WARN: secret/workstation codex_shared_auth_json unreadable -> shared Codex login not staged"
    fi
  fi
  if (( need & 1 )) && [[ -s "$HUBS_SRC" ]]; then
    if out="$(VAULT_TOKEN="$ADMIN_VAULT_TOKEN" CHROME_HUBS_MAP="$HUBS_MAP" CHROME_HUBS_OUT="$ENVDIR" bash "$HUBS_SRC" 2>&1)"; then
      log "chrome hub configs: $(grep -c 'staged' <<<"$out") staged"
    else
      log "WARN: chrome hub staging failed: $(tail -n 1 <<<"$out")"
    fi
  fi
  return 0
}

# Re-deploy the managed per-user Claude launcher to ~/start-claude.sh. /etc/skel only
# seeds it at account creation (setup-devvm.sh), so without this a launcher edit never
# reaches EXISTING users — they keep running a stale copy. Copy-if-changed from the repo's
# skel/, owned by the user, 0755. (We deliberately do NOT re-copy .tmux.conf: terminal-lobby
# appends a managed persistence section to each user's ~/.tmux.conf that a re-copy would clobber.)
deploy_user_launcher() {
  local user="$1" home src dst
  src="${LAUNCHER_SRC:-$WORKSTATION_DIR/skel/start-claude.sh}"
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" && -f "$src" ]] || return 0
  dst="$home/start-claude.sh"
  cmp -s "$src" "$dst" 2>/dev/null && return 0          # already current -> no churn
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] deploy launcher -> $dst"; return 0; fi
  write_as "$user" 0755 "$dst" < "$src" || { log "WARN: could not deploy start-claude.sh -> $user"; return 0; }
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
#
# Since 2026-10-01, once terminal-lobby's package has installed
# /usr/local/bin/tl-browser, step (2) points the entry at it instead: a stdio
# launcher that gives each Claude session its own browser, which the person can
# watch and take over from the lobby, and which is shut when the agent is done
# (terminal-lobby ADR-0035). The shared playwright-mcp@ server then stays up
# only while a Claude process that read the old http entry is still running,
# see playwright_stdio_settled.
install_playwright() {
  local user="$1" home port
  local tl_browser="${TL_BROWSER_BIN:-/usr/local/bin/tl-browser}"
  local since_file="$STATEDIR/playwright-stdio-$user.since" entry
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0
  port="$(grep -oE 'PLAYWRIGHT_PORT=[0-9]+' "$ENVDIR/playwright-$user.env" 2>/dev/null | cut -d= -f2 || true)"
  [[ -n "$port" ]] || { log "WARN: no PLAYWRIGHT_PORT for $user -> skip playwright"; return 0; }

  # (1) the user's own hub config (snapshot + write-back URLs and tokens)
  install_chrome_hub "$user" "$home"

  # (2) wire user-scope ~/.claude.json (AS the user, login shell so the native
  #     ~/.local/bin/claude is on PATH; clobber-proof + if-absent via `mcp get`).
  #     With tl-browser installed the entry is the stdio launcher. An entry this
  #     script wrote earlier (http to a localhost /mcp URL) is replaced, and the
  #     moment of the switch is recorded once in a root-owned file. Any other
  #     `playwright` entry is the user's own choice and is left alone.
  if [[ "$DRY_RUN" == 1 ]]; then
    if [[ -x "$tl_browser" ]]; then
      echo "[dry-run] wire playwright MCP (stdio $tl_browser, replacing the http entry) -> $user"
    else
      echo "[dry-run] wire playwright MCP (:$port) if-absent -> $user"
    fi
  elif runuser -u "$user" -- bash -lc 'command -v claude >/dev/null 2>&1'; then
    entry="$(runuser -u "$user" -- bash -lc 'claude mcp get playwright 2>/dev/null')" || entry=""
    if [[ -x "$tl_browser" ]]; then
      if grep -qE 'URL: http://localhost:[0-9]+/mcp' <<<"$entry"; then
        runuser -u "$user" -- bash -lc 'claude mcp remove --scope user playwright >/dev/null 2>&1' \
          || log "WARN: claude mcp remove playwright failed for $user"
        entry=""
      fi
      if [[ -z "$entry" ]]; then
        runuser -u "$user" -- bash -lc "claude mcp add --scope user playwright -- '$tl_browser' >/dev/null 2>&1" \
          && entry="$tl_browser" \
          && log "wired playwright MCP (user scope, stdio $tl_browser) -> $user" \
          || log "WARN: claude mcp add playwright (stdio) failed for $user (retries next run)"
      fi
      if [[ "$entry" == *"$tl_browser"* && ! -s "$since_file" ]]; then
        date +%s > "$since_file.tmp" && mv -f "$since_file.tmp" "$since_file" \
          && log "recorded the playwright stdio switch for $user"
      fi
    elif [[ -z "$entry" ]]; then
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
  # The snapshot-refresh timer keeps the shared storage state fresh, and
  #     tl-browser's host reads that same file, so it stays on either way.
  run systemctl enable --now "playwright-snapshot-refresh@$user.timer" >/dev/null 2>&1 || true
  if [[ -x "$tl_browser" ]] && playwright_stdio_settled "$user" "$since_file"; then
    if systemctl is-enabled --quiet "playwright-mcp@$user.service" 2>/dev/null; then
      run systemctl disable --now "playwright-mcp@$user.service" >/dev/null 2>&1 || true
      log "playwright-mcp@$user retired: every Claude session of $user uses tl-browser now"
    fi
    return 0
  fi
  run systemctl enable --now "playwright-mcp@$user.service" >/dev/null 2>&1 || true
}

# Copy USER's staged hub config (stage-chrome-hubs.sh) to ~/.config/chrome-hub/
# hub.json whenever it differs, so a token rotation reaches the user on the next
# reconcile. A user with no staged file has no hub: nothing is written, and the
# snapshot refresh and every browser's write-back stay off for them.
install_chrome_hub() {
  local user="$1" home="$2" staged="$ENVDIR/chrome-hub-$1.json" dest
  dest="$home/.config/chrome-hub/hub.json"
  [[ -r "$staged" ]] || return 0
  if ! cmp -s "$staged" "$dest" 2>/dev/null; then
    if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] install chrome hub config -> $user"; return 0; fi
    if mkdir_as "$user" 0700 "$home/.config/chrome-hub" \
       && write_as "$user" 0600 "$dest" < "$staged"; then
      log "installed chrome hub config -> $user"
    else
      log "WARN: could not install the chrome hub config for $user"
      return 0
    fi
  fi
  # The T3 browser sync (units from the devvm playbook). enable --now is
  # idempotent and never restarts a running unit.
  if [[ -f /etc/systemd/system/t3-browser-cookies@.timer ]]; then
    run systemctl enable --now "t3-browser-cookies@$user.timer" >/dev/null 2>&1 || true
  fi
}

# True once USER's playwright entry has been switched to tl-browser (SINCE_FILE
# holds the epoch second it happened) AND every claude process USER has running
# started after that second. Claude reads ~/.claude.json at launch, so a session
# started before the switch still talks to the shared http server; stopping that
# server under it would break its browser tools mid-task.
playwright_stdio_settled() {
  local user="$1" since_file="$2" since now etimes comm
  [[ -s "$since_file" ]] || return 1
  since="$(cat "$since_file")"
  [[ "$since" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  while read -r etimes comm; do
    [[ "$comm" == claude && "$etimes" =~ ^[0-9]+$ ]] || continue
    (( now - etimes > since )) || return 1
  done < <(ps -u "$user" -o etimes=,comm= 2>/dev/null)
  return 0
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
# The shared facts come from scripts/workstation/beads/metadata.json in this
# repo, read from origin/master by step 0a ($BEADS_SRC). Until 2026-11-03 they
# were read from wizard's ~/code/.beads/metadata.json, which the ~/code monorepo
# tracked; the monorepo was dissolved, so the copy here is now the source and
# wizard's own ~/code/.beads is written from it too (install_admin_beads). If
# the source is missing this is skipped with a warning rather than guessing.
#
# A non-admin's metadata sits in their infra clone's .beads/, which infra tracks
# with a local-project default: ~/code/.beads on the single layout, and
# ~/code/infra/.beads on the workspace layout, where the migration moved it.
# Both are pointed when present; neither is created.
install_beads() {
  local user="$1" home admin_meta dir
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home/code" ]] || return 0
  admin_meta="$BEADS_SRC/metadata.json"
  [[ -r "$admin_meta" ]] || { log "WARN: no beads metadata at $BEADS_SRC -> skip beads for $user"; return 0; }
  if [[ "$user" == "wizard" ]]; then install_admin_beads "$home"; return 0; fi
  for dir in "$home/code" "$home/code/infra"; do
    [[ -f "$dir/.beads/metadata.json" && ! -L "$dir/.beads" ]] || continue
    point_user_beads "$user" "$dir" "$admin_meta"
  done
  return 0
}

# point_user_beads <user> <dir> <source metadata>: <dir>/.beads/metadata.json.
point_user_beads() {
  local user="$1" dir="$2" admin_meta="$3" user_meta="$2/.beads/metadata.json"
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry-run] point $user's beads ($dir) at the shared Dolt server + project identity"
    return 0
  fi

  # Rewrite only the server + identity keys; everything else in their metadata
  # is theirs to keep. Idempotent: a correct file is left byte-identical.
  # Root reads the committed copy and hands its JSON over in the environment;
  # the rewrite itself runs AS the user.
  local admin_json
  admin_json="$(cat "$admin_meta")" || { log "WARN: cannot read $admin_meta"; return 0; }
  runuser -u "$user" -- env ADMIN_META="$admin_json" python3 - "$user_meta" <<'PYEOF' || { log "WARN: beads metadata rewrite failed for $user"; return 0; }
import json, os, sys
target = sys.argv[1]
a = json.loads(os.environ["ADMIN_META"])
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
  runuser -u "$user" -- chmod 700 "$dir/.beads" 2>/dev/null || true
  # bd refuses to write without a role. contributor, not maintainer: a
  # non-admin should not be closing other people's issues by default.
  runuser -u "$user" -- sh -c 'git -C "$1" config beads.role >/dev/null 2>&1 || git -C "$1" config beads.role contributor' _ "$dir" 2>/dev/null || true
  log "beads pointed at the shared Dolt server -> $user:$dir"
}

# wizard's ~/code/.beads holds the four files bd reads in the admin workspace:
# metadata.json (the shared Dolt server and project identity), config.yaml,
# and the .gitignore and README.md bd init wrote (kept here as `gitignore`, so
# it does not act as a .gitignore inside this repo). Each is written as wizard
# from $BEADS_SRC when it differs, so a rebuilt box gets them back and an
# unchanged one is left byte-identical. Runtime files (dolt/, backup/, the
# credential key, logs) are bd's own and never touched. Best-effort: returns 0.
install_admin_beads() {
  local home="$1" dir f dst
  dir="$home/code/.beads"
  [[ -L "$dir" ]] && { log "WARN: $dir is a symlink -> wizard's beads files skipped"; return 0; }
  for f in metadata.json config.yaml gitignore README.md; do
    dst="$f"; [[ "$f" == gitignore ]] && dst=.gitignore
    [[ -s "$BEADS_SRC/$f" ]] || continue
    cmp -s "$BEADS_SRC/$f" "$dir/$dst" 2>/dev/null && continue
    if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] beads $dst -> wizard:$dir"; continue; fi
    [[ -d "$dir" ]] || mkdir_as wizard 0700 "$dir" || { log "WARN: could not create $dir"; return 0; }
    if write_as wizard 0640 "$dir/$dst" < "$BEADS_SRC/$f"; then log "beads $dst -> wizard (source changed)"
    else log "WARN: could not write $dir/$dst"; fi
  done
  return 0
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
  token="$(vault_admin kv get -field="$user" secret/browser-bridge/tokens 2>/dev/null || true)"

  # 2) Otherwise mint one, and keep the copy.
  if [[ -z "$token" ]]; then
    local provision_token
    provision_token="$(vault_admin kv get -field=provision_token secret/browser-bridge 2>/dev/null || true)"
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
    vault_admin kv patch "secret/browser-bridge/tokens" "$user=$token" >/dev/null 2>&1 \
      || vault_admin kv put "secret/browser-bridge/tokens" "$user=$token" >/dev/null 2>&1 \
      || log "WARN: minted a browser-bridge token for $user but could not store it in Vault"
  fi

  # write_as holds umask 077 for the whole write: the token must never exist
  # world-readable, not even for the instant before its mode is set.
  if mkdir_as "$user" 0700 "$dir" && printf '%s\n' "$token" | write_as "$user" 0600 "$dst"; then
    log "browser-bridge CLI token installed -> $user"
  else
    log "WARN: could not write the browser-bridge CLI token for $user"
  fi
  return 0  # best-effort tail must never return non-zero under set -euo pipefail
}

# The agent-tool keys a user's ~/.claude/settings.json carries in env:
# MEMORY_API_KEY and CLAUDE_MEMORY_API_KEY for homelab memory, PAGES_API_KEY
# for page publishing. Each is that user's entry in the map its service checks,
# secret/claude-memory api_keys and secret/pages-publish api_keys, so a rebuilt
# box takes them from there: nothing else brings them back, since chezmoi
# leaves settings.json alone on the devvm and the session store does not keep
# env values. Fills only keys that are absent, never replacing one, and only
# when this run holds an admin Vault token. The values reach the user's python
# on stdin, never in argv or the log.
install_agent_api_keys() {  # install_agent_api_keys USER
  local user="$1" home settings mem pages want added
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home/.claude" ]] || return 0
  settings="$home/.claude/settings.json"
  if [[ -f "$settings" ]] && jq -e '.env // {} | has("MEMORY_API_KEY") and has("CLAUDE_MEMORY_API_KEY") and has("PAGES_API_KEY")' \
       "$settings" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] agent API keys from Vault -> $user"; return 0; fi
  vault_admin token lookup >/dev/null 2>&1 || return 0
  mem="$(vault_admin kv get -field=api_keys secret/claude-memory 2>/dev/null | jq -r --arg u "$user" '.[$u] // empty' 2>/dev/null)" || mem=""
  pages="$(vault_admin kv get -field=api_keys secret/pages-publish 2>/dev/null | jq -r --arg u "$user" '.[$u] // empty' 2>/dev/null)" || pages=""
  want="$(jq -cn --arg m "$mem" --arg p "$pages" --arg url https://claude-memory.viktorbarzin.me \
    '(if $m != "" then {MEMORY_API_KEY: $m, CLAUDE_MEMORY_API_KEY: $m, MEMORY_API_URL: $url, CLAUDE_MEMORY_API_URL: $url} else {} end)
     + (if $p != "" then {PAGES_API_KEY: $p} else {} end)')"
  [[ "$want" != "{}" ]] || return 0
  added="$(printf '%s' "$want" | runuser -u "$user" -- sh -c 'umask 077 && exec python3 -c "$1" "$2"' _ '
import json, os, sys
path, want = sys.argv[1], json.load(sys.stdin)
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as fh:
        data = json.load(fh)
env = data.setdefault("env", {})
added = sorted(k for k in want if k not in env)
if added:
    env.update({k: want[k] for k in added})
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
print(" ".join(added))
' "$settings" 2>/dev/null)" || { log "WARN: could not write the agent API keys for $user"; return 0; }
  [[ -n "$added" ]] && log "agent API keys from Vault -> $user ($added)"
  return 0
}

install_memory() {
  local user="$1" home
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0
  local src="${HOOKS_SRC:-$WORKSTATION_DIR/claude-hooks}" hooks_dst="$home/.claude/hooks" settings="$home/.claude/settings.json"
  [[ -d "$src" ]] || { log "WARN: $src missing -> skip memory setup for $user"; return 0; }

  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] memory: hooks + settings wire + claude_memory MCP removal -> $user"; return 0; fi

  # (1) (re)install the hook scripts, owned by the user (refreshed each reconcile so fixes land)
  mkdir_as "$user" 0755 "$hooks_dst" || { log "WARN: could not create $user:~/.claude/hooks"; return 0; }
  local h
  for h in auto-learn.py pre-compact-backup.sh post-compact-recovery.sh zsh-guard.py scan-guard.py rm-guard.py fixer-suggest.py; do
    write_as "$user" 0755 "$hooks_dst/$h" < "$src/$h" || log "WARN: could not install hook $h -> $user"
  done
  # Retired hooks: unslop-check.py (2026-09-28), homelab-memory-recall.py (2026-11-09).
  # wire-memory-hooks.py unwires them below.
  runuser -u "$user" -- rm -f "$hooks_dst/unslop-check.py" "$hooks_dst/homelab-memory-recall.py" || true

  # (2) wire the hooks in settings.json, if-absent + additive. The helper sits under
  #     the admin's hardened home (mode 700), which the user cannot enter, so root
  #     opens it and feeds it on stdin to a python running AS the user. umask 077
  #     keeps settings.json 0600 (it holds the per-user MEMORY_API_KEY).
  if runuser -u "$user" -- sh -c 'umask 077 && exec python3 - "$1"' _ "$home" < "$src/wire-memory-hooks.py" >/dev/null 2>&1; then
    log "memory hooks wired -> $user"
  else
    log "WARN: memory hook wiring failed for $user (retries next reconcile)"
  fi
  [[ -f "$settings" ]] && runuser -u "$user" -- chmod 600 "$settings" || true

  # (2a) on a rebuilt box, the user's keys come back from Vault (admin token only).
  install_agent_api_keys "$user"

  # (2b) reuse the user's existing key; warn (do NOT mint — needs an admin vault write) if absent.
  if [[ -f "$settings" ]] && ! grep -q 'MEMORY_API_KEY' "$settings"; then
    log "WARN: $user has no MEMORY_API_KEY in settings.json — homelab memory no-ops until an admin mints one"
  fi

  # (3) remove the now-superseded claude_memory MCP (AS the user, if-present) + the plugin dir.
  if runuser -u "$user" -- bash -lc 'command -v claude >/dev/null 2>&1 && claude mcp get claude_memory >/dev/null 2>&1'; then
    runuser -u "$user" -- bash -lc 'claude mcp remove claude_memory >/dev/null 2>&1' && log "removed claude_memory MCP -> $user" || true
  fi
  if [[ -d "$home/.claude/plugins/claude-memory" ]]; then
    runuser -u "$user" -- rm -rf "$home/.claude/plugins/claude-memory" && log "removed claude-memory plugin dir -> $user"
  fi
  return 0  # best-effort tail must never return non-zero, else set -euo pipefail aborts the whole reconcile
}

# fetch_user_agents <os_user> <owner/name>: refresh $AGENTS_SRC_DIR/<os_user>.md
# from AGENTS.md on master of that Forgejo repo, the user's own private one.
#
# The fetch lands in one bare repository per user under $AGENTS_FETCH_DIR, a
# directory owned by the admin infra checkout's owner ($clone_owner, wizard) and
# closed to everyone else. Every git command runs as that owner, like step 0a's
# fetch, so it authenticates with that owner's Forgejo credential (viktor, a
# collaborator on each user's repo) and root never runs git in a repository it
# does not own. Root only writes what `git show` prints, into a 0700 directory.
# Only committed master is read; no working tree is involved.
#
# Fail safe: a failed fetch, or a master with no AGENTS.md, keeps the last good
# copy, so the user keeps the instructions they already have, and says so in
# the journal. Best-effort tail: must return 0.
fetch_user_agents() {
  local user="$1" repo="$2" mirror dest sha
  mirror="$AGENTS_FETCH_DIR/$user.git"; dest="$AGENTS_SRC_DIR/$user.md"
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] fetch agent instructions for $user from $repo master"; return 0; fi
  install -d -m 0700 "$AGENTS_SRC_DIR"   # root only: one user's file is not another's to read
  install -d -m 0700 -o "$clone_owner" "$AGENTS_FETCH_DIR" || { log "WARN: cannot create $AGENTS_FETCH_DIR -> agent instructions for $user unchanged"; return 0; }
  if [[ ! -d "$mirror" ]] && ! runuser -u "$clone_owner" -- git init --quiet --bare "$mirror" >/dev/null 2>&1; then
    log "WARN: cannot create $mirror -> agent instructions for $user unchanged"; return 0
  fi
  if ! runuser -u "$clone_owner" -- env GIT_TERMINAL_PROMPT=0 git --git-dir="$mirror" \
       fetch --quiet --no-tags "$FORGEJO_BASE/$repo.git" +refs/heads/master:refs/heads/master 2>/dev/null; then
    log "WARN: fetch of $repo failed -> agent instructions for $user unchanged"; return 0
  fi
  sha="$(runuser -u "$clone_owner" -- git --git-dir="$mirror" rev-parse --short master 2>/dev/null)"
  if runuser -u "$clone_owner" -- git --git-dir="$mirror" show master:AGENTS.md > "$dest.tmp" 2>/dev/null \
     && [[ -s "$dest.tmp" ]]; then
    mv -f "$dest.tmp" "$dest"
    log "agent instructions for $user: $repo master ($sha)"
  else
    rm -f "$dest.tmp"
    log "WARN: no AGENTS.md on $repo master -> agent instructions for $user unchanged"
  fi
  return 0
}

# prune_user_agents <managed os_users, one per line>: a user whose roster row
# no longer names an agents_repo stops being managed. Their home keeps the last
# file it received and nothing overwrites it afterwards; the cached copy and the
# fetch are dropped here.
prune_user_agents() {
  local f u
  for f in "$AGENTS_SRC_DIR"/*.md "$AGENTS_FETCH_DIR"/*.git; do
    [[ -e "$f" ]] || continue
    u="$(basename "$f")"; u="${u%.md}"; u="${u%.git}"
    grep -qxF -- "$u" <<<"$1" && continue
    if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] drop $f ($u has no agents_repo)"; continue; fi
    rm -rf "$f" && log "agent instructions no longer managed for $u -> dropped $f"
  done
  return 0
}

# Each user's own agent instructions -> ~/.agents/AGENTS.md, linked from both
# harnesses: ~/.claude/CLAUDE.md (Claude Code) and ~/.codex/AGENTS.md (Codex).
# Replaced install_shared_rules on 2026-09-22, when one shared set copied into
# every home gave way to one file per person. Only users whose roster row names
# an agents_repo are touched (fetch_user_agents below); wizard's comes from his
# dotfiles and is left alone. The file is installed byte for byte as it is on
# that repo's master.
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
    # having its edit reverted within the hour. The place to change it is the
    # user's own clone of their agents_repo (~/code/agents for emo).
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

# link_agents_file <user> <path> [target]: make <path> a symlink to <target>, as
# the user. The default, ../.agents/AGENTS.md, suits a file one directory below
# the home (~/.claude/CLAUDE.md, ~/.codex/AGENTS.md); pi's ~/.pi/agent/AGENTS.md
# sits one deeper and passes ../../.agents/AGENTS.md. A regular file there is
# the old hand-edited CLAUDE.md or the old Codex mirror, whose content now lives
# in the user's agents_repo, or one the user wrote for pi before the link existed. Either
# way it is kept beside the link as <path>.pre-agents-md.
link_agents_file() {
  local user="$1" path="$2" want="${3:-../.agents/AGENTS.md}"
  [[ -L "$path" && "$(readlink "$path")" == "$want" ]] && return 0
  if [[ -e "$path" && ! -L "$path" ]]; then
    runuser -u "$user" -- mv -f "$path" "$path.pre-agents-md" || { log "WARN: could not move $path aside"; return 0; }
  fi
  if runuser -u "$user" -- ln -sfn "$want" "$path"; then log "linked $path -> $want"
  else log "WARN: could not link $path for $user"; fi
  return 0
}

# Pi, the third harness in terminal-lobby since 2026-09-25, reads each user's
# files from ~/.pi/agent. Two links go there, both made as the user:
#
#   extensions/terminal-lobby.js -> $PI_EXTENSION, for every roster user. It
#     reports pi's state to the lobby and appends /etc/pi/org-policy.md to
#     pi's system prompt. Pi skips a dangling link without a word, so the link
#     is made even before the terminal-lobby package has installed the file.
#   AGENTS.md -> ../../.agents/AGENTS.md, for users whose instructions
#     install_user_agents manages, decided by the same test it uses. wizard's
#     comes from his dotfiles instead.
#
# A file a user put in the extension's place is theirs, and so is a link
# pointing outside the terminal-lobby package directory, such as one into a
# checkout they are working on. The one link this replaces is ours: a link into
# that directory that points somewhere other than the current file. The
# AGENTS.md link goes through link_agents_file, like the Claude Code and Codex
# links.
#
# Directories this creates are 0700, because pi keeps its sign-in and session
# transcripts under ~/.pi and would otherwise create it with the umask of
# whatever runs first. Existing directories keep their mode.
# Best-effort tail: must return 0 or set -euo pipefail aborts the whole reconcile.
install_pi_links() {
  local user="$1" home pi ext cur action f
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || return 0
  pi="$home/.pi/agent"; ext="$pi/extensions/terminal-lobby.js"
  for f in "$home/.pi" "$pi" "$pi/extensions"; do
    # Same refusal as install_user_agents: a link here would aim the writes
    # below somewhere else.
    [[ -L "$f" ]] && { log "WARN: $f is a symlink -> pi links for $user skipped"; return 0; }
  done
  if [[ -L "$ext" ]]; then
    cur="$(readlink "$ext")"
    if [[ "$cur" == "$PI_EXTENSION" ]]; then action=current
    elif [[ "$cur" == "${PI_EXTENSION%/*}/"* ]]; then action=repoint
    else action=theirs; fi
  elif [[ -e "$ext" ]]; then action=theirs
  else action=create; fi
  if [[ "$DRY_RUN" == 1 ]]; then
    case "$action" in
      create|repoint) echo "[dry-run] pi extension link ($action) -> $user:$ext" ;;
      theirs) echo "[dry-run] pi extension: $user:$ext is theirs, left alone" ;;
    esac
    if [[ -s "$AGENTS_SRC_DIR/$user.md" ]] \
       && ! [[ -L "$pi/AGENTS.md" && "$(readlink "$pi/AGENTS.md")" == ../../.agents/AGENTS.md ]]; then
      echo "[dry-run] pi AGENTS.md link -> $user:$pi/AGENTS.md"
    fi
    return 0
  fi
  runuser -u "$user" -- sh -c 'umask 077 && mkdir -p "$1"' _ "$pi/extensions" \
    || { log "WARN: could not create $pi/extensions for $user"; return 0; }
  case "$action" in
    create|repoint)
      if runuser -u "$user" -- ln -sfn "$PI_EXTENSION" "$ext"; then log "linked $ext -> $PI_EXTENSION"
      else log "WARN: could not link $ext for $user"; fi ;;
    theirs) log "pi extension: $ext is $user's own, left alone" ;;
  esac
  if [[ -s "$AGENTS_SRC_DIR/$user.md" ]]; then
    link_agents_file "$user" "$pi/AGENTS.md" ../../.agents/AGENTS.md
  fi
  return 0
}

# Pi's starting model, the same one Claude Code starts every user on: Opus 5.5
# at high effort (Viktor, 2026-09-25), which pi calls anthropic/claude-opus-5-5
# at thinking level high. Pi's own default for Anthropic is claude-opus-4-8 at
# medium. Asked for 2026-09-26.
#
# Pi has no machine-wide settings file, only ~/.pi/agent/settings.json and a
# project's .pi/settings.json, so this writes the user's file. IF-ABSENT, as
# install_claude_defaults is: pi writes these keys itself when someone saves a
# choice (a /model pick it persists, a thinking level they set), and that choice
# is theirs. The model and its provider are one choice, written together or not
# at all, so a user's own defaultModel is never paired with our provider.
#
# Runs after install_pi_links, which creates ~/.pi/agent at 0700.
# Best-effort tail: must return 0 or set -euo pipefail aborts the whole reconcile.
install_pi_defaults() {
  local user="$1" home pi added
  home="$(getent passwd "$user" | cut -d: -f6)"
  pi="$home/.pi/agent"
  [[ -n "$home" && -d "$pi" && ! -L "$home/.pi" && ! -L "$pi" ]] || return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] pi defaults (opus 5.5, high) -> $user"; return 0; fi

  added="$(runuser -u "$user" -- sh -c 'umask 077 && exec python3 - "$1"' _ "$pi/settings.json" <<'PYEOF'
import json, os, sys

path = sys.argv[1]
if os.path.islink(path):
    sys.exit(0)
if os.path.exists(path) and os.path.getsize(path) > 0:
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (json.JSONDecodeError, OSError) as e:
        print(f"ERROR: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        sys.exit(0)
else:
    data = {}

added = []
if "defaultModel" not in data and "defaultProvider" not in data:
    data["defaultProvider"] = "anthropic"
    data["defaultModel"] = "claude-opus-5-5"
    added.append("defaultModel")
if "defaultThinkingLevel" not in data:
    data["defaultThinkingLevel"] = "high"
    added.append("defaultThinkingLevel")
if added:
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
    print(" ".join(added))
PYEOF
  )" || { log "WARN: pi defaults failed for $user (retries next reconcile)"; return 0; }

  [[ -n "$added" ]] && log "pi default set -> $user ($added)"
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

  # Runs AS the user, like the memory wiring, so root never writes a file the user
  # controls; umask 077 keeps it 0600 (it holds the per-user MEMORY_API_KEY).
  added="$(runuser -u "$user" -- sh -c 'umask 077 && exec python3 - "$1"' _ "$settings" <<'PYEOF'
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

  runuser -u "$user" -- chmod 600 "$settings" 2>/dev/null || true
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
# The homelab CLI's source tree, for step 0b. A whole directory, so it comes
# out of `git archive` into a temp directory and replaces the last copy only
# once it is complete; a failure keeps the last good tree.
committed_cli() {  # committed_cli <dest>; 0 when dest now holds origin/master's cli/
  local dst="$1" tmp
  tmp="$(mktemp -d "$dst.XXXXXX")" || return 1
  if runuser -u "$clone_owner" -- git -C "$clone_root" "${gitc[@]}" archive --format=tar origin/master cli 2>/dev/null \
       | tar -x -C "$tmp" 2>/dev/null && [[ -s "$tmp/cli/VERSION" ]]; then
    rm -rf "$dst" && mv "$tmp/cli" "$dst" && rm -rf "$tmp" && return 0
  fi
  rm -rf "$tmp"; return 1
}
# Any other directory of the repo, the same way: claude-hooks/ for install_memory.
committed_tree() {  # committed_tree <repo-dir> <dest>; 0 when dest now holds origin/master's copy
  local src="$1" dst="$2" tmp
  tmp="$(mktemp -d "$dst.XXXXXX")" || return 1
  if runuser -u "$clone_owner" -- git -C "$clone_root" "${gitc[@]}" archive --format=tar origin/master "$src" 2>/dev/null \
       | tar -x -C "$tmp" 2>/dev/null && [[ -d "$tmp/$src" ]] && [[ -n "$(ls -A "$tmp/$src")" ]]; then
    rm -rf "$dst" && mv "$tmp/$src" "$dst" && rm -rf "$tmp" && return 0
  fi
  rm -rf "$tmp"; return 1
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
# The rest of what this script deploys comes from origin/master too, so
# nothing it installs depends on the admin's working tree being current. That
# tree was kept current by an hourly `git pull` in wizard's crontab until
# 2026-11-11, when the disposable-devvm plan dropped it. Like cli/ below, these
# are extracted on both passes: the pass that self-deploys a new copy of this
# script skips the fetch above, and a file only the new copy knows about would
# otherwise come from the working tree until the next hourly run.
# origin/master is whatever the last fetch brought, which is committed content
# either way.
committed scripts/workstation/workstation-creds.sh "$STATEDIR/workstation-creds.committed.sh" || true
committed scripts/vault-token-renew.sh "$STATEDIR/vault-token-renew.committed.sh" || true
committed scripts/vault-token-renew.service "$STATEDIR/vault-token-renew.committed.service" || true
committed scripts/vault-token-renew.timer "$STATEDIR/vault-token-renew.committed.timer" || true
committed scripts/tmux-persist.sh "$STATEDIR/tmux-persist.committed.sh" || true
committed scripts/workstation/skel/start-claude.sh "$STATEDIR/start-claude.committed.sh" || true
committed scripts/workstation/stage-chrome-hubs.sh "$STATEDIR/stage-chrome-hubs.committed.sh" || true
committed scripts/workstation/chrome-hubs.json "$STATEDIR/chrome-hubs.committed.json" || true
[[ "$DRY_RUN" == 1 ]] || install -d -m 0755 "$STATEDIR/beads.committed"
for f in metadata.json config.yaml gitignore README.md; do
  committed "scripts/workstation/beads/$f" "$STATEDIR/beads.committed/$f" || true
done
if [[ "$DRY_RUN" != 1 ]]; then
  committed_cli "$STATEDIR/cli.committed" || log "WARN: could not extract cli/ from origin/master"
  committed_tree scripts/workstation/claude-hooks "$STATEDIR/claude-hooks.committed" \
    || log "WARN: could not extract claude-hooks/ from origin/master"
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

# Each user's agent instructions are an input too (fetch_user_agents, step
# 5d-bis): the last good copy of each is $AGENTS_SRC_DIR/<user>.md, and the
# bare fetches they come from are under $AGENTS_FETCH_DIR.
AGENTS_SRC_DIR="$STATEDIR/agents"
AGENTS_FETCH_DIR="$STATEDIR/agent-repos"
# The shared beads facts (install_beads) are an input like the roster. Each of
# the four files falls back to the working tree independently of the others.
BEADS_SRC="$WORKSTATION_DIR/beads"
[[ -s "$STATEDIR/beads.committed/metadata.json" ]] && BEADS_SRC="$STATEDIR/beads.committed"
# The deployed files, each falling back to the working tree on its own.
pick() { if [[ -s "$STATEDIR/$1" ]]; then echo "$STATEDIR/$1"; else echo "$2"; fi; }
CREDS_SRC="$(pick workstation-creds.committed.sh "$WORKSTATION_DIR/workstation-creds.sh")"
VTR_SRC="$(pick vault-token-renew.committed.sh "$WORKSTATION_DIR/../vault-token-renew.sh")"
VTR_SERVICE="$(pick vault-token-renew.committed.service "$WORKSTATION_DIR/../vault-token-renew.service")"
VTR_TIMER="$(pick vault-token-renew.committed.timer "$WORKSTATION_DIR/../vault-token-renew.timer")"
TMUX_PERSIST_SRC="$(pick tmux-persist.committed.sh "$WORKSTATION_DIR/../tmux-persist.sh")"
LAUNCHER_SRC="$(pick start-claude.committed.sh "$WORKSTATION_DIR/skel/start-claude.sh")"
HUBS_SRC="$(pick stage-chrome-hubs.committed.sh "$WORKSTATION_DIR/stage-chrome-hubs.sh")"
HUBS_MAP="$(pick chrome-hubs.committed.json "$WORKSTATION_DIR/chrome-hubs.json")"
HOOKS_SRC="$WORKSTATION_DIR/claude-hooks"
[[ -d "$STATEDIR/claude-hooks.committed" ]] && HOOKS_SRC="$STATEDIR/claude-hooks.committed"

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
    # The fresh copy takes the admin token again at its top. Exported here,
    # into root's own exec, rather than as an env argument, which ps shows.
    [[ -z "$ADMIN_VAULT_TOKEN" ]] || export VAULT_TOKEN="$ADMIN_VAULT_TOKEN"
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
# Built from origin/master's cli/ (extracted in 0a), like the other inputs, and
# from the working tree only until a first extraction succeeds. Building from
# the shared checkout kept /usr/local/bin/homelab on the Oct 21 build until
# 2026-10-30: that checkout fast-forwards only while it is clean, and an
# uncommitted edit to one file held it behind origin/master.
homelab_cli_src() {
  if [[ -s "$STATEDIR/cli.committed/VERSION" ]]; then
    echo "$STATEDIR/cli.committed"
  else
    echo "$WORKSTATION_DIR/../../cli"
  fi
}
build_homelab_cli() {
  local src dst=/usr/local/bin/homelab
  src="$(homelab_cli_src)"
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
  if k8s_raw="$(vault_admin kv get -field=k8s_users secret/platform 2>/dev/null)"; then
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

# 3b) machine-wide org policy (repo -> /etc), for Claude Code, Codex and pi
sync_managed_config
sync_codex_requirements
sync_pi_org_policy
# 3c) machine-wide tmux-persist binary (repo -> /usr/local/bin; units enabled in step 5b)
sync_tmux_persist

# 3d) credentials from Vault for every account that already exists, before the
#     loop below: the admin's restored kubeconfig is what step 4 copies the
#     cluster address into every other user's from, and the restored Git PATs
#     are what their clones authenticate with. Only with an admin Vault token;
#     the hourly run logs one skip line.
for u in $(jq -r '.accounts[].os_user' "$desired_file"); do
  id "$u" >/dev/null 2>&1 && restore_user_credentials "$u"
done
# 3e) the shared Codex login and the chrome hub configs, from Vault when absent
#     (admin token only), before step 4 adds users to codex-shared and step 5c
#     copies each hub config into its home.
stage_shared_auth

# 4) per-account: create-if-absent + ADDITIVE tier groups (never strip) + locked clone
# NB: empty @tsv fields collapse under tab-IFS read (tab is IFS whitespace), so
# the jq below emits "-" for empty groups/repos and we map it back here.
while IFS=$'\t' read -r os_user tier shell groups_csv code_layout repos_csv claude_auth dotfiles; do
  [[ "$groups_csv" == "-" ]] && groups_csv=""
  [[ "$repos_csv" == "-" ]] && repos_csv=""
  if ! id "$os_user" >/dev/null 2>&1; then
    log "create account: $os_user (shell $shell)"
    run useradd -m -s "$shell" "$os_user"
    run passwd -l "$os_user"           # SSO/t3 only — no local password
    run chmod 700 "/home/$os_user"
    restore_user_credentials "$os_user"    # an existing account was done in 3d
  fi
  install_user_dotfiles "$os_user" "$dotfiles"
  [[ "$tier" == admin ]] && install_admin_infra_clone "$os_user"
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
        hoist_nested_repo  "$os_user" "${repo##*/}"
        install_user_repo  "$os_user" "$repo"
        refresh_user_clone "$os_user" "code/${repo##*/}"
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
  install_vault_token_renew "$os_user"       # every user vault-token-renew.sh has a token scope for
done < <(jq -r '.accounts[] | [.os_user, .tier, .shell, (if (.groups|length)==0 then "-" else (.groups|join(",")) end), .code_layout, (if (.repos|length)==0 then "-" else (.repos|join(",")) end), (.claude_auth|tostring), (.dotfiles // "-")] | @tsv' "$desired_file")

# --- session-store (disposable devvm, 2026-11-11) ---
# 4a) agent state from the session store. On a rebuilt box, each user's
# ~/.claude and ~/.codex come back from the claude-sessions ClickHouse once,
# here, before step 5 starts their T3 serve and before the ingest takes the
# user on (it waits for this step's marker). `restore --rebuild` writes as the
# user through runuser and tar --skip-old-files, then records the restored
# files in the ingest state as already sent. A user this box already ingests,
# such as everyone on the live devvm, gets only the marker; every later pass is
# a no-op that does not touch the database. A failure leaves no marker, so the
# next pass tries again (docs/runbooks/restore-claude-sessions.md).
restore_agent_state() {  # restore_agent_state USER
  local user="$1" out bin="${HOMELAB_BIN:-/usr/local/bin/homelab}"
  [[ -x "$bin" ]] || { log "WARN: no $bin -> agent state restore skipped for $user"; return 0; }
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] restore ~/.claude and ~/.codex from the session store -> $user"; return 0; fi
  if out="$("$bin" claude-sessions restore --user "$user" --rebuild 2>&1)"; then
    grep -q 'already restored' <<<"$out" || while IFS= read -r l; do log "$user: $l"; done <<<"$out"
  else
    log "WARN: agent state restore failed for $user: $(tail -n 1 <<<"$out")"
  fi
}
for u in $(jq -r '.accounts[].os_user' "$desired_file"); do
  id "$u" >/dev/null 2>&1 && restore_agent_state "$u"
done
# --- end session-store ---

# --- emo-jobs (disposable devvm, 2026-11-11) ---
# 4b) a roster repo's own devvm setup. A workspace repo may ship devvm-setup.sh
# at its root: the steps that put back what the user built around the clone by
# hand, such as ~/bin links and systemd user units. emo's
# ebarzin/vermont-device-configs restores the B4 intercom watchdog this way
# (docs/runbooks/cameras-nvr-intercom.md). It runs AS the user on every
# reconcile, so it must be idempotent and print nothing when nothing changed.
# The environment is emptied first: a rebuild runs this script with an admin
# VAULT_TOKEN (step 3d), and the user's own code must never see it. Linger is
# turned on so the user's timers fire while they are logged out.
run_repo_setup() {  # run_repo_setup USER SUBPATH
  local user="$1" sub="$2" home="" uid="" f out
  IFS=: read -r _ _ uid _ _ home _ < <(getent passwd "$user") || return 0
  [[ -n "$home" && -n "$uid" ]] || return 0
  f="$home/$sub/devvm-setup.sh"
  [[ -f "$f" ]] || return 0
  if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] run ~/$sub/devvm-setup.sh as $user"; return 0; fi
  [[ "$(loginctl show-user "$user" -p Linger 2>/dev/null)" == "Linger=yes" ]] || loginctl enable-linger "$user" >/dev/null 2>&1 || true
  if out="$(timeout 300 runuser -u "$user" -- env -i HOME="$home" USER="$user" LOGNAME="$user" \
        PATH=/usr/local/bin:/usr/bin:/bin XDG_RUNTIME_DIR="/run/user/$uid" bash "$f" 2>&1)"; then
    [[ -z "$out" ]] || log "$user ~/$sub/devvm-setup.sh: $(tail -n 1 <<<"$out")"
  else
    log "WARN: ~/$sub/devvm-setup.sh failed for $user: $(tail -n 1 <<<"$out")"
  fi
}
while IFS=$'\t' read -r os_user repos_csv; do
  IFS=',' read -ra extra_repos <<< "$repos_csv"
  for repo in "${extra_repos[@]}"; do
    [[ -n "$repo" && "$repo" != "-" ]] || continue
    run_repo_setup "$os_user" "code/${repo##*/}"
  done
done < <(jq -r '.accounts[] | select(.tier != "admin" and .code_layout == "workspace") | [.os_user, (if (.repos|length)==0 then "-" else (.repos|join(",")) end)] | @tsv' "$desired_file")
# --- end emo-jobs ---

# --- t3-snapshot (disposable devvm, 2026-11-11) ---
# t3_restore_before_serve USER: on a rebuilt devvm, put the user's newest T3
# snapshot back before the serve first starts (scripts/t3-restore-state.sh).
# --if-missing is a no-op for anyone who already has a database. Returns 1
# when the restore says hold (exit 3: the first-boot build could not copy the
# snapshots and this user has none yet), so the caller skips starting an empty
# T3 for them; the next hourly run tries again. Tests:
# scripts/t3-restore-state.test.sh.
t3_restore_before_serve() {
  local u="$1" bin="${T3_RESTORE_BIN:-/usr/local/bin/t3-restore-state}" rc=0
  [[ -x "$bin" ]] || return 0
  run "$bin" --if-missing "$u" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) log "t3-serve held for $u: waiting for the T3 snapshots (docs/architecture/backup-dr.md, T3 snapshots)"; return 1 ;;
    *) log "WARN: t3-restore-state failed for $u (rc=$rc)"; return 0 ;;
  esac
}
# --- end t3-snapshot ---

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
  # --- t3-snapshot (disposable devvm, 2026-11-11) ---
  if id "$os_user" >/dev/null 2>&1 && ! t3_restore_before_serve "$os_user"; then continue; fi
  # --- end t3-snapshot ---
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
#     harness links, for users whose roster row names an agents_repo: fetched from
#     that repo's master first, keeping the last good copy when the fetch fails.
#     Retires the old shared rules in every home that has its own file. Personal
#     slot created once, never rewritten. Pruned first, so a user whose
#     agents_repo was removed is not installed again this run.
prune_user_agents "$(jq -r '.accounts[] | select(.agents_repo != null) | .os_user' "$desired_file")"
while IFS=$'\t' read -r os_user agents_repo; do
  id "$os_user" >/dev/null 2>&1 || continue
  [[ "$agents_repo" == "-" ]] || fetch_user_agents "$os_user" "$agents_repo"
  install_user_agents "$os_user"
done < <(jq -r '.accounts[] | [.os_user, (.agents_repo // "-")] | @tsv' "$desired_file")

# 5d-quinquies) pi's per-user links (ALL users): terminal-lobby's extension in
#     ~/.pi/agent/extensions, and ~/.pi/agent/AGENTS.md for the users 5d-bis
#     manages. Runs after 5d-bis so the file that link points at is in place.
#     Then pi's starting model and thinking level, written once per key.
while IFS=$'\t' read -r os_user; do
  id "$os_user" >/dev/null 2>&1 || continue
  install_pi_links "$os_user"
  install_pi_defaults "$os_user"
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
