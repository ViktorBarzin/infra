#!/bin/sh
# ci-pipeline-health — daily sweep of the off-infra CI chain (ADR-0002, PRD infra#10).
# Deterministic (no LLM): GitHub Actions runs + Woodpecker pipelines + GHA minutes.
# Healthy => one quiet Slack line. Issues => Slack alert + comment on infra#10.
# POSIX sh + curl + jq only (runs on the Alpine claude-agent-service image).
# Exit 0 = sweep ran (even with findings); exit 2 = the sweep itself errored,
# which surfaces through the existing CronJob-failure alerting.

GH_API="https://api.github.com"
WP_API="https://ci.viktorbarzin.me/api"
WP_UI="https://ci.viktorbarzin.me"

NOW_EPOCH=$(date -u +%s)
SINCE_EPOCH=$((NOW_EPOCH - 86400))
SINCE_ISO=$(date -u -d "@${SINCE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)
PUSH_CUTOFF=$(date -u -d "@$((NOW_EPOCH - 259200))" +%Y-%m-%dT%H:%M:%SZ)

ISSUES=$(mktemp)
NOTES=$(mktemp)
trap 'rm -f "$ISSUES" "$NOTES"' EXIT
gha_checked=0
wp_checked=0
sweep_errors=0

gh_get() { curl -sf --max-time 30 -H "Authorization: Bearer ${GITHUB_PAT}" -H "Accept: application/vnd.github+json" "$1"; }
wp_get() { curl -sf --max-time 30 -H "Authorization: Bearer ${WOODPECKER_API_TOKEN}" "$1"; }

# --- 1) GitHub Actions runs across owned repos with a recent push ---
repos=$(gh_get "${GH_API}/user/repos?affiliation=owner&sort=pushed&per_page=60" \
  | jq -r --arg cutoff "$PUSH_CUTOFF" '.[] | select(.pushed_at >= $cutoff) | .full_name')
if [ $? -ne 0 ]; then
  echo "sweep: failed to list GitHub repos" >>"$ISSUES"; sweep_errors=1; repos=""
fi
for repo in $repos; do
  runs=$(gh_get "${GH_API}/repos/${repo}/actions/runs?created=%3E%3D${SINCE_ISO}&per_page=50")
  if [ $? -ne 0 ]; then echo "sweep: failed to list runs for ${repo}" >>"$ISSUES"; sweep_errors=1; continue; fi
  n=$(printf '%s' "$runs" | jq '.workflow_runs | length')
  gha_checked=$((gha_checked + n))
  printf '%s' "$runs" | jq -r '.workflow_runs[]
      | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled" or .conclusion == "action_required")
      | "GHA: \(.repository.full_name) #\(.run_number) [\(.name)] \(.conclusion) \(.html_url)"' >>"$ISSUES"
  printf '%s' "$runs" | jq -r --argjson now "$NOW_EPOCH" '.workflow_runs[]
      | select(.status == "in_progress" or .status == "queued")
      | select(($now - ((.run_started_at // .created_at) | fromdateiso8601)) > 7200)
      | "GHA stuck >2h: \(.repository.full_name) #\(.run_number) [\(.name)] \(.status) \(.html_url)"' >>"$ISSUES"
done

# --- 2) Woodpecker pipelines (deploy chain) ---
wrepos=$(wp_get "${WP_API}/repos?perPage=100" | jq -r '.[] | select(.active == true) | "\(.id) \(.full_name)"')
if [ $? -ne 0 ]; then
  echo "sweep: failed to list Woodpecker repos" >>"$ISSUES"; sweep_errors=1; wrepos=""
fi
printf '%s\n' "$wrepos" | while IFS=' ' read -r id name; do
  [ -z "$id" ] && continue
  pls=$(wp_get "${WP_API}/repos/${id}/pipelines?perPage=10")
  if [ $? -ne 0 ]; then echo "sweep: failed pipelines for ${name}" >>"$ISSUES"; continue; fi
  printf '%s' "$pls" | jq -r --argjson since "$SINCE_EPOCH" --arg name "$name" --arg ui "$WP_UI" --arg id "$id" '
      [.[] | select(.created >= $since)][]
      | select(.status == "failure" or .status == "error" or .status == "killed")
      | "Woodpecker: \($name) #\(.number) \(.status) (\(.event)) \($ui)/repos/\($id)/pipeline/\(.number)"' >>"$ISSUES"
  printf '%s' "$pls" | jq --argjson since "$SINCE_EPOCH" '[.[] | select(.created >= $since)] | length' >>"$NOTES.wpcount" 2>/dev/null || true
done
wp_checked=$(awk '{s+=$1} END {print s+0}' "$NOTES.wpcount" 2>/dev/null || echo 0)
rm -f "$NOTES.wpcount"

# --- 3) GHA minutes vs free tier ---
billing=$(gh_get "${GH_API}/users/ViktorBarzin/settings/billing/actions")
if [ $? -eq 0 ]; then
  used=$(printf '%s' "$billing" | jq -r '.total_minutes_used')
  included=$(printf '%s' "$billing" | jq -r '.included_minutes')
  if [ "${included:-0}" -gt 0 ] 2>/dev/null; then
    pct=$((used * 100 / included))
    echo "GHA minutes: ${used}/${included} (${pct}%)" >>"$NOTES"
    [ "$pct" -ge 75 ] && echo "GHA minutes at ${pct}% of the free tier (${used}/${included}) — check for runaway workflows or consider Pro" >>"$ISSUES"
  fi
else
  echo "minutes check unavailable" >>"$NOTES"
fi

# v1 scope (deliberate, not silent): Forgejo→GitHub mirror-gap detection (a
# Forgejo push that produced no GHA run) is NOT implemented yet — it needs the
# per-repo mirror inventory that lands with the offinfra-onboard rollout (#13+).

# --- Report ---
issue_count=$(grep -c . "$ISSUES" || true)
summary="ci-pipeline-health: checked ${gha_checked} GHA runs + ${wp_checked} Woodpecker pipelines (24h). $(tr '\n' '; ' <"$NOTES")"

if [ "$issue_count" -eq 0 ]; then
  text=":white_check_mark: ${summary}"
else
  text=":rotating_light: ci-pipeline-health: ${issue_count} issue(s)
$(sed 's/^/• /' "$ISSUES")
${summary}"
  body="Daily CI sweep found ${issue_count} issue(s):

$(sed 's/^/- /' "$ISSUES")

_${summary}_"
  printf '%s' "$body" | jq -Rs '{body: .}' \
    | curl -sf --max-time 30 -X POST -H "Authorization: Bearer ${GITHUB_PAT}" \
        -H "Accept: application/vnd.github+json" \
        -d @- "${GH_API}/repos/ViktorBarzin/infra/issues/10/comments" >/dev/null \
    || { echo "sweep: failed to comment on infra#10"; sweep_errors=1; }
fi

printf '%s' "$text" | jq -Rs '{text: .}' \
  | curl -sf --max-time 30 -X POST -H 'Content-Type: application/json' -d @- "$SLACK_WEBHOOK" >/dev/null \
  || { echo "sweep: failed to post to Slack"; sweep_errors=1; }

echo "$text"
[ "$sweep_errors" -ne 0 ] && exit 2
exit 0
