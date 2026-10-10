#!/usr/bin/env bash
# Unit tests for scripts/renovate-rails: the parts that decide what the rails
# act on (pending commits, stacks, trailers, ignore entries, gate allowlist,
# revert commit, marker base). Each case builds a throwaway git repo, so the
# tests touch neither the cluster nor this checkout.
#
#   bash scripts/renovate-rails.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
RAILS="$HERE/renovate-rails"
# shellcheck source=renovate-rails
source "$RAILS"

fails=0 passes=0
ok() { passes=$((passes + 1)); echo "ok   $1"; }
bad() { fails=$((fails + 1)); echo "FAIL $1"; [ $# -gt 1 ] && printf '     %s\n' "${@:2}"; }
eq() { # name want got
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want: $(printf %q "$2")" "got:  $(printf %q "$3")"; fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# A repo with two stacks, a renovate commit per stack, a human commit and an
# ignore list, laid out like the infra repo.
mkrepo() {
  rm -rf "$T/r" && mkdir -p "$T/r" && cd "$T/r" || exit 1
  git init -q -b master .
  git config user.name Human && git config user.email human@example.com
  mkdir -p stacks/app stacks/chart renovate stacks/docsonly
  touch stacks/app/terragrunt.hcl stacks/chart/terragrunt.hcl
  echo 'tag: v1.0.0' >stacks/app/values.yaml
  echo 'version = "1.0.0"' >stacks/chart/main.tf
  printf '{\n  "packageRules": []\n}\n' >renovate/ignored-versions.json
  git add -A && git commit -qm base
  BASE=$(git rev-parse HEAD)
  echo 'tag: v1.1.0' >stacks/app/values.yaml
  git add -A
  git -c user.name='Renovate Bot' -c user.email=renovate-bot@viktorbarzin.me commit -qm "app: bump ghcr.io/x/app v1.0.0 -> v1.1.0

Why: upstream released.

Renovate-Dep: docker ghcr.io/x/app v1.1.0
"
  R1=$(git rev-parse HEAD)
  echo 'note' >stacks/app/verify.sh
  git add -A && git commit -qm "human: verify script only"
  H1=$(git rev-parse HEAD)
  echo 'version = "1.2.0"' >stacks/chart/main.tf
  git add -A
  git -c user.name='Renovate Bot' -c user.email=renovate-bot@viktorbarzin.me commit -qm "chart: bump chart 1.0.0 -> 1.2.0

Renovate-Dep: helm chart 1.2.0
Renovate-Dep: docker example/sidecar sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
"
  R2=$(git rev-parse HEAD)
}

# --- pending_commits ---------------------------------------------------------
mkrepo
eq "pending: both renovate commits, oldest first" "$R1 $R2" "$(pending_commits "$BASE" HEAD | tr '\n' ' ' | sed 's/ $//')"
eq "pending: range starts after the marker" "$R2" "$(pending_commits "$H1" HEAD | tr '\n' ' ' | sed 's/ $//')"
git revert --no-edit "$R1" >/dev/null
eq "pending: a reverted renovate commit is no longer pending" "$R2" "$(pending_commits "$BASE" HEAD | tr '\n' ' ' | sed 's/ $//')"

# --- commit_stacks -----------------------------------------------------------
mkrepo
eq "stacks: renovate commit -> its stack" "app" "$(commit_stacks "$R1")"
eq "stacks: verify.sh-only commit applies nothing" "" "$(commit_stacks "$H1")"
eq "stacks: chart commit" "chart" "$(commit_stacks "$R2")"

# --- commit_deps -------------------------------------------------------------
eq "deps: one trailer" "docker ghcr.io/x/app v1.1.0" "$(commit_deps "$R1")"
eq "deps: two trailers" "2" "$(commit_deps "$R2" | wc -l | tr -d ' ')"
eq "deps: helm datasource detected" "yes" "$(commits_have_helm "$R1" "$R2" && echo yes || echo no)"
eq "deps: docker-only commit is not a chart change" "no" "$(commits_have_helm "$R1" && echo yes || echo no)"

# --- ignore entries ----------------------------------------------------------
f=renovate/ignored-versions.json
add_ignore_entries "$f" "$R2" "test reason" || bad "add_ignore_entries returned non-zero"
eq "ignore: two rules appended" "2" "$(jq '.packageRules | length' "$f")"
eq "ignore: version pin uses matchNewValue" '{"description":"test reason","matchDatasources":["helm"],"matchPackageNames":["chart"],"matchNewValue":"1.2.0","enabled":false}' "$(jq -c '.packageRules[0]' "$f")"
eq "ignore: digest pin disables digest updates for the package" '{"description":"test reason","matchDatasources":["docker"],"matchPackageNames":["example/sidecar"],"matchUpdateTypes":["digest"],"enabled":false}' "$(jq -c '.packageRules[1]' "$f")"
git checkout -q -- "$f"
eq "ignore: a commit without trailers adds nothing and fails" "1 0" "$(add_ignore_entries "$f" "$H1" x >/dev/null 2>&1; echo "$? $(jq '.packageRules|length' "$f")")"
eq "ignore: the real repo file stays valid JSON with packageRules" "array" "$(jq -r '.packageRules|type' "$REPO/renovate/ignored-versions.json")"

# --- revert_commit -----------------------------------------------------------
mkrepo
revert_commit fail "$R2" "chart failed its verify checks" "Snapshot: none" >/dev/null 2>&1 || bad "revert_commit fail returned non-zero"
eq "revert: tree back to the old version" 'version = "1.0.0"' "$(cat stacks/chart/main.tf)"
eq "revert: ignore entries in the same commit" "renovate/ignored-versions.json stacks/chart/main.tf" "$(git show --name-only --format= HEAD | sort | tr '\n' ' ' | sed 's/ $//')"
eq "revert: message names the reverted commit" "This reverts commit $R2." "$(git log -1 --format=%B | grep '^This reverts commit')"
eq "revert: authored by the CI identity" "ci@viktorbarzin.me" "$(git log -1 --format=%ae)"
eq "revert: subject" "Revert \"chart: bump chart 1.0.0 -> 1.2.0\"" "$(git log -1 --format=%s)"
eq "revert: not pending any more" "$R1" "$(pending_commits "$BASE" HEAD | tr '\n' ' ' | sed 's/ $//')"
revert_commit hold "$R1" "gate held" "Snapshot: none" >/dev/null 2>&1 || bad "revert_commit hold returned non-zero"
eq "hold: no ignore entry for a held bump" "2" "$(jq '.packageRules|length' renovate/ignored-versions.json)"
eq "hold: tree back to the old version" "tag: v1.0.0" "$(cat stacks/app/values.yaml)"
if git log -1 --format=%B | grep -qi 'ci skip'; then bad "revert commits must not skip CI"; else ok "revert commits do not skip CI"; fi

# A revert that conflicts fails cleanly and leaves other uncommitted work alone.
mkrepo
echo 'tag: v1.1.0-human' >stacks/app/values.yaml && git commit -qam "human edits the same line"
echo "uncommitted" >stacks/chart/notes.txt
before=$(git rev-parse HEAD)
eq "conflict: revert_commit fails" "1" "$(revert_commit fail "$R1" x y >/dev/null 2>&1; echo $?)"
eq "conflict: no commit made" "$before" "$(git rev-parse HEAD)"
eq "conflict: tree as before" "tag: v1.1.0-human" "$(cat stacks/app/values.yaml)"
eq "conflict: unrelated uncommitted file kept" "uncommitted" "$(cat stacks/chart/notes.txt 2>/dev/null)"

# --- marker base -------------------------------------------------------------
mkrepo
eq "base: marker that is an ancestor of HEAD" "$H1" "$(choose_base "$H1" "$R1" HEAD)"
eq "base: empty marker falls back to the diff base" "$R1" "$(choose_base "" "$R1" HEAD)"
eq "base: unknown marker falls back" "$R1" "$(choose_base 0000000000000000000000000000000000000000 "$R1" HEAD)"
git checkout -q -b side "$BASE" && echo x >other && git add other && git commit -qm side && SIDE=$(git rev-parse HEAD) && git checkout -q master
eq "base: marker on another lineage falls back" "$R1" "$(choose_base "$SIDE" "$R1" HEAD)"

# --- stages: catch-up after a cancelled Renovate pipeline ------------------
# R1 (app) was pushed by Renovate, its pipeline was cancelled by the human push
# H1, so H1's pipeline (diff base R1, not a renovate-bot push) must still pick
# up R1 from the marker and verify stack app.
mkrepo
git reset -q --hard "$H1"
mkdir -p scripts/verify
printf '#!/bin/bash\necho "stub verify $*"; exit ${STUB_VERIFY_RC:-0}\n' >scripts/verify/run
MARKER=$BASE SLACKED="" MARKED="" METRIC=""
get_marker() { echo "$MARKER"; }
set_marker() { MARKED=$1; }
gate_blocking() { echo "${STUB_GATE:-}"; }
snapshot_targets() { :; }
slack() { SLACKED=$1; }
push_metrics() { METRIC=$1; }
tg_apply() { echo "stub apply $1"; }
echo "$R1" >.diff_base; echo "" >.platform_stacks; : >.platform_apply; : >.app_apply; : >.platform_failed; : >.app_failed
CI_COMMIT_AUTHOR=viktor CI_COMMIT_SHA=$H1 stage_prepare >/dev/null
eq "catch-up: renovate commit from the cancelled pipeline is pending" "$R1" "$(cat .rails_commits)"
eq "catch-up: its stack is added to the apply list" "app" "$(cat .app_apply)"
eq "catch-up: mode verify" "verify" "$(cat .rails_mode)"
eq "catch-up: owned stacks" "app" "$(stage_owned)"
CI_COMMIT_SHA=$H1 STUB_VERIFY_RC=0 stage_finish >/dev/null
eq "catch-up: verified -> marker moves to HEAD" "$H1" "$MARKED"
eq "catch-up: verified -> outcome 0" "0" "$METRIC"
eq "catch-up: verified -> no failure exit" "0" "$(stage_exit >/dev/null; echo $?)"

# Same, but verify fails: revert + ignore entry, marker moves past it.
MARKED="" SLACKED=""
CI_COMMIT_SHA=$H1 stage_prepare >/dev/null
CI_COMMIT_SHA=$H1 STUB_VERIFY_RC=1 stage_finish >/dev/null
eq "verify fail: revert commit on top" "This reverts commit $R1." "$(git log -1 --format=%B | grep '^This reverts')"
eq "verify fail: ignore entry for the exact version" "v1.1.0" "$(jq -r '.packageRules[0].matchNewValue' renovate/ignored-versions.json)"
eq "verify fail: app back on the old tag" "tag: v1.0.0" "$(cat stacks/app/values.yaml)"
case "$SLACKED" in *"reverted"*"ghcr.io/x/app v1.1.0"*) ok "verify fail: Slack names the ignored version" ;; *) bad "verify fail: Slack names the ignored version" "$SLACKED" ;; esac
eq "verify fail: marker moves (the commit is handled)" "$H1" "$MARKED"
eq "verify fail: outcome 1" "1" "$METRIC"
eq "verify fail: pipeline exits non-zero" "1" "$(stage_exit >/dev/null; echo $?)"

# Apply failure of a rails-owned stack goes the same way, without running verify.
mkrepo; git reset -q --hard "$R1"; mkdir -p scripts/verify
printf '#!/bin/bash\necho SHOULD-NOT-RUN; exit 0\n' >scripts/verify/run
echo "$BASE" >.diff_base; : >.platform_apply; : >.app_apply; : >.platform_failed; echo " app" >.app_failed; MARKER=""
CI_COMMIT_AUTHOR=renovate-bot CI_COMMIT_SHA=$R1 stage_prepare >/dev/null
out=$(CI_COMMIT_SHA=$R1 stage_finish)
case "$out" in *SHOULD-NOT-RUN*) bad "apply fail: verify skipped" ;; *) ok "apply fail: verify skipped" ;; esac
eq "apply fail: reverted" "This reverts commit $R1." "$(git log -1 --format=%B | grep '^This reverts')"

