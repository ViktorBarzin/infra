#!/bin/bash
# Tests for the verify floor's namespace scope: scripts/verify/stack-namespaces
# (which namespaces a stack without verify.sh is checked in) and floor_scope /
# floor_rollout in scripts/verify/lib.sh (a floor that finds nothing to check
# fails instead of passing). kubectl is replaced by a stub; no cluster access.
# Run: bash scripts/verify/verify.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$2] got [$3]"; fi; }

# --- stack-namespaces ---------------------------------------------------------
stack() { mkdir -p "$WORK/stacks/$1"; cat >"$WORK/stacks/$1/main.tf"; }

stack literal <<'TF'
resource "kubernetes_namespace" "website" {
  metadata {
    name = "website"
  }
}
TF
eq "literal namespace name" "website" "$("$HERE/stack-namespaces" "$WORK/stacks/literal")"

stack viaLocal <<'TF'
locals {
  namespace = "claude-agent" # comment
}
resource "kubernetes_namespace" "claude_agent" {
  metadata {
    name = local.namespace
  }
}
resource "kubernetes_secret" "x" {
  metadata {
    namespace = "monitoring"
  }
  env {
    name = "JITTER_SECONDS"
  }
}
TF
eq "name from locals, other string assignments ignored" "claude-agent" "$("$HERE/stack-namespaces" "$WORK/stacks/viaLocal")"

stack viaVar <<'TF'
variable "ns" {
  type    = string
  default = "osm-routing"
}
resource "kubernetes_namespace_v1" "osm" {
  metadata {
    name = var.ns
  }
}
TF
eq "name from a variable default" "osm-routing" "$("$HERE/stack-namespaces" "$WORK/stacks/viaVar")"

stack twoNs <<'TF'
resource "kubernetes_namespace" "a" {
  metadata {
    name = "servarr"
  }
}
TF
mkdir -p "$WORK/stacks/twoNs/aiostreams"
printf 'resource "kubernetes_namespace" "b" {\n  metadata {\n    name = "aiostreams"\n  }\n}\n' >"$WORK/stacks/twoNs/aiostreams/main.tf"
eq "namespaces in stack-local modules" "aiostreams servarr" "$("$HERE/stack-namespaces" "$WORK/stacks/twoNs")"

stack noNsResource <<'TF'
resource "kubernetes_daemonset" "node_cache" {
  metadata {
    name      = "node-local-dns"
    namespace = "kube-system"
  }
}
TF
eq "no namespace resource: literal namespace values" "kube-system" "$("$HERE/stack-namespaces" "$WORK/stacks/noNsResource")"

stack nothing <<'TF'
resource "cloudflare_record" "r" {
  name = "x"
}
TF
eq "no namespace at all: empty" "" "$("$HERE/stack-namespaces" "$WORK/stacks/nothing")"

# --- floor_scope / floor_rollout ------------------------------------------------
# The stub serves namespaces listed in $EXIST, with $OBJS_<ns> as the
# deploy/sts/ds items and $CRON_<ns> as the CronJob count.
run_floor() { # <fn> -> prints the log, then "passed=N failed=M ns=[...]"
  (
    # shellcheck source=lib.sh
    . "$HERE/lib.sh"
    log() { echo "$*"; }
    k() {
      local ns="" a
      for a in "$@"; do [ "${prev:-}" = "-n" ] && ns=$a; prev=$a; done
      case "$1 $2" in
        "get namespace") [[ " $EXIST " == *" $3 "* ]] ;;
        "get deploy,statefulset,daemonset") v="OBJS_${ns//-/_}"; echo "{\"items\":[${!v:-}]}" ;;
        "get cronjob") v="CRON_${ns//-/_}"; for _ in $(seq "${!v:-0}"); do echo "cj"; done ;;
        "get pods") echo '{"items":[]}' ;;
        *) return 1 ;;
      esac
    }
    workload_ready() { echo "$1 $2 ready"; }
    export VERIFY_ROLLOUT_TIMEOUT=0
    "$1"
    echo "passed=$PASS_COUNT failed=$FAIL_COUNT ns=[$VERIFY_NAMESPACES]"
  )
}
DEP='{"kind":"Deployment","metadata":{"name":"app"}}'

out=$(EXIST="servarr aiostreams" VERIFY_NAMESPACES="aiostreams readarr servarr" VERIFY_NAMESPACES_DERIVED=1 run_floor floor_scope)
eq "derived scope drops a namespace that does not exist" "passed=1 failed=0 ns=[aiostreams servarr]" "$(tail -1 <<<"$out")"

out=$(EXIST="claude-agent" VERIFY_NAMESPACES="claude-agent-service" VERIFY_NAMESPACES_DERIVED=1 run_floor floor_scope)
eq "derived scope with no existing namespace fails" "passed=0 failed=1 ns=[claude-agent-service]" "$(tail -1 <<<"$out")"

out=$(EXIST="traefik" VERIFY_NAMESPACES="traefik gone" run_floor floor_scope)
eq "a missing namespace named by verify.sh fails" "passed=0 failed=1 ns=[traefik gone]" "$(tail -1 <<<"$out")"

out=$(EXIST="x" VERIFY_NAMESPACES="x" run_floor floor_rollout)
eq "rollout with no workload and no CronJob fails" "passed=1 failed=1 ns=[x]" "$(tail -1 <<<"$out")"
grep -q "checked nothing" <<<"$out" && ok "empty rollout says it checked nothing" || bad "empty rollout message: $out"

out=$(EXIST="keel" VERIFY_NAMESPACES="keel" VERIFY_EMPTY_OK=1 run_floor floor_rollout)
eq "VERIFY_EMPTY_OK=1 lets an empty namespace pass" "passed=2 failed=0 ns=[keel]" "$(tail -1 <<<"$out")"

out=$(EXIST="cj" VERIFY_NAMESPACES="cj" CRON_cj=2 run_floor floor_rollout)
eq "CronJob-only namespace passes" "passed=2 failed=0 ns=[cj]" "$(tail -1 <<<"$out")"

out=$(EXIST="claude-agent" VERIFY_NAMESPACES="claude-agent" OBJS_claude_agent="$DEP" run_floor floor_rollout)
eq "namespace with a workload passes" "passed=2 failed=0 ns=[claude-agent]" "$(tail -1 <<<"$out")"
grep -q "1 workloads converged in claude-agent" <<<"$out" && ok "rollout counts the workload" || bad "rollout count: $out"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
