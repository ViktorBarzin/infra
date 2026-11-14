# Load the per-user long-lived Claude setup-token (materialized by claude-auth-sync
# from the user's OWN Vault path) so interactive `claude` uses it too — matching
# start-claude.sh + t3-serve@.service. Per-user ($HOME), guarded, no-op without a
# token. NEVER a shared token (that would collapse identities; see runbook
# docs/runbooks/claude-auth-renew-workstation.md).
_cc_oauth_env="$HOME/.config/claude-auth-sync/claude-oauth.env"
if [ -r "$_cc_oauth_env" ]; then
  set -a; . "$_cc_oauth_env"; set +a
fi
unset _cc_oauth_env