# Gate blocked: hold = revert without ignore entry, applied by the normal loop.
mkrepo; git reset -q --hard "$R1"
echo "$BASE" >.diff_base; : >.platform_apply; echo app >.app_apply; : >.platform_failed; : >.app_failed; MARKER="" MARKED=""
RAILS_GATE_WAIT=0 GATE_WAIT=0 STUB_GATE=NodeDown CI_COMMIT_AUTHOR=renovate-bot CI_COMMIT_SHA=$R1 stage_prepare >/dev/null
eq "hold: mode" "hold" "$(cat .rails_mode)"
eq "hold: reverted before the apply" "tag: v1.0.0" "$(cat stacks/app/values.yaml)"
eq "hold: no ignore entry" "0" "$(jq '.packageRules|length' renovate/ignored-versions.json)"
eq "hold: stack still applied (reverted tree)" "app" "$(cat .app_apply)"
eq "hold: nothing owned" "" "$(stage_owned)"
CI_COMMIT_SHA=$R1 stage_finish >/dev/null
eq "hold: outcome 2" "2" "$METRIC"
eq "hold: pipeline stays green" "0" "$(stage_exit >/dev/null; echo $?)"

# No Renovate commits: nothing to do, marker moves.
mkrepo; git reset -q --hard "$H1"; echo "$R1" >.diff_base; MARKER=$R1 MARKED=""
CI_COMMIT_AUTHOR=viktor CI_COMMIT_SHA=$H1 stage_prepare >/dev/null
eq "idle: no commits" "" "$(cat .rails_commits)"
CI_COMMIT_SHA=$H1 stage_finish >/dev/null
eq "idle: marker moves" "$H1" "$MARKED"

