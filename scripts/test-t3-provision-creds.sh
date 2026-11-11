#!/usr/bin/env bash
# Checks the three steps t3-provision-users.sh runs so a rebuilt devvm gets each
# user's own state back (docs/plans/2026-11-11-disposable-devvm.md):
#   restore_user_credentials  the Vault-held credential files (workstation-creds)
#   install_vault_token_renew the renewer, its user units and a first token
#   install_user_dotfiles     chezmoi init --apply from the roster's dotfiles repo
#
# Run: bash scripts/test-t3-provision-creds.sh
#
# Pulls the functions out of the script by name and runs them against a temp
# home, with stand-ins for runuser, vault, systemctl, loginctl, curl and
# getent that record what they were asked to do.
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
for fn in mkdir_as write_as repo_url restore_user_credentials install_vault_token_renew install_user_dotfiles; do
  eval "$(extract "$fn")"
  declare -F "$fn" >/dev/null || { echo "FAIL: $fn not found in $SCRIPT"; exit 1; }
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
CALLS="$tmp/calls"; : > "$CALLS"
export CALLS
printf '#!/usr/bin/env bash\n[[ "$1" == -u ]] && shift 2\n[[ "$1" == -- ]] && shift\nexec "$@"\n' > "$tmp/bin/runuser"
cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS"
[[ "$*" == *is-enabled* ]] && exit 1
exit 0
EOF
cat > "$tmp/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
echo "loginctl $*" >> "$CALLS"
[[ "$1" == show-user ]] && echo "Linger=no"
exit 0
EOF
cat > "$tmp/bin/vault" <<'EOF'
#!/usr/bin/env bash
echo "vault $*" >> "$CALLS"
[[ -n "${FAKE_VAULT_DENY:-}" ]] && exit 2
[[ "$1 $2" == "token lookup" ]] && exit 0
[[ "$1 $2" == "token create" ]] && { echo "s.minted-token"; exit 0; }
exit 0
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS"
# the chezmoi installer: writes a fake binary where -b says
cat <<'SH'
while [ $# -gt 0 ]; do case "$1" in -b) b="$2"; shift;; esac; shift; done
mkdir -p "$b"; printf '#!/bin/sh\necho "chezmoi $*" >> "$CALLS"\nmkdir -p "$HOME/.local/share/chezmoi"\n' > "$b/chezmoi"; chmod +x "$b/chezmoi"
SH
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

LOG="$tmp/log"; : > "$LOG"
log() { echo "$*" >> "$LOG"; }
logged() { grep -qF -- "$1" "$LOG"; }
home="$tmp/home"; mkdir -p "$home"
TEST_HOME="$home"
getent() { echo "u:x:$(id -u):$(id -g)::$TEST_HOME:/bin/sh"; }
DRY_RUN=0
FORGEJO_BASE="https://forgejo.example.invalid"
CHEZMOI_VERSION=v2.69.3
me="$(id -un)"

# --- restore_user_credentials ------------------------------------------------
CREDS_SRC="$tmp/creds.sh"
printf '#!/usr/bin/env bash\necho "creds $*" >> "$CALLS"\necho "workstation-creds: $2 restored 3, kept 0, skipped 0"\n' > "$CREDS_SRC"
FAKE_VAULT_DENY=1 restore_user_credentials "$me"
FAKE_VAULT_DENY=1 restore_user_credentials other
no "without a Vault token nothing is restored" grep -q '^creds ' "$CALLS"
eq "the skip is logged once per run, not per user" "1" "$(grep -c 'credential restore skipped' "$LOG")"
unset CREDS_NO_VAULT_LOGGED
restore_user_credentials "$me"
ok "with a Vault token it restores that user" grep -qx "creds restore $me" "$CALLS"
ok "its summary reaches the log" logged "restored 3, kept 0, skipped 0"
: > "$CALLS"; DRY_RUN=1 restore_user_credentials "$me" >/dev/null; DRY_RUN=0
no "a dry run restores nothing" grep -q '^creds ' "$CALLS"

# --- install_vault_token_renew ---------------------------------------------
VTR_SRC="$tmp/vtr.sh"; VTR_SERVICE="$tmp/vtr.service"; VTR_TIMER="$tmp/vtr.timer"
cat > "$VTR_SRC" <<EOF
#!/usr/bin/env bash
vtr_resolve_config() {
  case "\${1:-}" in
    $me) VTR_MINT_POLICIES=(pol-a pol-b) ;;
    *) return 1 ;;
  esac
}
EOF
printf '[Service]\nExecStart=%%h/.local/bin/vault-token-renew\n' > "$VTR_SERVICE"
printf '[Timer]\nOnCalendar=daily\n' > "$VTR_TIMER"
: > "$CALLS"; : > "$LOG"
install_vault_token_renew someone-unmapped
ok "a user the renewer has no scope for is skipped" logged "no token scope for someone-unmapped"
no "and nothing is installed for them" grep -q 'systemctl' "$CALLS"

install_vault_token_renew "$me"
ok "the renewer is installed" cmp -s "$VTR_SRC" "$home/.local/bin/vault-token-renew"
eq "the renewer is executable" "755" "$(stat -c %a "$home/.local/bin/vault-token-renew")"
ok "the service unit is installed" cmp -s "$VTR_SERVICE" "$home/.config/systemd/user/vault-token-renew.service"
ok "the timer unit is installed" cmp -s "$VTR_TIMER" "$home/.config/systemd/user/vault-token-renew.timer"
ok "linger is turned on so the timer runs logged out" grep -qx "loginctl enable-linger $me" "$CALLS"
ok "the timer is enabled" grep -q 'systemctl --user enable --now vault-token-renew.timer' "$CALLS"
ok "a missing token is minted with the renewer's policies" \
  grep -q -- "vault token create -orphan -period=768h -policy=pol-a -policy=pol-b -display-name=devvm-$me -field=token" "$CALLS"
eq "the token lands in ~/.vault-token" "s.minted-token" "$(cat "$home/.vault-token")"
eq "the token file is private" "600" "$(stat -c %a "$home/.vault-token")"

: > "$CALLS"
install_vault_token_renew "$me"
no "an existing token is never re-minted" grep -q 'token create' "$CALLS"
rm "$home/.vault-token"; : > "$CALLS"; : > "$LOG"
FAKE_VAULT_DENY=1 install_vault_token_renew "$me"
no "without admin Vault access no token is written" test -e "$home/.vault-token"
ok "and that is logged" logged "no ~/.vault-token for $me"

# --- install_user_dotfiles -------------------------------------------------
: > "$CALLS"; : > "$LOG"
install_user_dotfiles "$me" "-"
eq "no dotfiles repo, nothing happens" "" "$(cat "$CALLS")"

install_user_dotfiles "$me" viktor/dot_files
ok "chezmoi is installed at the pinned version when missing" grep -q '^curl ' "$CALLS"
ok "the binary lands in ~/.local/bin" test -x "$home/.local/bin/chezmoi"
ok "init --apply runs from the roster repo, skipping encrypted entries" \
  grep -qF "chezmoi init --apply --force --no-tty --keep-going --exclude=encrypted https://forgejo.example.invalid/viktor/dot_files.git" "$CALLS"
ok "the user manager reloads the new units" grep -q 'systemctl --user daemon-reload' "$CALLS"

: > "$CALLS"
install_user_dotfiles "$me" viktor/dot_files
no "an existing chezmoi source is never re-initialised" grep -q 'chezmoi init' "$CALLS"

echo "t3-provision creds: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
