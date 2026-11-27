#!/usr/bin/env bash
# Checks wire_infra_hooks in t3-provision-users.sh: every infra clone on the
# devvm runs the tracked hooks in .githooks (the git-crypt guard, then the
# clone's own .git/hooks), through core.hooksPath.
#   - set to the clone's absolute .githooks, so a worktree on an older branch
#     still runs them
#   - set only once the checkout has .githooks/pre-commit: an older checkout
#     would otherwise run no hooks at all, gitleaks included
#   - a hooksPath the user chose is left alone, with a WARN
#   - idempotent, and a dry run changes nothing
#
# Run: bash scripts/test-t3-provision-infra-hooks.sh
# Pulls the function out of the script by name and runs it against a temp
# home, with a stand-in for runuser. Needs git.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/t3-provision-users.sh"

pass=0 fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want [$2] got [$3])"; fi; }
ok() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail+1)); echo "FAIL: $1"; else pass=$((pass+1)); fi; }

extract() {
  awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$SCRIPT"
}
eval "$(extract wire_infra_hooks)"
declare -F wire_infra_hooks >/dev/null || { echo "FAIL: wire_infra_hooks not found in $SCRIPT"; exit 1; }
# t3-provision-users.sh runs under `set -euo pipefail`, so every call here
# does too: an unset hooksPath (git config exits 1) once stopped the whole
# hourly run.
# A new bash process, since `set -e` is ignored inside an `if` or `!` context.
wire() {
  bash -euo pipefail -c "$(declare -f wire_infra_hooks log getent)
    DRY_RUN=$DRY_RUN LOG='$LOG' TEST_HOME='$TEST_HOME' me='$me'
    wire_infra_hooks \"\$@\"" _ "$@"
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/runuser" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -u ]] && shift 2
[[ "$1" == -- ]] && shift
exec "$@"
EOF
chmod +x "$tmp/bin/runuser"
export PATH="$tmp/bin:$PATH"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
LOG="$tmp/log"; : > "$LOG"
log() { echo "$*" >> "$LOG"; }
logged() { grep -qF -- "$1" "$LOG"; }
DRY_RUN=0
me="$(id -un)"
home="$tmp/home"; mkdir -p "$home/code"
TEST_HOME="$home"
getent() { echo "$me:x:$(id -u):$(id -g)::$TEST_HOME:/bin/sh"; }
dst="$home/code/infra"
hooks_path() { git -C "$dst" config --get core.hooksPath; }

# --- no clone: nothing to do --------------------------------------------------------
wire "$me" code/infra
eq "no clone: nothing logged" "" "$(cat "$LOG")"

# --- a checkout from before .githooks existed ----------------------------------------
git init -q -b master "$dst"
ok "no .githooks yet: returns 0 under set -e" wire "$me" code/infra
eq "no .githooks yet: hooksPath stays unset" "" "$(hooks_path)"

# --- the checkout has the hooks -----------------------------------------------------
mkdir -p "$dst/.githooks"; printf '#!/bin/sh\n' > "$dst/.githooks/pre-commit"; chmod +x "$dst/.githooks/pre-commit"
DRY_RUN=1
eq "dry run only reports" "[dry-run] core.hooksPath -> $me:$dst/.githooks" "$(wire "$me" code/infra)"
DRY_RUN=0
eq "dry run changes nothing" "" "$(hooks_path)"
ok "an unset hooksPath returns 0 under set -e" wire "$me" code/infra
eq "set to the clone's absolute .githooks" "$dst/.githooks" "$(hooks_path)"
ok "and logged" logged "set $me:~/code/infra core.hooksPath -> $dst/.githooks"

: > "$LOG"
wire "$me" code/infra
eq "a second run changes and logs nothing" "" "$(cat "$LOG")"

# --- a hooksPath the user chose -------------------------------------------------------
git -C "$dst" config core.hooksPath /somewhere/else
wire "$me" code/infra
eq "a user's own hooksPath is left alone" "/somewhere/else" "$(hooks_path)"
ok "with a WARN" logged "WARN: $me:~/code/infra core.hooksPath is /somewhere/else"

# --- the single layout: ~/code is the clone ---------------------------------------------
rm -rf "$dst"; git init -q -b master "$home/code"
mkdir -p "$home/code/.githooks"; cp "$tmp/bin/runuser" "$home/code/.githooks/pre-commit"
wire "$me" code
eq "single layout: set to ~/code/.githooks" "$home/code/.githooks" "$(git -C "$home/code" config --get core.hooksPath)"

echo "t3-provision infra hooks: $pass passed, $fail failed"
(( fail == 0 ))