# --- gate --------------------------------------------------------------------
cd "$REPO" || exit 1
chain=$(gate_chain_alerts)
# Independent parse: every quoted fragment of the assignment, joined.
want=$(sed -n '/^UPGRADE_GATE_ALERTS=/,/[^\\]$/p' stacks/k8s-version-upgrade/scripts/upgrade-step.sh | grep -o "'[^']*'" | tr -d "'\n")
eq "gate: chain allowlist parsed from upgrade-step.sh" "$want" "$chain"
case "|$chain|" in *"|NodeDown|"*"|TraefikDown|"*) ok "gate: allowlist has NodeDown and TraefikDown" ;; *) bad "gate: allowlist has NodeDown and TraefikDown" "$chain" ;; esac
case "$chain" in *[!A-Za-z0-9\|]*) bad "gate: chain allowlist has unexpected characters" "$chain" ;; *) ok "gate: chain allowlist is names and pipes only" ;; esac
kured=$(gate_kured_regex)
case "$kured" in '^('*')$') ok "gate: kured alertFilterRegexp parsed" ;; *) bad "gate: kured alertFilterRegexp parsed" "$kured" ;; esac
alerts='{"data":{"alerts":[
 {"state":"firing","labels":{"alertname":"NodeDown","severity":"critical"}},
 {"state":"firing","labels":{"alertname":"BankSyncConsentExpired","severity":"critical"}},
 {"state":"pending","labels":{"alertname":"TraefikDown","severity":"critical"}},
 {"state":"firing","labels":{"alertname":"PostgreSQLDown","severity":"warning"}},
 {"state":"firing","labels":{"alertname":"NodeDiskPressure","severity":"warning"}}]}}'
eq "gate: allowlisted firing criticals and kured names block; others do not" "NodeDiskPressure NodeDown" "$(gate_match "$chain" "$kured" <<<"$alerts" | tr '\n' ' ' | sed 's/ $//')"
eq "gate: empty allowlist fails closed (every firing critical blocks)" "BankSyncConsentExpired NodeDown" "$(gate_match "" "" <<<"$alerts" | tr '\n' ' ' | sed 's/ $//')"
eq "gate: nothing firing" "" "$(gate_match "$chain" "$kured" <<<'{"data":{"alerts":[]}}')"

echo
echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
