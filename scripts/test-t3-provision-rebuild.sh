#!/usr/bin/env bash
# Checks the first-boot pieces of t3-provision-users.sh that the fifth rebuild
# drill found missing or out of order (docs/runbooks/devvm-drill.md, drill log):
#   check_workstation_inputs  the hourly run before the infra clone exists
#   resolve_agents_owner      who owns the agent-instruction fetches
#   install_forgejo_known_hosts  Forgejo's SSH host key in each user's known_hosts
#   start_skills_update_once  skills come back without waiting for 05:45
#   install_ios_rig_units     wizard's iOS rig units on a rebuilt live box
#   install_user_dotfiles     with a real chezmoi: the session store's
#                             ~/.claude files survive the dotfiles apply
#
# Run: bash scripts/test-t3-provision-rebuild.sh
#
# Pulls the functions out of the script by name and runs them against temp
# homes, with stand-ins for runuser, systemctl, ip, vault and homelab that
# record what they were asked to do. The chezmoi part needs chezmoi on PATH
# (or in ~/.local/bin) and is skipped without it.
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
for fn in mkdir_as write_as repo_url check_workstation_inputs resolve_agents_owner install_forgejo_known_hosts \
          start_skills_update_once is_live_devvm install_ios_rig_units install_user_dotfiles dotfiles_apply; do
  eval "$(extract "$fn")"
  declare -F "$fn" >/dev/null || { echo "FAIL: $fn not found in $SCRIPT"; exit 1; }
done
# The pinned host key line is a top-level assignment, not a function.
eval "$(grep -E '^FORGEJO_SSH_HOST_KEY=' "$SCRIPT")"

real_chezmoi="$(command -v chezmoi 2>/dev/null || true)"
[[ -z "$real_chezmoi" && -x "$HOME/.local/bin/chezmoi" ]] && real_chezmoi="$HOME/.local/bin/chezmoi"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
CALLS="$tmp/calls"; : > "$CALLS"
export CALLS
printf '#!/usr/bin/env bash\necho "runuser $*" >> "$CALLS"\n[[ "$1" == -u ]] && shift 2\n[[ "$1" == -- ]] && shift\nexec "$@"\n' > "$tmp/bin/runuser"
cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS"
[[ "$1" == cat ]] && { [[ -n "${FAKE_NO_SKILLS_UNIT:-}" ]] && exit 1; exit 0; }
exit 0
EOF
cat > "$tmp/bin/ip" <<'EOF'
#!/usr/bin/env bash
echo "2: eth0    inet ${FAKE_ADDR:-10.0.10.14}/24 brd 10.0.10.255 scope global eth0"
EOF
# These two run under `env -i`, so the call log and the switch are baked in.
cat > "$tmp/bin/vault" <<EOF
#!/usr/bin/env bash
echo "vault \$* (VAULT_TOKEN=\${VAULT_TOKEN:-<unset>})" >> "$CALLS"
[[ -e "$tmp/no-rig" ]] && exit 2
exit 0
EOF
cat > "$tmp/bin/homelab" <<EOF
#!/usr/bin/env bash
echo "homelab \$* (HOME=\$HOME VAULT_TOKEN=\${VAULT_TOKEN:-<unset>})" >> "$CALLS"
exit 0
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
LOG="$tmp/log"; : > "$LOG"
log() { echo "$*" >> "$LOG"; }
logged() { grep -qF -- "$1" "$LOG"; }
DRY_RUN=0
me="$(id -un)"
home="$tmp/home"; mkdir -p "$home"
TEST_HOME="$home"
getent() { echo "$me:x:$(id -u):$(id -g)::$TEST_HOME:/bin/sh"; }

# --- check_workstation_inputs --------------------------------------------------
WORKSTATION_DIR="$tmp/nope/scripts/workstation"; ROSTER="$WORKSTATION_DIR/roster.yaml"; ENGINE="$WORKSTATION_DIR/roster_engine.py"
check_workstation_inputs; eq "no infra checkout yet: nothing to do (1)" 1 "$?"
mkdir -p "$WORKSTATION_DIR"
check_workstation_inputs; eq "a checkout without roster or engine is an error (2)" 2 "$?"
touch "$ROSTER" "$ENGINE"
check_workstation_inputs; eq "both present: go (0)" 0 "$?"
ok "the script exits 0 on 1 and says why" grep -q 'infra checkout .* not there yet' "$SCRIPT"

