#!/usr/bin/env bash
# Checks how t3-provision-users.sh sources each user's agent instructions and
# wizard's beads files.
#
# Run: bash scripts/test-t3-provision-agents.sh
#
# Since 2026-11-03 each user's AGENTS.md is the root file of their own private
# Forgejo repo (roster `agents_repo`), read from that repo's committed master.
# Before that, the files sat together in wizard's ~/code monorepo, which was
# dissolved; so did the beads metadata the provisioner copied into every
# user's ~/code/.beads. This pulls the functions out of the script by name and
# runs them against throwaway repositories, with a runuser stand-in that just
# runs the command.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/t3-provision-users.sh"

pass=0 fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want [$2] got [$3])"; fi; }
ok() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail+1)); echo "FAIL: $1"; else pass=$((pass+1)); fi; }

extract() {  # the text of one top-level function, from its name to its closing brace
  awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$SCRIPT"
}
for fn in mkdir_as write_as repo_url fetch_user_agents prune_user_agents install_admin_beads install_beads point_user_beads; do
  eval "$(extract "$fn")"
  declare -F "$fn" >/dev/null || { echo "FAIL: $fn not found in $SCRIPT"; exit 1; }
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\n[[ "$1" == -u ]] && shift 2\n[[ "$1" == -- ]] && shift\nexec "$@"\n' > "$tmp/bin/runuser"
chmod +x "$tmp/bin/runuser"
export PATH="$tmp/bin:$PATH"
LOG="$tmp/log"
log() { echo "$*" >> "$LOG"; }
logged() { grep -qF -- "$1" "$LOG"; }

g() { git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=master "$@" >/dev/null 2>&1; }

DRY_RUN=0
clone_owner="$(id -un)"
FORGEJO_BASE="$tmp/forgejo"
REPO_REMOTE_BASE="$FORGEJO_BASE/viktor"
STATEDIR="$tmp/state"; mkdir -p "$STATEDIR"
AGENTS_SRC_DIR="$STATEDIR/agents"
AGENTS_FETCH_DIR="$STATEDIR/agent-repos"

# --- repo_url: `name` is viktor/<name>, `owner/name` is that repo -----------
eq "a plain name is under viktor/" "$FORGEJO_BASE/viktor/tv.git" "$(repo_url tv)"
eq "owner/name is that repo" "$FORGEJO_BASE/ebarzin/agents.git" "$(repo_url ebarzin/agents)"

# --- fetch_user_agents ------------------------------------------------------
# "Forgejo": ebarzin/agents with v1 on master. Its working tree is then made
# dirty and a second branch carries other text; neither may be installed.
origin="$FORGEJO_BASE/ebarzin/agents.git"
g init -q "$origin"
printf '# emo v1\nline\n' > "$origin/AGENTS.md"
g -C "$origin" add AGENTS.md; g -C "$origin" commit -qm v1
g -C "$origin" checkout -qb draft
echo '# draft' > "$origin/AGENTS.md"; g -C "$origin" commit -qam draft
g -C "$origin" checkout -q master
echo '# uncommitted edit' > "$origin/AGENTS.md"

: > "$LOG"
ok "fetch succeeds" fetch_user_agents emo ebarzin/agents
ok "the file is master's AGENTS.md, byte for byte" cmp -s "$AGENTS_SRC_DIR/emo.md" <(git -C "$origin" show master:AGENTS.md)
ok "the journal names the repo and commit" logged "agent instructions for emo: ebarzin/agents master ($(git -C "$origin" rev-parse --short master))"
eq "the cached copy is root-only" 700 "$(stat -c %a "$AGENTS_SRC_DIR")"
eq "the fetch directory is closed to others" 700 "$(stat -c %a "$AGENTS_FETCH_DIR")"
eq "the fetch directory belongs to the checkout owner" "$clone_owner" "$(stat -c %U "$AGENTS_FETCH_DIR")"
ok "the fetch is a bare repository" test -f "$AGENTS_FETCH_DIR/emo.git/HEAD"

# A new commit on master arrives on the next run.
printf '# emo v2\n' > "$origin/AGENTS.md"; g -C "$origin" commit -qam v2
fetch_user_agents emo ebarzin/agents
eq "a new master commit arrives" '# emo v2' "$(cat "$AGENTS_SRC_DIR/emo.md")"

# Fail safe: an unreachable repo keeps the last good copy and says so.
: > "$LOG"
mv "$origin" "$origin.away"
ok "a failed fetch still returns 0" fetch_user_agents emo ebarzin/agents
eq "a failed fetch keeps the last good copy" '# emo v2' "$(cat "$AGENTS_SRC_DIR/emo.md")"
ok "a failed fetch is logged" logged "WARN: fetch of ebarzin/agents failed -> agent instructions for emo unchanged"
mv "$origin.away" "$origin"

# Fail safe: a master without AGENTS.md keeps the last good copy too.
: > "$LOG"
g -C "$origin" rm -q AGENTS.md; g -C "$origin" commit -qm gone
ok "a master without the file still returns 0" fetch_user_agents emo ebarzin/agents
eq "a master without the file keeps the last good copy" '# emo v2' "$(cat "$AGENTS_SRC_DIR/emo.md")"
ok "a missing file is logged" logged "WARN: no AGENTS.md on ebarzin/agents master"
ok "no temp file is left behind" test -z "$(find "$AGENTS_SRC_DIR" -name '*.tmp')"

