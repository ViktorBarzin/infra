#!/usr/bin/env bash
# Checks the three steps t3-provision-users.sh runs so a rebuilt devvm gets each
# user's own state back (docs/plans/2026-11-11-disposable-devvm.md):
#   restore_user_credentials  the Vault-held credential files (workstation-creds)
#   install_vault_token_renew the renewer, its user units and a first token
#   install_user_dotfiles     chezmoi init --apply from the roster's dotfiles repo
#   install_agent_api_keys    the memory and pages keys in ~/.claude/settings.json
# and that an admin VAULT_TOKEN the run is given reaches only the vault CLI,
# never a command run as a user (take_admin_vault_token, vault_admin).
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
for fn in take_admin_vault_token vault_admin mkdir_as write_as repo_url restore_user_credentials install_vault_token_renew install_user_dotfiles install_agent_api_keys; do
  eval "$(extract "$fn")"
  declare -F "$fn" >/dev/null || { echo "FAIL: $fn not found in $SCRIPT"; exit 1; }
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
CALLS="$tmp/calls"; : > "$CALLS"
export CALLS
# runuser notes the VAULT_TOKEN it was handed: a user's processes must never get one.
printf '#!/usr/bin/env bash\necho "runuser VAULT_TOKEN=${VAULT_TOKEN:-<unset>}" >> "$CALLS.runuser"\n[[ "$1" == -u ]] && shift 2\n[[ "$1" == -- ]] && shift\nexec "$@"\n' > "$tmp/bin/runuser"
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
echo "vault VAULT_TOKEN=${VAULT_TOKEN:-<unset>}" >> "$CALLS.vault"
[[ -n "${FAKE_VAULT_DENY:-}" ]] && exit 2
[[ "$*" == "kv get -field=api_keys secret/claude-memory" ]] && { printf '{"%s":"mem-key-1","other":"x"}' "$(id -un)"; exit 0; }
[[ "$*" == "kv get -field=api_keys secret/pages-publish" ]] && { printf '{"%s":"pages-key-1"}' "$(id -un)"; exit 0; }
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

# --- take_admin_vault_token ---------------------------------------------------
export VAULT_TOKEN=s.admin-test; take_admin_vault_token
eq "the admin token is kept in the script's own variable" "s.admin-test" "$ADMIN_VAULT_TOKEN"
eq "and taken out of the environment" "" "$(printenv VAULT_TOKEN)"
take_line="$(grep -n '^take_admin_vault_token$' "$SCRIPT" | head -1 | cut -d: -f1)"
first_user_cmd="$(grep -n 'fetch --quiet origin master' "$SCRIPT" | head -1 | cut -d: -f1)"
ok "the script takes the token before it first runs anything as a user" test "${take_line:-99999}" -lt "${first_user_cmd:-0}"
ok "the self-deploy re-exec hands the token on without putting it in argv" \
  grep -q 'export VAULT_TOKEN="\$ADMIN_VAULT_TOKEN"' "$SCRIPT"
ok "the deployed files are extracted on the self-deployed pass too" test \
  "$(grep -n '^committed scripts/workstation/workstation-creds.sh' "$SCRIPT" | cut -d: -f1)" -gt \
  "$(grep -n '^if \[\[ -z "\${T3_PROVISION_SELF_DEPLOYED:-}" \]\]; then$' "$SCRIPT" | head -1 | cut -d: -f1)"
no "no function calls the vault CLI directly" grep -qE '(^|[^_a-z-])vault (token|kv) ' <(grep -v '^ *#' "$SCRIPT" | grep -v 'log "')

# --- restore_user_credentials ------------------------------------------------
CREDS_SRC="$tmp/creds.sh"
printf '#!/usr/bin/env bash\necho "creds $*" >> "$CALLS"\necho "creds VAULT_TOKEN=${VAULT_TOKEN:-<unset>}" >> "$CALLS.vault"\necho "workstation-creds: $2 restored 3, kept 0, skipped 0"\n' > "$CREDS_SRC"
FAKE_VAULT_DENY=1 restore_user_credentials "$me"
FAKE_VAULT_DENY=1 restore_user_credentials other
no "without a Vault token nothing is restored" grep -q '^creds ' "$CALLS"
eq "the skip is logged once per run, not per user" "1" "$(grep -c 'credential restore skipped' "$LOG")"
unset CREDS_NO_VAULT_LOGGED
restore_user_credentials "$me"
ok "with a Vault token it restores that user" grep -qx "creds restore $me" "$CALLS"
ok "workstation-creds gets the admin token" grep -qx "creds VAULT_TOKEN=s.admin-test" "$CALLS.vault"
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

# --- install_agent_api_keys -------------------------------------------------
settings="$home/.claude/settings.json"; mkdir -p "$home/.claude"
printf '{"env":{"MEMORY_API_KEY":"kept-by-hand","STATUSLINE_X":"1"},"fastMode":true}\n' > "$settings"
: > "$CALLS"; : > "$LOG"
install_agent_api_keys "$me"
eq "a key already there is never replaced" "kept-by-hand" "$(jq -r .env.MEMORY_API_KEY "$settings")"
eq "a missing memory key comes from secret/claude-memory" "mem-key-1" "$(jq -r .env.CLAUDE_MEMORY_API_KEY "$settings")"
eq "a missing pages key comes from secret/pages-publish" "pages-key-1" "$(jq -r .env.PAGES_API_KEY "$settings")"
eq "the memory URL is filled in with its key" "https://claude-memory.viktorbarzin.me" "$(jq -r .env.CLAUDE_MEMORY_API_URL "$settings")"
eq "the rest of settings.json is kept" "1 true" "$(jq -r '"\(.env.STATUSLINE_X) \(.fastMode)"' "$settings")"
eq "settings.json stays private" "600" "$(stat -c %a "$settings")"
ok "what it filled is logged by name" logged "CLAUDE_MEMORY_API_KEY"
no "a key value never reaches the log" grep -qE 'mem-key-1|pages-key-1' "$LOG"
: > "$CALLS"
install_agent_api_keys "$me"
no "with every key present Vault is not asked" grep -q '^vault ' "$CALLS"
rm "$settings"; : > "$CALLS"
FAKE_VAULT_DENY=1 install_agent_api_keys "$me"
no "without admin Vault access nothing is written" test -e "$settings"
install_agent_api_keys "$me"
eq "a missing settings.json is created with the keys" "mem-key-1" "$(jq -r .env.MEMORY_API_KEY "$settings")"
: > "$LOG"
TEST_HOME="$tmp/nohome" install_agent_api_keys "$me"
eq "a user without ~/.claude is left alone" "" "$(cat "$LOG")"

# --- the admin token reaches only the vault CLI ------------------------------
ok "the vault CLI was given the admin token" grep -qx "vault VAULT_TOKEN=s.admin-test" "$CALLS.vault"
ok "commands did run as the user" grep -q '^runuser ' "$CALLS.runuser"
no "no command run as a user ever got the admin token" grep -q 's.admin-test' "$CALLS.runuser"

echo "t3-provision creds: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
