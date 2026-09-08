#!/usr/bin/env bash
# /etc/ttyd-user-map carries comment lines, and rows may append a :<cwd>.
# Comments must not fall through as bogus users — they now reach path-building
# code (snapshot dirs, tombstone files), not just an `id -u` that rejects them.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== the user map yields only real os users =="

cat > "$TMUX_PERSIST_MAP" <<EOF
# Generated from roster.yaml by roster_engine.py — DO NOT EDIT BY HAND.
# <authentik_user>=<os_user>; consumed by t3-dispatch.
vbarzin=$TEST_USER
emil.barzin=someone
ancaelena98=pinned:/home/pinned/code

EOF

got="$(bash "$SCRIPT_UNDER_TEST" history 2>&1 | grep -oE '^\[[a-z_][a-z0-9_-]*\]|^== [a-z_][a-z0-9_-]* ' | tr -d '[]=' | tr -d ' ' | sort -u | tr '\n' ' ')"

assert_contains "$got" "$TEST_USER" "a plain row yields its os user"
assert_contains "$got" "someone"    "a second row yields its os user"
assert_contains "$got" "pinned"     "a row with a :cwd suffix yields just the user"
assert_not_contains "$got" "Generated" "the comment header is not a user"
assert_not_contains "$got" "consumed"  "the second comment line is not a user"
assert_not_contains "$got" "os_user"   "the placeholder in the comment is not a user"

# An unknown selector is still refused rather than silently matching a comment.
out="$(tp snapshots "not-a-user" 2>&1)"; rc=$?
assert_eq "$rc" "2" "an unknown user is refused"
assert_contains "$out" "not a known terminal user" "the refusal says why"

finish