# --- resolve_agents_owner --------------------------------------------------------
eq "the checkout's owner when it is a person" wizard "$(resolve_agents_owner wizard "$me")"
eq "root's /opt clone hands the fetches to the first admin with an account" "$me" \
  "$(resolve_agents_owner root "$(printf '# header\nno-such-user-x\n%s\n' "$me")")"
eq "root only when no admin has an account" root "$(resolve_agents_owner root "no-such-user-x")"

# --- install_forgejo_known_hosts --------------------------------------------------
ok "the pinned key is Forgejo's RSA key" test "${FORGEJO_SSH_HOST_KEY%% *}" == "git.viktorbarzin.me"
: > "$LOG"
install_forgejo_known_hosts "$me"
ok "known_hosts gets the pinned line" grep -qxF "$FORGEJO_SSH_HOST_KEY" "$home/.ssh/known_hosts"
eq "~/.ssh is made private" 700 "$(stat -c %a "$home/.ssh")"
eq "known_hosts is 0644" 644 "$(stat -c %a "$home/.ssh/known_hosts")"
ok "ssh-keygen finds the host" eval 'ssh-keygen -F git.viktorbarzin.me -f "$home/.ssh/known_hosts" >/dev/null'
install_forgejo_known_hosts "$me"
eq "a second run adds nothing" 1 "$(grep -c 'git.viktorbarzin.me' "$home/.ssh/known_hosts")"
# A hashed entry the user trusted by hand counts as present.
rm "$home/.ssh/known_hosts"
echo "$FORGEJO_SSH_HOST_KEY" > "$tmp/plain"; ssh-keygen -H -f "$tmp/plain" >/dev/null 2>&1
cp "$tmp/plain" "$home/.ssh/known_hosts"; before="$(cat "$home/.ssh/known_hosts")"
install_forgejo_known_hosts "$me"
eq "a hashed entry already there is left alone" "$before" "$(cat "$home/.ssh/known_hosts")"
echo "other.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOther" > "$home/.ssh/known_hosts"
install_forgejo_known_hosts "$me"
eq "other hosts are kept" 2 "$(wc -l < "$home/.ssh/known_hosts")"
DRY_RUN=1; rm -rf "$home/.ssh"
eq "dry run only reports" "[dry-run] Forgejo SSH host key -> $me:~/.ssh/known_hosts" "$(install_forgejo_known_hosts "$me")"
no "dry run writes nothing" test -e "$home/.ssh"
DRY_RUN=0

# --- start_skills_update_once ----------------------------------------------------
STATEDIR="$tmp/state"; mkdir -p "$STATEDIR"
CLAUDE_SESSIONS_RESTORED_DIR="$tmp/restored"; mkdir -p "$CLAUDE_SESSIONS_RESTORED_DIR"
: > "$CALLS"; : > "$LOG"
start_skills_update_once "$me"
no "not before every user's agent state is restored (the skill lockfile comes from it)" grep -q 'start' "$CALLS"
no "and nothing is marked" test -e "$STATEDIR/skills-update.started"
touch "$CLAUDE_SESSIONS_RESTORED_DIR/$me"
start_skills_update_once "$me" no-such-user-x
ok "a user without an account does not hold it back" grep -qxF "systemctl start --no-block claude-skills-update.service" "$CALLS"
ok "the start is marked" test -e "$STATEDIR/skills-update.started"
ok "and logged" logged "started claude-skills-update once"
: > "$CALLS"
start_skills_update_once "$me"
no "only once per box" grep -q 'start' "$CALLS"
rm "$STATEDIR/skills-update.started"; : > "$CALLS"
FAKE_NO_SKILLS_UNIT=1 start_skills_update_once "$me"
no "a box without the unit does nothing" grep -q 'start --no-block' "$CALLS"
no "and is not marked, so a later run still starts it" test -e "$STATEDIR/skills-update.started"