# Dry run fetches nothing and writes nothing.
DRY_RUN=1
out="$(fetch_user_agents anca anca/agents)"
eq "dry run only reports" "[dry-run] fetch agent instructions for anca from anca/agents master" "$out"
no "dry run creates no fetch" test -e "$AGENTS_FETCH_DIR/anca.git"
DRY_RUN=0

# --- prune_user_agents --------------------------------------------------------
echo old > "$AGENTS_SRC_DIR/ancamilea.md"
mkdir -p "$AGENTS_FETCH_DIR/ancamilea.git"
: > "$LOG"
prune_user_agents "emo"
no "a user without agents_repo loses the cached copy" test -e "$AGENTS_SRC_DIR/ancamilea.md"
no "a user without agents_repo loses the fetch" test -e "$AGENTS_FETCH_DIR/ancamilea.git"
ok "a managed user keeps the cached copy" test -s "$AGENTS_SRC_DIR/emo.md"
ok "a managed user keeps the fetch" test -d "$AGENTS_FETCH_DIR/emo.git"
ok "pruning is logged" logged "agent instructions no longer managed for ancamilea"
prune_user_agents ""
no "an empty managed list drops everything" test -e "$AGENTS_SRC_DIR/emo.md"

# --- install_admin_beads --------------------------------------------------------
BEADS_SRC="$DIR/workstation/beads"
home="$tmp/home"; mkdir -p "$home/code"
: > "$LOG"
install_admin_beads "$home"
ok "metadata.json is the committed copy" cmp -s "$BEADS_SRC/metadata.json" "$home/code/.beads/metadata.json"
ok "config.yaml is the committed copy" cmp -s "$BEADS_SRC/config.yaml" "$home/code/.beads/config.yaml"
ok "gitignore is installed as .gitignore" cmp -s "$BEADS_SRC/gitignore" "$home/code/.beads/.gitignore"
ok "README.md is the committed copy" cmp -s "$BEADS_SRC/README.md" "$home/code/.beads/README.md"
eq "bd still points at the shared Dolt server" "10.0.20.200 3306 code" \
  "$(jq -r '[.dolt_server_host, .dolt_server_port, .dolt_database] | join(" ")' "$home/code/.beads/metadata.json")"
eq "the files are not world-readable" 640 "$(stat -c %a "$home/code/.beads/metadata.json")"

# bd's runtime files are left alone and an unchanged file is not rewritten.
echo 3306 > "$home/code/.beads/dolt-server.port"
: > "$LOG"
install_admin_beads "$home"
eq "a second run changes nothing" "" "$(cat "$LOG")"
eq "runtime files are left alone" 3306 "$(cat "$home/code/.beads/dolt-server.port")"

# A drifted file is put back.
echo '{}' > "$home/code/.beads/metadata.json"
install_admin_beads "$home"
ok "a drifted metadata.json is restored" cmp -s "$BEADS_SRC/metadata.json" "$home/code/.beads/metadata.json"

# A symlinked .beads is refused rather than followed.
mkdir -p "$tmp/elsewhere" "$tmp/home2/code"; ln -s "$tmp/elsewhere" "$tmp/home2/code/.beads"
: > "$LOG"
install_admin_beads "$tmp/home2"
ok "a symlinked .beads is refused" logged "is a symlink"
eq "nothing is written through the link" "" "$(ls -A "$tmp/elsewhere")"

# --- install_beads for a non-admin ----------------------------------------------
# A workspace-layout user's bd config is in their infra clone, which infra
# tracks with a local-project default. It is pointed at the shared server and
# project; their other keys stay. ~/code/.beads is not created.
getent() { echo "emo:x:1:1::$tmp/emo:/bin/sh"; }
mkdir -p "$tmp/emo/code/infra/.beads"
printf '{"database":"dolt","backend":"dolt","dolt_mode":"server","dolt_server_host":"127.0.0.1","dolt_server_port":23209,"dolt_database":"in","project_id":"local"}' \
  > "$tmp/emo/code/infra/.beads/metadata.json"
git init -q "$tmp/emo/code/infra"
: > "$LOG"
install_beads emo
m="$tmp/emo/code/infra/.beads/metadata.json"
eq "the infra clone's bd points at the shared server" \
  "$(jq -r '[.dolt_server_host, .dolt_server_port, .dolt_database, .project_id] | join(" ")' "$BEADS_SRC/metadata.json")" \
  "$(jq -r '[.dolt_server_host, .dolt_server_port, .dolt_database, .project_id] | join(" ")' "$m")"
eq "the user's other keys stay" dolt "$(jq -r .database "$m")"
no "~/code/.beads is not created" test -e "$tmp/emo/code/.beads"
eq "bd gets the contributor role in that clone" contributor "$(git -C "$tmp/emo/code/infra" config beads.role)"
ok "the journal names the directory" logged "beads pointed at the shared Dolt server -> emo:$tmp/emo/code/infra"
before="$(sha256sum < "$m")"; install_beads emo
eq "a correct file is left byte-identical" "$before" "$(sha256sum < "$m")"
unset -f getent

echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
