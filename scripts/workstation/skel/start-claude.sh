#!/bin/bash
# Per-user Claude Code Workstation launcher (devvm). Lands the user in their OWN
# ~/code clone (NOT a hardcoded /home/wizard/code) and names the Claude session
# after the tmux session so /resume, the prompt box, and the terminal title line
# up. Deployed via /etc/skel by setup-devvm.sh, so new accounts get it on
# `useradd -m`. Existing users are repointed to this during their migration.
echo ""
echo "  Welcome, $(id -un)! 🚀"
echo ""
echo "  Starting Claude Code in $HOME/code ..."
echo "  (Right-click for tmux menu, or Ctrl+B then | or - to split)"
echo ""

name_args=()
if [ -n "${TMUX:-}" ]; then
  sess="$(tmux display-message -p '#{session_name}' 2>/dev/null)"
  [ -n "$sess" ] && name_args=(--name "$sess")
fi

cd "$HOME/code" 2>/dev/null || cd "$HOME"

# Prefer the system-wide `claude` (installed by setup-devvm.sh); fall back to npx.
launch() {
  if command -v claude >/dev/null 2>&1; then
    claude "$@"
  else
    npx @anthropic-ai/claude-code "$@"
  fi
}

# Deliberately not `exec` so we can branch on the exit code: clean quit ends the
# pane (ttyd closes the terminal); a crash drops to a shell so the tmux session
# isn't destroyed-and-recreated in a ttyd auto-reconnect loop.
# No --model flag: inherit the org-wide default from /etc/claude-code/managed-settings.json
# (an explicit --model would override that managed default for every launched session).
launch --dangerously-skip-permissions "${name_args[@]}"
code=$?
[ "$code" -eq 0 ] && exit 0

echo ""
echo "  claude exited abnormally (status $code). Dropping to a shell — your tmux session is preserved."
echo "  Re-launch any time with: ~/start-claude.sh"
echo ""
exec "${SHELL:-/bin/bash}" -l
