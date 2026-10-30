#!/usr/bin/env bash
# Checks that t3-provision-users.sh builds the homelab CLI from origin/master's
# cli/, not from the admin's working tree.
#
# Run: bash scripts/test-t3-provision-homelab-cli.sh
#
# Step 0b used to hash and build $WORKSTATION_DIR/../../cli, the shared main
# checkout. That checkout fast-forwards only while it is clean, and an
# uncommitted edit to one file kept it behind origin/master from 2026-10-29 to
# 2026-10-30, so /usr/local/bin/homelab stayed on the Oct 21 build and kept
# sending `homelab claim` to a presence path emo does not have. Like the other
# 0a inputs, cli/ now comes from origin/master. This pulls the two functions out
# of the script by name and runs them against a throwaway repository, with a
# runuser stand-in that just runs the command.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/t3-provision-users.sh"

pass=0 fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want [$2] got [$3])"; fi; }
ok() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

extract() {  # the text of one top-level function, from its name to its closing brace
  awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$SCRIPT"
}
eval "$(extract committed_cli)"
eval "$(extract homelab_cli_src)"
declare -F committed_cli >/dev/null || { echo "FAIL: committed_cli not found"; exit 1; }
declare -F homelab_cli_src >/dev/null || { echo "FAIL: homelab_cli_src not found"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\n[[ "$1" == -u ]] && shift 2\n[[ "$1" == -- ]] && shift\nexec "$@"\n' > "$tmp/bin/runuser"
chmod +x "$tmp/bin/runuser"
export PATH="$tmp/bin:$PATH"

g() { git -c user.email=t@example.invalid -c user.name=t "$@" >/dev/null 2>&1; }
# "origin": master has cli/ at v2. The admin clone fetched it but its working
# tree is still on v1 and carries an uncommitted edit.
g init -q -b master "$tmp/origin"
mkdir -p "$tmp/origin/cli/bridge" "$tmp/origin/scripts/workstation"
echo v1 > "$tmp/origin/cli/VERSION"; echo 'package main // v1' > "$tmp/origin/cli/main.go"
echo bridge > "$tmp/origin/cli/bridge/go.mod"; echo '{}' > "$tmp/origin/scripts/workstation/managed-settings.json"
g -C "$tmp/origin" add -A; g -C "$tmp/origin" commit -qm v1
g clone -q "$tmp/origin" "$tmp/clone"
echo v2 > "$tmp/origin/cli/VERSION"; echo 'package main // v2' > "$tmp/origin/cli/main.go"
g -C "$tmp/origin" commit -qam v2
g -C "$tmp/clone" fetch -q origin master
echo 'dirty' > "$tmp/clone/scripts/workstation/managed-settings.json"

clone_root="$tmp/clone" clone_owner="$(id -un)"
gitc=(-c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false)
STATEDIR="$tmp/state"; mkdir -p "$STATEDIR"
WORKSTATION_DIR="$tmp/clone/scripts/workstation"

eq "before 0a runs, 0b falls back to the working tree" "$WORKSTATION_DIR/../../cli" "$(homelab_cli_src)"
ok "committed_cli extracts origin/master's cli/" committed_cli "$STATEDIR/cli.committed"
eq "VERSION is origin/master's" v2 "$(cat "$STATEDIR/cli.committed/VERSION")"
eq "sources are origin/master's" 'package main // v2' "$(cat "$STATEDIR/cli.committed/main.go")"
ok "the nested bridge module comes along" test -s "$STATEDIR/cli.committed/bridge/go.mod"
eq "0b builds from the committed tree" "$STATEDIR/cli.committed" "$(homelab_cli_src)"

# A second extraction replaces the first, including files origin deleted.
touch "$STATEDIR/cli.committed/stale.go"
ok "re-extraction succeeds" committed_cli "$STATEDIR/cli.committed"
ok "a file no longer on origin/master is gone" test ! -e "$STATEDIR/cli.committed/stale.go"

# A failed extraction keeps the last good tree.
clone_root="$tmp/nowhere"
if committed_cli "$STATEDIR/cli.committed"; then fail=$((fail+1)); echo "FAIL: extraction from a missing clone should fail"; else pass=$((pass+1)); fi
eq "the last good tree stays" v2 "$(cat "$STATEDIR/cli.committed/VERSION")"
ok "no temp directories are left behind" test -z "$(find "$STATEDIR" -maxdepth 1 -name 'cli.committed.*')"

echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
