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
# organization_member added 2026-08-03: affiliation=owner alone lists only repos
# Viktor owns PERSONALLY, so org-owned repos were invisible to this sweep — e.g.
# immovika/realestate-crawler (wrongmove), whose deploy half was silently dead
# from 2026-05-18 to 2026-08-03. Org repos have collaborators, so their failing
# builds are exactly the ones worth surfacing.
repos=$(gh_get "${GH_API}/user/repos?affiliation=owner,organization_member&sort=pushed&per_page=60" \
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

# --- 3) GHA minutes vs free tier (enhanced billing API; old endpoint is 410-gone) ---
YM_Y=$(date -u +%Y); YM_M=$(date -u +%-m)
billing=$(gh_get "${GH_API}/users/ViktorBarzin/settings/billing/usage?year=${YM_Y}&month=${YM_M}")
if [ $? -eq 0 ]; then
  used=$(printf '%s' "$billing" | jq '[.usageItems[] | select(.product=="actions" and .unitType=="Minutes") | .quantity] | add // 0 | floor')
  included=2000
  pct=$((used * 100 / included))
  echo "GHA minutes (month): ${used}/${included} (${pct}%)" >>"$NOTES"
  [ "$pct" -ge 75 ] && echo "GHA minutes at ${pct}% of the free tier (${used}/${included}) — check for runaway workflows or consider Pro" >>"$ISSUES"
else
  echo "minutes check unavailable" >>"$NOTES"
fi

# --- Forgejo->GitHub mirror drift (infra#43) ---
#
# ADR-0003 makes Forgejo canonical and GitHub a one-way push-mirror, for
# off-site backup. That only holds if the mirrors are actually running, and
# until now nothing checked: mirrors were verified by hand at rollout and never
# again.
#
# Three distinct faults, in descending severity:
#
#  1. EMPTY-CANONICAL. The Forgejo repo has no branches but a mirror exists. The
#     mirror then tries to DELETE the target's default branch on every sync.
#     Found on audiblez-web 2026-09-02 while enabling one by hand; only GitHub
#     refusing to delete a default branch prevented the loss. This is the
#     inverse of the usual drift and is the one worth waking someone for.
#  2. MIRROR ERROR. push_mirrors reports a non-empty last_error, so the backup
#     silently stopped.
#  3. DRIFT. Both sides exist but their default-branch HEADs differ. Note a
#     mirror EXISTING does not mean the sides are in sync — if something
#     committed straight to GitHub, GitHub is ahead until the next Forgejo push
#     force-overwrites it.
#
# Repos with no mirror at all are reported unless they are a recorded exception.
# GitHub-first repos need no entry here: they are archived on the Forgejo side,
# and the loop skips archived repos.
FORGEJO_API="https://forgejo.viktorbarzin.me/api/v1"
FORGEJO_ONLY="hmrc-sync portal-assistant travel-agent"  # ADR-0003, infra#39: deliberately not mirrored

if [ -n "${FORGEJO_TOKEN:-}" ]; then
  mirror_checked=0
  repos=$(curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
    "$FORGEJO_API/user/repos?limit=100" 2>/dev/null |
    jq -r '.[] | select(.owner.login=="viktor" and .archived==false) | "\(.name)\t\(.default_branch)\t\(.empty)"')
  for line in $(echo "$repos" | tr '\t' '|' | tr ' ' '_'); do
    name=$(echo "$line" | cut -d'|' -f1)
    branch=$(echo "$line" | cut -d'|' -f2)
    is_empty=$(echo "$line" | cut -d'|' -f3)
    [ -n "$name" ] || continue
    mirror_checked=$((mirror_checked + 1))
    mirrors=$(curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
      "$FORGEJO_API/repos/viktor/$name/push_mirrors" 2>/dev/null)
    count=$(echo "$mirrors" | jq -r 'length' 2>/dev/null || echo 0)

    if [ "$count" = "0" ]; then
      case " $FORGEJO_ONLY " in
        *" $name "*) : ;;  # recorded exception, no backup by decision
        *) echo "$name has no push-mirror and is not a recorded Forgejo-only exception (ADR-0003) — it has no off-site backup" >>"$ISSUES" ;;
      esac
      continue
    fi

    if [ "$is_empty" = "true" ]; then
      echo "$name is EMPTY on Forgejo but has a push-mirror — every sync attempts to DELETE the mirror target's default branch (ADR-0003)" >>"$ISSUES"
      continue
    fi

    err=$(echo "$mirrors" | jq -r '.[0].last_error // ""')
    if [ -n "$err" ]; then
      echo "$name mirror is failing: $(echo "$err" | head -1 | cut -c1-140)" >>"$ISSUES"
      continue
    fi

    # HEAD comparison. Strip scheme and any .git suffix — getting this wrong
    # makes every repo read as drifted, which is how this check cries wolf.
    ghrepo=$(echo "$mirrors" | jq -r '.[0].remote_address' |
      sed -E 's#^(https|ssh)://##; s#^github\.com/##; s#\.git$##')
    fj_head=$(curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
      "$FORGEJO_API/repos/viktor/$name/commits?limit=1&sha=$branch" 2>/dev/null | jq -r '.[0].sha // ""')
    gh_head=$(curl -sf -H "Authorization: token $GITHUB_PAT" \
      "$GH_API/repos/$ghrepo/commits/$branch" 2>/dev/null | jq -r '.sha // ""')
    if [ -n "$fj_head" ] && [ -n "$gh_head" ] && [ "$fj_head" != "$gh_head" ]; then
      echo "$name has drifted: forgejo $(echo "$fj_head" | cut -c1-8) vs github $(echo "$gh_head" | cut -c1-8) on $branch ($ghrepo)" >>"$ISSUES"
    fi
  done
  echo "mirrors: ${mirror_checked} repos checked" >>"$NOTES"