# --- install_ios_rig_units -------------------------------------------------------
HOMELAB_BIN="$tmp/bin/homelab"
: > "$CALLS"; : > "$LOG"
echo s.user-token > "$home/.vault-token"
FAKE_ADDR=10.0.10.14 install_ios_rig_units "$me" admin
no "a drill (not 10.0.10.10) never drives the real phone" grep -q '^homelab ' "$CALLS"
FAKE_ADDR=10.0.10.10 install_ios_rig_units "$me" power-user
no "only an admin's rig" grep -q '^homelab ' "$CALLS"
touch "$tmp/no-rig"; FAKE_ADDR=10.0.10.10 install_ios_rig_units "$me" admin; rm "$tmp/no-rig"
no "no secret/ios-rig for this user: not configured, skipped" grep -q '^homelab ' "$CALLS"
FAKE_ADDR=10.0.10.10 install_ios_rig_units "$me" admin
ok "the live box restores the units" grep -q "^homelab ios bootstrap --units-only (HOME=$home VAULT_TOKEN=<unset>)" "$CALLS"
ok "the rig check reads Vault as the user, with the user's own token file" grep -q '^vault kv get .*secret/ios-rig (VAULT_TOKEN=<unset>)' "$CALLS"
ok "and logs it" logged "iOS rig units restored -> $me"
mkdir -p "$home/.config/systemd/user"; touch "$home/.config/systemd/user/ios-rig-tunnel.service"; : > "$CALLS"
FAKE_ADDR=10.0.10.10 install_ios_rig_units "$me" admin
no "units already there: nothing runs" grep -q '^homelab ' "$CALLS"
rm -rf "$home/.config" "$home/.vault-token"
FAKE_ADDR=10.0.10.10 install_ios_rig_units "$me" admin
no "no ~/.vault-token yet: skipped until the admin run mints one" grep -q '^homelab ' "$CALLS"

# --- install_user_dotfiles with a real chezmoi ---------------------------------
# The scratch run of the drill-5 order: dotfiles first (step 4), then the
# session store's restore (step 4a, tar --skip-old-files). The store's
# ~/.claude files must be the ones left on disk.
if [[ -n "$real_chezmoi" ]]; then
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
  FORGEJO_BASE="$tmp/forgejo"; src="$FORGEJO_BASE/viktor/dots.git"; mkdir -p "$src"
  g() { git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=master "$@" >/dev/null 2>&1; }
  g init -q "$src"
  mkdir -p "$src/dot_claude/plugins" "$src/dot_codex" "$src/dot_agents"
  echo 'export FROM_DOTFILES=1' > "$src/dot_zshrc"
  echo '{"from":"dotfiles"}' > "$src/dot_claude/settings.local.json"
  echo '{"from":"dotfiles"}' > "$src/dot_claude/plugins/installed_plugins.json"
  echo '# agents' > "$src/dot_agents/AGENTS.md"
  printf '{{ .chezmoi.homeDir }}/.agents/AGENTS.md\n' > "$src/dot_claude/symlink_CLAUDE.md.tmpl"
  printf '{{ .chezmoi.homeDir }}/.agents/AGENTS.md\n' > "$src/dot_codex/symlink_AGENTS.md.tmpl"
  g -C "$src" add -A; g -C "$src" commit -qm dots
  h2="$tmp/home2"; mkdir -p "$h2/.local/bin"; ln -s "$real_chezmoi" "$h2/.local/bin/chezmoi"
  TEST_HOME="$h2"; : > "$LOG"
  install_user_dotfiles "$me" viktor/dots
  ok "the apply is logged" logged "applied dotfiles viktor/dots -> $me"
  eq "a dotfile outside ~/.claude is written" 'export FROM_DOTFILES=1' "$(cat "$h2/.zshrc" 2>/dev/null)"
  eq "~/.claude/CLAUDE.md is the dotfiles' link" "$h2/.agents/AGENTS.md" "$(readlink "$h2/.claude/CLAUDE.md")"
  eq "~/.codex/AGENTS.md too" "$h2/.agents/AGENTS.md" "$(readlink "$h2/.codex/AGENTS.md")"
  no "no regular file under ~/.claude came from the dotfiles" test -e "$h2/.claude/settings.local.json"
  no "nor under ~/.claude/plugins" test -e "$h2/.claude/plugins/installed_plugins.json"
  # step 4a: the store's copy, restored with --skip-old-files
  mkdir -p "$tmp/store/.claude/plugins"
  echo '{"from":"store"}' > "$tmp/store/.claude/settings.local.json"
  echo '{"from":"store"}' > "$tmp/store/.claude/plugins/installed_plugins.json"
  tar -C "$tmp/store" -cf - .claude | tar -x --skip-old-files -C "$h2"
  eq "the store's settings.local.json is what stays" '{"from":"store"}' "$(cat "$h2/.claude/settings.local.json")"
  eq "and its installed_plugins.json" '{"from":"store"}' "$(cat "$h2/.claude/plugins/installed_plugins.json")"
  TEST_HOME="$home"
else
  echo "SKIP: no chezmoi binary, the real-chezmoi scratch run did not run"
fi

echo "t3-provision rebuild: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
