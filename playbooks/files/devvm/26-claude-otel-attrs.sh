# Stamp Claude Code's OpenTelemetry export with the OS user and, inside tmux,
# the human session name. Claude knows the name (start-claude.sh passes --name)
# but does not export it, so it is added here or not at all. Read once at shell
# start, so a later rename does not reach a running session.
_tl_sess=""
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  _tl_sess="$(tmux display-message -p '#S' 2>/dev/null | tr -d ',=' )"
fi
export OTEL_RESOURCE_ATTRIBUTES="host.name=devvm,deployment.environment=homelab,os.user=$(id -un)${_tl_sess:+,tmux.session=$_tl_sess}"
unset _tl_sess