else
  echo "mirror check unavailable (no FORGEJO_TOKEN)" >>"$NOTES"
fi

# --- Forward-auth authorization assertion (infra#53, story 18) -------------
#
# ADR-0023 replaced a hardcoded admin-host list with a GENERATED default-deny
# host->groups table inside one expression policy. Generated from ingress
# annotations at apply time, which is the right design and also means a bad
# generation, an empty table or an accidental early `return True` would grant
# everyone and look exactly like a normal apply. Until now the only check was
# somebody running the policy-test API by hand.
#
# THE TRAP THIS CHECK EXISTS TO AVOID, learned the hard way on 2026-09-02: the
# policy reads `request.context.get("host", "")`, NOT
# `context.http_request.host`. Send the host under the wrong key and it reads
# empty, the OAuth-authorize clause returns True, and EVERY assertion passes
# for the wrong reason. A first attempt at this matrix reported a confined user
# reaching grafana, prometheus and t3 — which looked like a live hole and was
# actually a bad payload. Hence the exact shape below, and hence the two
# must-GRANT rows: a check that only asserts denials passes just as happily
# when the policy denies everything.
if [ -n "${AUTHENTIK_TOKEN:-}" ]; then
  AK_API="https://authentik.viktorbarzin.me/api/v3"
  ak_group_member() {  # $1 = group name -> first member pk, or empty
    curl -sf -H "Authorization: Bearer $AUTHENTIK_TOKEN" \
      "$AK_API/core/groups/?page_size=100" 2>/dev/null |
      jq -r --arg g "$1" '.results[] | select(.name==$g) | .users_obj[0].pk // empty' | head -1
  }
  ak_policy_pk=$(curl -sf -H "Authorization: Bearer $AUTHENTIK_TOKEN" \
    "$AK_API/policies/all/?page_size=100" 2>/dev/null |
    jq -r '.results[] | select(.name=="admin-services-restriction") | .pk' | head -1)
  ak_confined=$(ak_group_member "Proxy Users")
  ak_admin=$(ak_group_member "Home Server Admins")

  if [ -z "$ak_policy_pk" ] || [ -z "$ak_confined" ] || [ -z "$ak_admin" ]; then
    echo "forward-auth assertion skipped (policy or a test identity not resolvable)" >>"$NOTES"
  else
    ak_test() {  # $1 = user pk, $2 = host -> "true"/"false"
      curl -sf -X POST -H "Authorization: Bearer $AUTHENTIK_TOKEN" -H "Content-Type: application/json" \
        -d "{\"user\":$1,\"context\":{\"host\":\"$2\"}}" \
        "$AK_API/policies/all/$ak_policy_pk/test/" 2>/dev/null | jq -r '.passing'
    }
    authz_failed=0
    # host | user | expected. The GRANT rows are load-bearing: without them a
    # deny-everything policy would satisfy this check.
    for row in \
      "grafana.viktorbarzin.me|$ak_confined|false" \
      "prometheus.viktorbarzin.me|$ak_confined|false" \
      "t3.viktorbarzin.me|$ak_confined|false" \
      "nosuchhost.viktorbarzin.me|$ak_confined|false" \
      "proxy.viktorbarzin.me|$ak_confined|true" \
      "grafana.viktorbarzin.me|$ak_admin|true"
    do
      h=$(echo "$row" | cut -d'|' -f1); u=$(echo "$row" | cut -d'|' -f2); want=$(echo "$row" | cut -d'|' -f3)
      got=$(ak_test "$u" "$h")
      if [ "$got" != "$want" ]; then
        echo "forward-auth authorization WRONG for user $u on $h: expected passing=$want, got $got (ADR-0023 default-deny table)" >>"$ISSUES"
        authz_failed=$((authz_failed + 1))
      fi
    done
    if [ "$authz_failed" = "0" ]; then
      echo "forward-auth authz: 6 assertions pass" >>"$NOTES"
    fi
  fi
else
  echo "forward-auth assertion unavailable (no AUTHENTIK_TOKEN)" >>"$NOTES"
fi

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
