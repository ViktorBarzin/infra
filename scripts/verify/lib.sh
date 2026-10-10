# shellcheck shell=bash
# Shared library for stack verify scripts. Sourced inside the verify Job pod by
# entrypoint.sh, before the stack's own stacks/<stack>/verify.sh.
#
# Runtime: ghcr.io/viktorbarzin/infra-ci (bash, curl, jq, kubectl, python3),
# ServiceAccount verify/verify-runner (read-only cluster-wide except Secrets,
# plus the narrow writes in stacks/verify/main.tf).
#
# Contract and how to add a check: docs/runbooks/verify-jobs.md.

PROM_URL=${VERIFY_PROM_URL:-http://prometheus-server.monitoring.svc.cluster.local}
VERIFY_OWN_NS=${VERIFY_OWN_NS:-verify}
TRAEFIK_SVC=${VERIFY_TRAEFIK_SVC:-traefik/traefik}
# Sent with every HTTP probe. Sablier ignores user agents matching
# "blackbox", so a probe never wakes an app parked at 0 replicas (a plain curl
# woke affine for its 3h session on the first run).
VERIFY_UA=${VERIFY_UA:-homelab-verify/1 (blackbox probe; docs/runbooks/verify-jobs.md)}

# Alerts never counted by the floor: Trivy findings follow image scans rather
# than the health of the change, and Watchdog/InfoInhibitor always fire.
VERIFY_ALERT_IGNORE_DEFAULT='^(Trivy.*|Watchdog|InfoInhibitor)$'

PASS_COUNT=0
FAIL_COUNT=0
FAILED_CHECKS=()

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
section() { printf '\n== %s\n' "$*"; }

pass() { PASS_COUNT=$((PASS_COUNT + 1)); log "PASS  $1${2:+  [$2]}"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_CHECKS+=("$1"); log "FAIL  $1${2:+  [$2]}"; }

_oneline() { tr '\n' ' ' | tr -s ' ' | cut -c1-"${1:-400}"; }

# check "<name>" <command...>
# Runs the command; exit 0 is a pass. The command's output (trimmed) is shown
# next to the verdict, so make checks print the value they judged.
check() {
  local name=$1 out rc
  shift
  out=$("$@" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "$name" "$(printf '%s' "$out" | tail -c 400 | _oneline 300)"
  else
    fail "$name" "$(printf '%s' "$out" | tail -c 900 | _oneline 700)"
  fi
  return 0
}

# retry <timeout-seconds> <interval-seconds> <command...>
# Re-runs the command until it succeeds or the timeout passes. Prints the
# output of the last attempt. Used for conditions that settle after a change.
retry() {
  local timeout=$1 interval=$2 deadline out rc
  shift 2
  deadline=$(($(date +%s) + timeout))
  while :; do
    out=$("$@" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] || [ "$(date +%s)" -ge "$deadline" ]; then
      printf '%s\n' "$out"
      return "$rc"
    fi
    sleep "$interval"
  done
}

k() { kubectl "$@"; }

# iso_epoch <RFC 3339 timestamp> -> epoch seconds (busybox date cannot parse
# Kubernetes timestamps, jq can)
iso_epoch() {
  jq -rn --arg t "$1" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601'
}

# age_seconds <RFC 3339 timestamp>
age_seconds() {
  echo $(($(date +%s) - $(iso_epoch "$1")))
}

# ---------------------------------------------------------------------------
# Prometheus
# ---------------------------------------------------------------------------

# prom_json <promql> -> the .data.result array
prom_json() {
  curl -sS --fail --max-time 30 "$PROM_URL/api/v1/query" --data-urlencode "query=$1" | jq -c '.data.result'
}

# prom_value <promql> -> the first sample value, empty when there is none
prom_value() {
  prom_json "$1" | jq -r '.[0].value[1] // empty'
}

# prom_count <promql> -> number of series
prom_count() {
  prom_json "$1" | jq -r 'length'
}

# expect_prom <promql> <op> <number>
# op is one of -eq -ne -ge -gt -le -lt (compared as floats).
expect_prom() {
  local q=$1 op=$2 want=$3 v
  v=$(prom_value "$q") || { echo "query failed: $q"; return 1; }
  if [ -z "$v" ]; then echo "no series: $q"; return 1; fi
  echo "value=$v want $op $want"
  python3 - "$v" "$op" "$want" <<'PY'
import sys
v, op, w = float(sys.argv[1]), sys.argv[2], float(sys.argv[3])
ok = {"-eq": v == w, "-ne": v != w, "-ge": v >= w, "-gt": v > w, "-le": v <= w, "-lt": v < w}[op]
sys.exit(0 if ok else 1)
PY
}

# expect_series <promql> <min-count>
expect_series() {
  local n
  n=$(prom_count "$1") || return 1
  echo "series=$n want >= $2"
  [ "$n" -ge "$2" ]
}

# ---------------------------------------------------------------------------
# Kubernetes helpers
# ---------------------------------------------------------------------------

# pod_of <ns> <label-selector> -> name of the first Running pod
pod_of() {
  k get pods -n "$1" -l "$2" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# meta_list <api path> -> PartialObjectMetadataList JSON (metadata only), for
# resources whose full objects are too large to list in a 512Mi pod
# (VulnerabilityReports run to hundreds of MB).
meta_list() {
  local tok
  tok=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  curl -sS --max-time 60 --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    -H "Authorization: Bearer $tok" \
    -H 'Accept: application/json;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1' \
    "https://kubernetes.default.svc$1"
}

# images_of <ns> <kind/name> -> container images of the pod template
images_of() {
  k get -n "$1" "$2" -o jsonpath='{.spec.template.spec.containers[*].image}'
}

# Helm release status is not checked here: Helm keeps it in Secrets, which the
# verify ServiceAccount cannot read. The apply itself covers it (every
# helm_release is atomic=true, so a failed upgrade fails the apply).

# workload_ready <ns> <kind>/<name>
# Converged: the controller has seen the latest spec and every replica is
# updated and ready. StatefulSets and DaemonSets with OnDelete skip the
# revision test (Vault rolls by hand).
workload_ready() {
  local ns=$1 obj=$2 j
  j=$(k get -n "$ns" "$obj" -o json) || return 1
  jq -r --arg o "$obj" '
    def conv:
      if .kind == "Deployment" then
        ((.spec.replicas // 1) == 0) or
        ((.status.observedGeneration // 0) >= .metadata.generation
         and (.status.updatedReplicas // 0) == (.spec.replicas // 1)
         and (.status.readyReplicas // 0) == (.spec.replicas // 1)
         and (.status.availableReplicas // 0) == (.spec.replicas // 1)
         and ((.status.replicas // 0) == (.spec.replicas // 1)))
      elif .kind == "StatefulSet" then
        ((.spec.replicas // 1) == 0) or
        ((.status.observedGeneration // 0) >= .metadata.generation
         and (.status.readyReplicas // 0) == (.spec.replicas // 1)
         and ((.spec.updateStrategy.type // "RollingUpdate") == "OnDelete"
              or ((.status.updatedReplicas // 0) == (.spec.replicas // 1)
                  and (.status.currentRevision == .status.updateRevision))))
      elif .kind == "DaemonSet" then
        ((.status.observedGeneration // 0) >= .metadata.generation
         and (.status.numberReady // 0) == (.status.desiredNumberScheduled // 0)
         and ((.spec.updateStrategy.type // "RollingUpdate") == "OnDelete"
              or (.status.updatedNumberScheduled // 0) == (.status.desiredNumberScheduled // 0)))
      else true end;
    if conv then "\($o) ready" else "\($o) not converged: \(.status | tostring | .[0:300])" end,
    (if conv then 0 else 1 end)' <<<"$j" | {
    read -r msg
    read -r code
    echo "$msg"
    return "$code"
  }
}

# list_workloads <ns...> -> "ns kind/name" lines for deploy, sts, ds
list_workloads() {
  local ns
  for ns in "$@"; do
    k get deploy,statefulset,daemonset -n "$ns" -o json 2>/dev/null |
      jq -r --arg ns "$ns" '.items[] | "\($ns) \(.kind)/\(.metadata.name)"'
  done
}

# bad_pods <ns...> -> pods stuck in CrashLoopBackOff / image pull errors / Pending > 5m
bad_pods() {
  local ns
  for ns in "$@"; do
    k get pods -n "$ns" -o json 2>/dev/null | jq -r --arg ns "$ns" '
      .items[] |
      select(.metadata.labels["app.kubernetes.io/managed-by"] != "verify") |
      [ (.status.containerStatuses // [] + (.status.initContainerStatuses // []))[]
        | select(.state.waiting.reason? // "" | test("CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|InvalidImageName"))
        | "\($ns)/\(.name) container \(.name): \(.state.waiting.reason)" ] as $w |
      if ($w | length) > 0 then $w[] else empty end'
  done
}

# expect_workload <ns> <kind/name> <image-substring>
# Workload converged and its template carries an image containing the string.
expect_workload_image() {
  local ns=$1 obj=$2 want=$3 imgs
  workload_ready "$ns" "$obj" || return 1
  imgs=$(images_of "$ns" "$obj")
  echo "images: $imgs"
  case "$imgs" in *"$want"*) return 0 ;; *) echo "expected image containing $want"; return 1 ;; esac
}

# http_code <url> [curl args...] -> prints the HTTP status code
http_code() {
  local url=$1
  shift
  curl -sk -A "$VERIFY_UA" -o /dev/null -w '%{http_code}' --max-time 20 "$@" "$url"
}

# expect_http <url> <code-regex> [curl args...]
expect_http() {
  local url=$1 want=$2 code
  shift 2
  code=$(http_code "$url" "$@")
  echo "$url -> $code (want $want)"
  [[ "$code" =~ ^($want)$ ]]
}

# expect_body <url> <grep -E regex> [curl args...]
expect_body() {
  local url=$1 re=$2 body
  shift 2
  body=$(curl -sk -A "$VERIFY_UA" --max-time 30 "$@" "$url") || { echo "request failed: $url"; return 1; }
  if grep -Eq -- "$re" <<<"$body"; then
    echo "$url matches /$re/"
  else
    echo "$url body did not match /$re/: $(printf '%s' "$body" | head -c 300)"
    return 1
  fi
}

traefik_ip() {
  k get svc -n "${TRAEFIK_SVC%%/*}" "${TRAEFIK_SVC##*/}" -o jsonpath='{.spec.clusterIP}'
}

# via_traefik <host> <path> [curl args...] -> status code of https://host/path
# sent to the in-cluster Traefik Service, so the check exercises the ingress
# route without depending on external DNS or Cloudflare.
via_traefik() {
  local host=$1 path=$2 ip
  shift 2
  ip=${_TRAEFIK_IP:-$(traefik_ip)}
  curl -sk -A "$VERIFY_UA" -o /dev/null -w '%{http_code}' --max-time 20 --resolve "$host:443:$ip" "$@" "https://$host$path"
}

# expect_ingress <host> <path> <code-regex> [curl args...]
expect_ingress() {
  local host=$1 path=$2 want=$3 code
  shift 3
  code=$(via_traefik "$host" "$path" "$@")
  echo "https://$host$path -> $code (want $want)"
  [[ "$code" =~ ^($want)$ ]]
}

# tcp_open <host> <port>
tcp_open() {
  if timeout 5 bash -c "</dev/tcp/$1/$2" 2>/dev/null; then
    echo "$1:$2 open"
  else
    echo "$1:$2 closed"
    return 1
  fi
}

# backend_parked <ns> <ingress>
# True when the ingress's backend Service has no ready endpoint, which is how
# a parked app (Deployment at 0 replicas, by hand or by Sablier) looks. A 503
# from such a route is expected; a crashed app is caught by the workload check
# instead, because its Deployment still asks for replicas it cannot make ready.
backend_parked() {
  local svc n
  svc=$(k get ingress -n "$1" "$2" -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}' 2>/dev/null)
  [ -n "$svc" ] || return 1
  n=$(k get endpointslices -n "$1" -l "kubernetes.io/service-name=$svc" -o json 2>/dev/null |
    jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length')
  [ "${n:-1}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Pods and Jobs the checks start
# ---------------------------------------------------------------------------

# Owner reference to this verify Job, so everything a check creates is garbage
# collected when the TTL controller deletes the finished Job.
_owner_json() {
  if [ -n "${VERIFY_JOB_UID:-}" ]; then
    printf '[{"apiVersion":"batch/v1","kind":"Job","name":"%s","uid":"%s"}]' "$VERIFY_JOB_NAME" "$VERIFY_JOB_UID"
  else
    printf '[]'
  fi
}

# run_pod <suffix> <image> <script> [key=value options...]
# Runs <script> with /bin/sh -c in a one-off pod in the verify namespace and
# prints its log. Exit status is the container's exit code.
# Options:
#   secret=<name>        envFrom this Secret (credentials from ESO)
#   gpu=1                request one nvidia.com/gpu slot on the GPU node
#   timeout=<seconds>    default 300
#   pvc=<name>           mount this PVC at /data
#   cpu=<q> memory=<q>   resource requests (memory is also the limit)
#   command=<shell>      shell to run the script with (default /bin/sh)
#   rm=1                 delete the pod once its log is read. Needed for pods
#                        that mount a PVC: a Completed pod still holds the PVC
#                        against deletion (pvc-protection).
run_pod() {
  local suffix=$1 image=$2 script=$3
  shift 3
  local secret="" gpu="" timeout=300 pvc="" cpu="20m" memory="128Mi" shell="/bin/sh" rm="" opt
  for opt in "$@"; do
    case "$opt" in
      secret=*) secret=${opt#secret=} ;;
      gpu=*) gpu=${opt#gpu=} ;;
      timeout=*) timeout=${opt#timeout=} ;;
      pvc=*) pvc=${opt#pvc=} ;;
      cpu=*) cpu=${opt#cpu=} ;;
      memory=*) memory=${opt#memory=} ;;
      command=*) shell=${opt#command=} ;;
      rm=*) rm=${opt#rm=} ;;
    esac
  done
  local name
  name=$(printf '%s-%s' "${VERIFY_JOB_NAME:-verify-adhoc}" "$suffix" | tr '[:upper:]_' '[:lower:]-' | cut -c1-63 | sed 's/-*$//')
  local spec
  spec=$(jq -n \
    --arg name "$name" --arg ns "$VERIFY_OWN_NS" --arg image "$image" --arg script "$script" \
    --arg secret "$secret" --arg gpu "$gpu" --arg pvc "$pvc" --arg cpu "$cpu" --arg mem "$memory" \
    --arg shell "$shell" --arg stack "${VERIFY_STACK:-adhoc}" --argjson owner "$(_owner_json)" '
    {
      apiVersion: "v1", kind: "Pod",
      metadata: {
        name: $name, namespace: $ns, ownerReferences: $owner,
        labels: {"app.kubernetes.io/managed-by": "verify", "verify/stack": $stack}
      },
      spec: {
        restartPolicy: "Never",
        automountServiceAccountToken: false,
        terminationGracePeriodSeconds: 5,
        containers: [{
          name: "probe", image: $image, imagePullPolicy: "IfNotPresent",
          command: [$shell, "-c", $script],
          resources: {requests: {cpu: $cpu, memory: $mem}, limits: {memory: $mem}}
        }]
      }
    }
    | if $secret != "" then .spec.containers[0].envFrom = [{secretRef: {name: $secret}}] else . end
    | if $pvc != "" then
        .spec.volumes = [{name: "data", persistentVolumeClaim: {claimName: $pvc}}]
        | .spec.containers[0].volumeMounts = [{name: "data", mountPath: "/data"}]
      else . end
    | if $gpu != "" then
        .spec.nodeSelector = {"nvidia.com/gpu.present": "true"}
        | .spec.tolerations = [{key: "nvidia.com/gpu", operator: "Exists", effect: "NoSchedule"}]
        | .spec.containers[0].resources.requests["nvidia.com/gpu"] = $gpu
        | .spec.containers[0].resources.limits["nvidia.com/gpu"] = $gpu
      else . end')
  # A pod of this name exists only when a replacement Job pod reruns a check
  # (preemption). Delete only then: K8sMassDelete counts every delete request,
  # including ones that find nothing.
  if k get pod -n "$VERIFY_OWN_NS" "$name" -o name >/dev/null 2>&1; then
    k delete pod -n "$VERIFY_OWN_NS" "$name" --wait=true >/dev/null 2>&1
  fi
  if ! printf '%s' "$spec" | k create -f - >/dev/null; then
    echo "could not create pod $name"
    return 1
  fi
  local deadline phase
  deadline=$(($(date +%s) + timeout))
  while :; do
    phase=$(k get pod -n "$VERIFY_OWN_NS" "$name" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$phase" in Succeeded | Failed) break ;; esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "pod $name still $phase after ${timeout}s"
      k get pod -n "$VERIFY_OWN_NS" "$name" -o jsonpath='{.status.conditions}{"\n"}{.status.containerStatuses[0].state}' 2>/dev/null
      k logs -n "$VERIFY_OWN_NS" "$name" --tail=30 2>/dev/null
      k delete pod -n "$VERIFY_OWN_NS" "$name" --wait=false >/dev/null 2>&1
      return 1
    fi
    sleep 3
  done
  k logs -n "$VERIFY_OWN_NS" "$name" 2>/dev/null
  local code
  code=$(k get pod -n "$VERIFY_OWN_NS" "$name" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')
  [ -n "$rm" ] && k delete pod -n "$VERIFY_OWN_NS" "$name" --wait=true --timeout=60s >/dev/null 2>&1
  [ "${code:-1}" -eq 0 ]
}

# run_cronjob <ns> <cronjob> [timeout-seconds]
# Starts a one-off Job from a CronJob (the backup run the design asks for),
# waits for it, prints its log tail, and deletes it on success. A failed run is
# left in place for inspection (BackupCronJobFailed will name it).
run_cronjob() {
  local ns=$1 cj=$2 timeout=${3:-1800} job
  job="$cj-verify-$(date +%s)"
  job=${job:0:63}
  k create job -n "$ns" --from="cronjob/$cj" "$job" >/dev/null || { echo "cannot create job from cronjob/$cj"; return 1; }
  local deadline st
  deadline=$(($(date +%s) + timeout))
  while :; do
    st=$(k get job -n "$ns" "$job" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}' 2>/dev/null)
    case "$st" in
      *Complete* | *SuccessCriteriaMet*)
        k logs -n "$ns" "job/$job" --all-containers --tail=5 2>/dev/null | tail -5
        echo "job $ns/$job complete"
        k delete job -n "$ns" "$job" --wait=false >/dev/null 2>&1
        return 0
        ;;
      *Failed*)
        k logs -n "$ns" "job/$job" --all-containers --tail=20 2>/dev/null
        echo "job $ns/$job failed"
        return 1
        ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "job $ns/$job not finished after ${timeout}s"
      return 1
    fi
    sleep 10
  done
}

# ---------------------------------------------------------------------------
# Floor checks (every stack)
# ---------------------------------------------------------------------------

# floor_rollout: every Deployment/StatefulSet/DaemonSet in VERIFY_NAMESPACES is
# converged within VERIFY_ROLLOUT_TIMEOUT (default 600 s), and no pod there is
# in CrashLoopBackOff or an image-pull error.
floor_rollout() {
  local timeout=${VERIFY_ROLLOUT_TIMEOUT:-600} deadline pending line ns obj out
  # shellcheck disable=SC2086
  set -- $VERIFY_NAMESPACES
  deadline=$(($(date +%s) + timeout))
  while :; do
    pending=()
    while read -r ns obj; do
      [ -n "$ns" ] || continue
      if [ -n "${VERIFY_ROLLOUT_SKIP:-}" ] && [[ "$ns/$obj" =~ $VERIFY_ROLLOUT_SKIP ]]; then continue; fi
      out=$(workload_ready "$ns" "$obj") || pending+=("$out")
    done < <(list_workloads "$@")
    if [ "${#pending[@]}" -eq 0 ] || [ "$(date +%s)" -ge "$deadline" ]; then break; fi
    sleep 10
  done
  local n
  n=$(list_workloads "$@" | wc -l | tr -d ' ')
  if [ "${#pending[@]}" -eq 0 ]; then
    pass "floor: $n workloads converged in $*"
  else
    for line in "${pending[@]}"; do fail "floor: rollout" "$line"; done
  fi
  local bad
  bad=$(bad_pods "$@")
  if [ -z "$bad" ]; then
    pass "floor: no crash-looping or image-pull-failing pods in $*"
  else
    fail "floor: unhealthy pods" "$(printf '%s' "$bad" | _oneline 600)"
  fi
}

# floor_ingress: every Ingress host in VERIFY_NAMESPACES answers through
# Traefik with a status below 500 (redirects to Authentik, 401 and 404 are
# fine; 000 and 5xx are not). VERIFY_INGRESS_SKIP is a regex over
# "<ns>/<ingress>" for routes known to be down independently of this stack.
floor_ingress() {
  local rows ns name host path code bad=0 n=0
  _TRAEFIK_IP=$(traefik_ip)
  # shellcheck disable=SC2086
  rows=$(for ns in $VERIFY_NAMESPACES; do
    k get ingress -n "$ns" -o json 2>/dev/null | jq -r --arg ns "$ns" '
      .items[] | select(.spec.rules[0].host != null) |
      "\($ns) \(.metadata.name) \(.spec.rules[0].host) \(.spec.rules[0].http.paths[0].path // "/")"'
  done)
  if [ -z "$rows" ]; then
    log "INFO  floor: no ingress in $VERIFY_NAMESPACES"
    return 0
  fi
  while read -r ns name host path; do
    if [ -n "${VERIFY_INGRESS_SKIP:-}" ] && [[ "$ns/$name" =~ $VERIFY_INGRESS_SKIP ]]; then
      log "SKIP  floor: ingress $ns/$name (VERIFY_INGRESS_SKIP)"
      continue
    fi
    n=$((n + 1))
    for _ in 1 2 3; do
      code=$(via_traefik "$host" "$path")
      [[ "$code" =~ ^[1-4][0-9][0-9]$ ]] && break
      sleep 5
    done
    if [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]; then
      log "ok    ingress $ns/$name https://$host$path -> $code"
    elif [ "$code" = 503 ] && backend_parked "$ns" "$name"; then
      log "ok    ingress $ns/$name https://$host$path -> 503, backend parked (no ready endpoints)"
    else
      bad=$((bad + 1))
      fail "floor: ingress $ns/$name" "https://$host$path -> $code"
    fi
  done <<<"$rows"
  [ "$bad" -eq 0 ] && pass "floor: $n ingress routes answer below 500"
  return 0
}

# new_alerts: firing alerts attributable to this stack that became active at or
# after VERIFY_SINCE. Attribution: the alert's namespace (or exported_namespace)
# is in VERIFY_NAMESPACES, its Traefik service label starts with one of those
# namespaces, or its alertname matches VERIFY_ALERTNAMES.
new_alerts() {
  local alt nsre svcre
  alt=$(echo "$VERIFY_NAMESPACES" | tr -s ' ' '|')
  nsre="^($alt)$"
  svcre="^($alt)-.*@kubernetes$"
  curl -sS --fail --max-time 30 "$PROM_URL/api/v1/alerts" | jq -r \
    --arg nsre "$nsre" --arg svcre "$svcre" --argjson since "${VERIFY_SINCE:-0}" \
    --arg names "${VERIFY_ALERTNAMES:-}" --arg ignore "${VERIFY_ALERT_IGNORE:-$VERIFY_ALERT_IGNORE_DEFAULT}" '
    .data.alerts[]
    | select(.state == "firing")
    | select((.activeAt | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $since)
    | select(.labels.alertname | test($ignore) | not)
    | select(
        ((.labels.namespace // "") | test($nsre))
        or ((.labels.exported_namespace // "") | test($nsre))
        or ((.labels.service // "") | test($svcre))
        or ($names != "" and (.labels.alertname | test($names))))
    | "\(.labels.alertname){namespace=\(.labels.namespace // "-")} active since \(.activeAt)"'
}

# floor_alerts: no new attributable alert fires during VERIFY_ALERT_WINDOW
# seconds (default 600) after the checks above.
floor_alerts() {
  local window=${VERIFY_ALERT_WINDOW:-600} deadline found left
  deadline=$(($(date +%s) + window))
  log "INFO  floor: watching alerts for ${window}s (new since $(date -u -d "@${VERIFY_SINCE:-0}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "${VERIFY_SINCE:-0}"))"
  while :; do
    if ! found=$(new_alerts); then
      fail "floor: alert query" "Prometheus $PROM_URL/api/v1/alerts did not answer"
      return 0
    fi
    if [ -n "$found" ]; then
      fail "floor: new firing alerts" "$(printf '%s' "$found" | _oneline 700)"
      return 0
    fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    left=$((deadline - $(date +%s)))
    sleep $((left < 30 ? (left > 0 ? left : 1) : 30))
  done
  pass "floor: no new firing alerts for ${window}s"
}

# ---------------------------------------------------------------------------
# Helpers shared by several component scripts
# ---------------------------------------------------------------------------

# expect_no_log_errors <ns> <selector> <regex> [since]
expect_no_log_errors() {
  local ns=$1 sel=$2 re=$3 since=${4:-15m} hits
  hits=$(k logs -n "$ns" -l "$sel" --all-containers --since="$since" --tail=2000 --prefix 2>/dev/null | grep -Ei -- "$re" | head -5)
  if [ -n "$hits" ]; then
    echo "$hits"
    return 1
  fi
  echo "no lines matching /$re/ in $ns $sel since $since"
}

# expect_alert_inactive <alertname-regex>
expect_alert_inactive() {
  local hits
  hits=$(curl -sS --fail --max-time 30 "$PROM_URL/api/v1/alerts" |
    jq -r --arg re "$1" '.data.alerts[] | select(.state=="firing") | select(.labels.alertname|test($re)) | .labels.alertname' | sort | uniq -c)
  if [ -n "$hits" ]; then
    echo "firing: $hits"
    return 1
  fi
  echo "not firing: $1"
}

# expect_dry_run_denied <manifest-json> <message-regex>
# Server-side dry run in the verify namespace that an admission webhook must
# refuse. Persists nothing.
expect_dry_run_denied() {
  local out
  if out=$(printf '%s' "$1" | k create --dry-run=server -f - 2>&1); then
    echo "admitted (expected a denial): $out"
    return 1
  fi
  if grep -Eq -- "$2" <<<"$out"; then
    echo "denied as expected: $(printf '%s' "$out" | head -c 300)"
  else
    echo "denied for another reason: $out"
    return 1
  fi
}

# apps_healthy <ns...>
# Dependent-app check for the database stacks: in every namespace that
# exists, each workload is converged, no pod is crash-looping, and each
# ingress answers below 500 through Traefik. Prints the unhealthy ones.
apps_healthy() {
  local ns obj out bad=() n=0 name host path code ip
  ip=$(traefik_ip)
  for ns in "$@"; do
    k get ns "$ns" >/dev/null 2>&1 || continue
    n=$((n + 1))
    while read -r _ obj; do
      [ -n "$obj" ] || continue
      out=$(workload_ready "$ns" "$obj") || bad+=("$ns/$obj")
    done < <(list_workloads "$ns")
    while read -r name host path; do
      [ -n "$host" ] || continue
      code=$(_TRAEFIK_IP=$ip via_traefik "$host" "$path")
      [[ "$code" =~ ^[1-4][0-9][0-9]$ ]] && continue
      [ "$code" = 503 ] && backend_parked "$ns" "$name" && continue
      bad+=("https://$host$path=$code")
    done < <(k get ingress -n "$ns" -o json 2>/dev/null | jq -r '.items[] | select(.spec.rules[0].host != null) | "\(.metadata.name) \(.spec.rules[0].host) \(.spec.rules[0].http.paths[0].path // "/")"')
  done
  out=$(bad_pods "$@")
  [ -z "$out" ] || bad+=("$out")
  echo "dependent namespaces checked=$n unhealthy=[${bad[*]}]"
  [ "${#bad[@]}" -eq 0 ]
}

# redis_session <host> <port> <command>...
# Sends inline commands on one connection and prints one reply per line.
# Bulk replies are printed on one line; an error reply fails the call.
redis_session() {
  local host=$1 port=$2 cmd reply len data rc=0
  shift 2
  exec 3<>"/dev/tcp/$host/$port" || return 1
  for cmd in "$@"; do printf '%s\r\n' "$cmd" >&3; done
  for cmd in "$@"; do
    IFS= read -r -t 10 reply <&3 || { echo "no reply to: $cmd"; rc=1; break; }
    reply=${reply%$'\r'}
    case "$reply" in
      '$-1') echo "$cmd => (nil)" ;;
      '$'*)
        len=${reply#\$}
        data=$(dd bs=1 count="$((len + 2))" <&3 2>/dev/null | tr -d '\r')
        echo "$cmd => $(printf '%s' "$data" | tr '\n' ' ')"
        ;;
      -*) echo "$cmd => $reply"; rc=1 ;;
      *) echo "$cmd => ${reply#?}" ;;
    esac
  done
  exec 3>&-
  return "$rc"
}

summary() {
  section "summary for ${VERIFY_STACK:-?}"
  log "passed=$PASS_COUNT failed=$FAIL_COUNT"
  local c
  for c in "${FAILED_CHECKS[@]}"; do log "failed: $c"; done
  if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "VERIFY RESULT: PASS ${VERIFY_STACK:-}"
    return 0
  fi
  echo "VERIFY RESULT: FAIL ${VERIFY_STACK:-}"
  return 1
}
