#!/usr/bin/env bash
# Checks run_repo_setup in t3-provision-users.sh: a roster repo that ships
# devvm-setup.sh at its root gets it run as the user after the clone, so a
# rebuilt devvm puts back what the user built around the clone by hand (emo's
# ebarzin/vermont-device-configs restores the B4 intercom watchdog this way;
# docs/plans/2026-11-11-disposable-devvm.md).
#
# Run: bash scripts/test-t3-provision-repo-setup.sh
#
# Pulls the function out of the script by name and runs it against a temp home,
# with stand-ins for runuser, getent and loginctl that record what they did.
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
eval "$(extract run_repo_setup)"
declare -F run_repo_setup >/dev/null || { echo "FAIL: run_repo_setup not found in $SCRIPT"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/emo/code/vermont-device-configs" "$tmp/home/emo/code/tv"
CALLS="$tmp/calls"; : > "$CALLS"
export CALLS FAKE_HOME="$tmp/home/emo"
cat > "$tmp/bin/runuser" <<'EOF'
#!/usr/bin/env bash
echo "runuser $*" >> "$CALLS"
[[ "$1" == -u ]] && shift 2
[[ "$1" == -- ]] && shift
exec "$@"
EOF
cat > "$tmp/bin/getent" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "passwd emo" ]] && { echo "emo:x:1001:1001::$FAKE_HOME:/bin/bash"; exit 0; }
exit 2
EOF
cat > "$tmp/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
echo "loginctl $*" >> "$CALLS"
[[ "$1" == show-user ]] && echo "Linger=${FAKE_LINGER:-no}"
exit 0
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
LOG="$tmp/log"
log() { echo "$*" >> "$LOG"; }
logged() { grep -qF -- "$1" "$LOG"; }
DRY_RUN=0

repo="$tmp/home/emo/code/vermont-device-configs"
# The hook records the environment it was given and where it ran.
cat > "$repo/devvm-setup.sh" <<'EOF'
env > "$HOME/hook-env"
echo "restored 2 units"
EOF

# --- a repo without devvm-setup.sh is left alone ----------------------------
: > "$LOG"; : > "$CALLS"
ok "no hook still returns 0" run_repo_setup emo code/tv
eq "no hook runs nothing as the user" "" "$(grep -c runuser "$CALLS" | grep -v '^0$')"
eq "no hook turns on no linger" "" "$(grep enable-linger "$CALLS")"

# --- an unknown account is skipped ------------------------------------------
ok "an unknown user returns 0" run_repo_setup nobody-here code/vermont-device-configs
eq "an unknown user runs nothing" "" "$(grep runuser "$CALLS")"

# --- the hook runs as the user, with an emptied environment ------------------
: > "$LOG"; : > "$CALLS"
export VAULT_TOKEN=hvs.admin-token-must-not-leak
ok "the hook run returns 0" run_repo_setup emo code/vermont-device-configs
ok "it runs as the user" grep -q '^runuser -u emo -- ' "$CALLS"
ok "the hook ran" test -s "$tmp/home/emo/hook-env"
no "the admin VAULT_TOKEN never reaches the user's code" grep -q VAULT_TOKEN "$tmp/home/emo/hook-env"
ok "HOME is the user's home" grep -qx "HOME=$tmp/home/emo" "$tmp/home/emo/hook-env"
ok "USER is the user" grep -qx "USER=emo" "$tmp/home/emo/hook-env"
ok "XDG_RUNTIME_DIR names the user's runtime dir, so systemctl --user works" grep -qx "XDG_RUNTIME_DIR=/run/user/1001" "$tmp/home/emo/hook-env"
ok "PATH reaches /usr/local/bin (homelab)" grep -q '^PATH=/usr/local/bin:' "$tmp/home/emo/hook-env"
ok "its last line is logged" logged "emo ~/code/vermont-device-configs/devvm-setup.sh: restored 2 units"
ok "linger is turned on so the user's timers fire logged out" grep -q '^loginctl enable-linger emo' "$CALLS"
unset VAULT_TOKEN

# --- linger already on: not asked again -------------------------------------
: > "$CALLS"
FAKE_LINGER=yes run_repo_setup emo code/vermont-device-configs
eq "linger already on is left alone" "" "$(grep enable-linger "$CALLS")"

# --- a quiet hook logs nothing (the hourly run stays quiet on a set-up box) --
: > "$LOG"
printf 'exit 0\n' > "$repo/devvm-setup.sh"
run_repo_setup emo code/vermont-device-configs
eq "a hook with no output logs nothing" "" "$(cat "$LOG")"

# --- a failing hook is a WARN, never an abort --------------------------------
: > "$LOG"
printf 'echo "first"\necho "boom: no sdk" >&2\nexit 3\n' > "$repo/devvm-setup.sh"
ok "a failing hook still returns 0" run_repo_setup emo code/vermont-device-configs
ok "the failure is logged with its last line" logged "WARN: ~/code/vermont-device-configs/devvm-setup.sh failed for emo: boom: no sdk"

# --- dry run runs nothing ----------------------------------------------------
: > "$CALLS"
out="$(DRY_RUN=1 run_repo_setup emo code/vermont-device-configs)"
eq "dry run says what it would do" "[dry-run] run ~/code/vermont-device-configs/devvm-setup.sh as emo" "$out"
eq "dry run runs nothing" "" "$(cat "$CALLS")"

# --- the reconcile calls it for every workspace repo of a non-admin ----------
ok "the reconcile loops run_repo_setup over the roster repos" \
  grep -qE 'run_repo_setup +"\$os_user" +"code/\$\{repo##\*/\}"' "$SCRIPT"

echo "pass=$pass fail=$fail"
(( fail == 0 ))
