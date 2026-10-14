#!/bin/bash
# Tests for the verify floor's namespace scope: scripts/verify/stack-namespaces
# (which namespaces a stack without verify.sh is checked in) and floor_scope /
# floor_rollout in scripts/verify/lib.sh (a floor that finds nothing to check
# fails instead of passing), and expect_no_log_errors_after_start (log errors
# from a container's startup window are ignored, later ones fail). kubectl is
# replaced by a stub; no cluster access.
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

# --- expect_no_log_errors_after_start -----------------------------------------
# The stub serves one Traefik pod whose traefik container started at 00:03:46
# and returns $LOGS (kubectl logs --prefix --timestamps format) for "logs".
run_after_start() { # <regex> <grace> -> prints the helper output, then "rc=N"
  (
    # shellcheck source=lib.sh
    . "$HERE/lib.sh"
    k() {
      case "$1" in
        get) echo '{"items":[{"metadata":{"name":"traefik-a"},"status":{"containerStatuses":[
          {"name":"traefik","state":{"running":{"startedAt":"2026-10-12T00:03:46Z"}}},
          {"name":"node-exporter","state":{"running":{"startedAt":"2026-10-12T00:03:40Z"}}}]}}]}' ;;
        logs) printf '%s\n' "$LOGS" ;;
        *) return 1 ;;
      esac
    }
    expect_no_log_errors_after_start traefik app=traefik "$1" "$2"
    echo "rc=$?"
  )
}
L_START='[pod/traefik-a/traefik] 2026-10-12T00:03:46.512Z ERR error="middleware \"traefik-anti-ai-headers@kubernetescrd\" does not exist"'
L_EDGE='[pod/traefik-a/traefik] 2026-10-12T00:04:45.900Z ERR error="middleware \"traefik-csp-headers@kubernetescrd\" does not exist"'
L_LATE='[pod/traefik-a/traefik] 2026-10-12T00:09:02.100Z ERR error="middleware \"traefik-broken@kubernetescrd\" does not exist"'
L_OTHER='[pod/traefik-b/traefik] 2026-10-12T00:03:47.000Z ERR error="middleware \"traefik-x@kubernetescrd\" does not exist"'
L_INFO='[pod/traefik-a/traefik] 2026-10-12T00:09:03.000Z INF Configuration loaded'
RE='middleware.*does not exist'

out=$(LOGS="$L_START"$'\n'"$L_EDGE"$'\n'"$L_INFO" run_after_start "$RE" 60)
eq "errors inside the startup grace window pass" "rc=0" "$(tail -1 <<<"$out")"

out=$(LOGS="$L_START"$'\n'"$L_LATE" run_after_start "$RE" 60)
eq "an error after the grace window fails" "rc=1" "$(tail -1 <<<"$out")"
grep -q "traefik-broken" <<<"$out" && ok "the late error is reported" || bad "late error output: $out"
grep -q "anti-ai-headers" <<<"$out" && bad "startup error reported: $out" || ok "the startup error is not reported"

out=$(LOGS="$L_OTHER" run_after_start "$RE" 60)
eq "a container with no known start time is not excused" "rc=1" "$(tail -1 <<<"$out")"

out=$(LOGS="$L_START" run_after_start "$RE" 0)
eq "grace 0 behaves like expect_no_log_errors" "rc=1" "$(tail -1 <<<"$out")"

# --- check names carry the workload ----------------------------------------------
# The Renovate rails compare failed check names before and after a bump, so a
# name must say which workload failed, not only which floor.
run_floor_broken() { # like run_floor, but app never converges and its pod crash-loops
  (
    # shellcheck source=lib.sh
    . "$HERE/lib.sh"
    log() { echo "$*"; }
    k() {
      local ns="" a
      for a in "$@"; do [ "${prev:-}" = "-n" ] && ns=$a; prev=$a; done
      case "$1 $2" in
        "get deploy,statefulset,daemonset") echo "{\"items\":[$DEP]}" ;;
        "get pods") echo '{"items":[{"metadata":{"name":"app-7d9f8c6b5-abcde","labels":{"pod-template-hash":"7d9f8c6b5"},"ownerReferences":[{"kind":"ReplicaSet","name":"app-7d9f8c6b5"}]},
          "status":{"containerStatuses":[{"name":"app","state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}' ;;
        *) return 1 ;;
      esac
    }
    workload_ready() { echo "$2 not converged"; return 1; }
    export VERIFY_ROLLOUT_TIMEOUT=0
    "$1"
    printf 'check=%s\n' "${FAILED_CHECKS[@]}"
  )
}
out=$(VERIFY_NAMESPACES="x" run_floor_broken floor_rollout)
grep -qx "check=floor: rollout x/Deployment/app" <<<"$out" && ok "rollout failure names the workload" || bad "rollout failure name: $out"
grep -qx "check=floor: unhealthy pod x/app" <<<"$out" && ok "crash-looping pod failure names its workload" || bad "unhealthy pod name: $out"

# --- floor_ingress grace ------------------------------------------------------------
# An app without a readiness probe answers 502 until it listens. The floor
# retries for VERIFY_INGRESS_GRACE seconds before failing (aiostreams needed
# ~45 s on 2026-10-14; the old 3 tries x 5 s gave it 15).
run_ingress() { # prints the log, then "passed=N failed=M calls=C"
  (
    # shellcheck source=lib.sh
    . "$HERE/lib.sh"
    log() { echo "$*"; }
    sleep() { :; }
    k() {
      case "$1 $2" in
        "get ingress") echo '{"items":[{"metadata":{"name":"aiostreams"},"spec":{"rules":[{"host":"aiostreams.example","http":{"paths":[{"path":"/"}]}}]}}]}' ;;
        *) return 1 ;;
      esac
    }
    traefik_ip() { echo 10.0.0.1; }
    backend_parked() { return 1; }
    CALLS=$WORK/calls; : >"$CALLS"
    # 502 for the first $BAD_CALLS requests, then 200. date advances 10 s per call.
    via_traefik() { echo x >>"$CALLS"; [ "$(wc -l <"$CALLS")" -gt "${BAD_CALLS:-0}" ] && echo 200 || echo 502; }
    date() { if [ "${1:-}" = +%s ]; then echo $((1000 + 10 * $(wc -l <"$CALLS"))); else command date "$@"; fi; }
    VERIFY_NAMESPACES=aiostreams
    floor_ingress
    echo "passed=$PASS_COUNT failed=$FAIL_COUNT calls=$(wc -l <"$CALLS")"
  )
}
out=$(BAD_CALLS=5 VERIFY_INGRESS_GRACE=180 run_ingress)
eq "ingress: a slow starter passes inside the grace" "passed=1 failed=0 calls=6" "$(tail -1 <<<"$out")"
out=$(BAD_CALLS=1000 VERIFY_INGRESS_GRACE=60 run_ingress)
case "$(tail -1 <<<"$out")" in "passed=0 failed=1 calls="*) ok "ingress: still 502 after the grace fails" ;; *) bad "ingress grace exhausted: $out" ;; esac
[ "$(tail -1 <<<"$out" | sed 's/.*calls=//')" -le 8 ] && ok "ingress: stops retrying at the grace deadline" || bad "ingress retried past the deadline: $out"
grep -q "FAIL  floor: ingress aiostreams/aiostreams" <<<"$out" && ok "ingress failure names the route" || bad "ingress failure name: $out"
out=$(BAD_CALLS=1000 VERIFY_BASELINE=1 run_ingress)
eq "ingress: a baseline run looks once" "passed=0 failed=1 calls=1" "$(tail -1 <<<"$out")"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
