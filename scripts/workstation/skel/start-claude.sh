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

# The native claude install lives in ~/.local/bin. This launcher runs in tmux's non-login
# env, which does NOT source the user's shell rc (where the native installer added it to
# PATH) — so `claude` would appear missing here. Put it on PATH ourselves; guarded/idempotent.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

name_args=()
if [ -n "${TMUX:-}" ]; then
  sess="$(tmux display-message -p '#{session_name}' 2>/dev/null)"
  [ -n "$sess" ] && name_args=(--name "$sess")
fi

cd "$HOME/code" 2>/dev/null || cd "$HOME"

# Freshen the user's clone(s) at session start so they begin on current upstream
# state (the hourly t3-provision-users reconcile does the same in the background).
# Single layout freshens ~/code itself; workspace layout freshens each repo under
# ~/code. Fast-forward only, and only when safe (on master + clean tree); hard
# 10s fetch cap per repo so an offline remote never stalls the launch.
freshen_repo() {
  GIT_TERMINAL_PROMPT=0 timeout 10 git -C "$1" fetch --all --prune --quiet 2>/dev/null || true
  # ff whatever branch is checked out (master, main, ...) when that is provably
  # safe: on a branch, clean tree, upstream configured. Never rebases/merges.
  if [ -n "$(git -C "$1" symbolic-ref --short -q HEAD)" ] \
     && [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ] \
     && git -C "$1" rev-parse --verify -q '@{upstream}' >/dev/null 2>&1; then
    git -C "$1" merge --ff-only '@{upstream}' >/dev/null 2>&1 || true
  fi
}
if [ -d "$HOME/code/.git" ]; then
  freshen_repo "$HOME/code"
else
  for repo_git in "$HOME"/code/*/.git; do
    [ -d "$repo_git" ] && freshen_repo "${repo_git%/.git}"
  done
fi

# Run the NATIVE `claude` (the recommended install: ~/.local/bin/claude, self-updating).
# No npm/npx. If the native binary is missing (a fresh account before the hourly reconcile
# has provisioned it), bootstrap it with the official native installer, then run it.
launch() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "  Installing Claude Code (native) for $(id -un) …"
    curl -fsSL https://claude.ai/install.sh | bash || return 127
    export PATH="$HOME/.local/bin:$PATH"
  fi
  claude "$@"
}

# Re-assert Claude Code's first-run onboarding flag before launch. ~/.claude.json is a
# SINGLE file that ALL of a user's concurrent claude processes (this terminal, their
# t3-serve instance, agent/SDK sessions) read-modify-write; a stale writer periodically
# drops top-level keys — including hasCompletedOnboarding — which throws the next
# interactive session back to the "Choose the text style" wizard even though the user is
# fully logged in (credentials live in the SEPARATE ~/.claude/.credentials.json, which is
# never affected). Idempotent, runs as the user right before launch, never clobbers other
# keys. Best-effort: no-op if jq is missing or the file is empty/corrupt (claude self-heals).
ensure_onboarding() {
  command -v jq >/dev/null 2>&1 || return 0
  local cfg="$HOME/.claude.json" ver tmp
  ver="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -s "$cfg" ]; then
    jq -e . "$cfg" >/dev/null 2>&1 || return 0                                     # corrupt -> leave for claude
    [ "$(jq -r '.hasCompletedOnboarding // false' "$cfg")" = "true" ] && return 0  # already set -> no write
  elif [ -e "$cfg" ]; then
    return 0                                                                       # empty (mid-write?) -> leave it
  fi
  tmp="$(mktemp "${cfg}.XXXXXX")" || return 0
  if [ -f "$cfg" ]; then
    jq --arg v "$ver" '.hasCompletedOnboarding = true
      | (if $v != "" then .lastOnboardingVersion = $v else . end)' "$cfg" > "$tmp" 2>/dev/null \
      && chmod 600 "$tmp" && mv "$tmp" "$cfg" || rm -f "$tmp"
  else
    jq -n --arg v "$ver" '{hasCompletedOnboarding: true}
      + (if $v != "" then {lastOnboardingVersion: $v} else {} end)' > "$tmp" 2>/dev/null \
      && chmod 600 "$tmp" && mv "$tmp" "$cfg" || rm -f "$tmp"
  fi
}
ensure_onboarding

# Load a per-user long-lived CLAUDE_CODE_OAUTH_TOKEN if claude-auth-sync has
# materialized one from this user's own Vault path. A non-rotating setup-token
# sidesteps the shared ~/.claude/.credentials.json OAuth refresh-token race that
# logs out users running many concurrent agents (interactive + t3 + always-on).
# Absent file -> no-op (normal per-user Enterprise-SSO flow). The user's OWN
# token; never shared between OS users.
_oauth_env="$HOME/.config/claude-auth-sync/claude-oauth.env"
if [ -r "$_oauth_env" ]; then set -a; . "$_oauth_env"; set +a; fi

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
