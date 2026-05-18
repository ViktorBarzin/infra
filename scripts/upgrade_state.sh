#!/usr/bin/env bash
#
# upgrade_state.sh — survey the three autonomous-upgrade pipelines.
#
# Companion to cluster_healthcheck.sh, surfaced via the /upgrade-state skill.
# Read-only by design — no --fix.
#
# The three pipelines:
#   1. Apps  — Keel polls registries hourly and rolls Deployments tagged
#              keel.sh/policy. Metrics on container :9300/metrics.
#   2. OS    — unattended-upgrades patches in-release per node; kured
#              reboots within a daily 02:00-06:00 London window.
#   3. K8s   — k8s-version-check CronJob (Sun 12:00 UTC) detects new
#              kubeadm patch/minor releases; Job-chain drains+upgrades
#              node-by-node. Pushgateway holds k8s_upgrade_* gauges.
#
# Exit codes: 0 healthy, 1 attention warranted, 2 something stalled.

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Globals ---
JSON=false
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/config}"
[[ -f "$KUBECONFIG_PATH" ]] || KUBECONFIG_PATH="/home/wizard/code/infra/config"
KUBECTL=""
NODES=(k8s-master:10.0.20.100 k8s-node1:10.0.20.101 k8s-node2:10.0.20.102 k8s-node3:10.0.20.103 k8s-node4:10.0.20.104)
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no)
NOW_EPOCH=$(date -u +%s)
HIGHEST_EXIT=0  # 0 healthy, 1 attention, 2 stalled

# Results — collectors fill these.
APPS_STATUS_ICON=""; APPS_STATUS_TEXT=""
APPS_LAST_CHECK=""; APPS_NEXT=""; APPS_NOTES=""
APPS_ENROLLED=0; APPS_PENDING=0; APPS_UPDATES_LINE=""; APPS_ERROR_LINE=""

OS_STATUS_ICON=""; OS_STATUS_TEXT=""
OS_LAST_CHECK=""; OS_NEXT=""; OS_NOTES=""
OS_DISTRO_SUMMARY=""; OS_KERNEL_SUMMARY=""
OS_PENDING_REBOOT_NODES=""; OS_HELD_DETAIL=""
OS_LAST_UU=""; OS_LAST_KURED=""

K8S_STATUS_ICON=""; K8S_STATUS_TEXT=""
K8S_LAST_CHECK=""; K8S_NEXT=""; K8S_NOTES=""
K8S_RUNNING=""; K8S_PATCH=""; K8S_MINOR=""
K8S_LAST_DETECT_LINE=""; K8S_IN_FLIGHT="no"; K8S_LAST_CHAIN=""

# --- Helpers ---
log() { [[ "$JSON" == true ]] && return 0; echo -e "$*"; }

raise_exit() {
    local n="$1"
    if [[ "$n" -gt "$HIGHEST_EXIT" ]]; then HIGHEST_EXIT="$n"; fi
    return 0
}

usage() {
    cat <<EOF
Usage: $0 [--json] [--kubeconfig <path>]

Read-only audit of the three autonomous-upgrade pipelines (apps, OS, k8s).

  --json              machine-readable JSON
  --kubeconfig PATH   override kubeconfig

Exit codes: 0 healthy, 1 attention warranted, 2 something stalled.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)       JSON=true; shift ;;
            --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
            -h|--help)    usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done
    KUBECTL="kubectl --kubeconfig $KUBECONFIG_PATH"
}

# Prometheus query — Prometheus + reload + backup share a network namespace,
# so reaching localhost:9090 works from any of the three sidecars.
prom_q() {
    local q="$1"
    $KUBECTL -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
        wget -qO- "http://localhost:9090/api/v1/query?query=${q}" 2>/dev/null || true
}

pg_metrics() {
    $KUBECTL -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
        wget -qO- "http://prometheus-prometheus-pushgateway:9091/metrics" 2>/dev/null || true
}

ssh_node() {
    local ip="$1"; shift
    ssh "${SSH_OPTS[@]}" "wizard@$ip" "$@" 2>/dev/null || true
}

human_age() {
    local secs="$1"
    if   [[ "$secs" -lt 60    ]]; then printf '%ds ago' "$secs"
    elif [[ "$secs" -lt 3600  ]]; then printf '%dm ago' $((secs/60))
    elif [[ "$secs" -lt 86400 ]]; then printf '%dh ago' $((secs/3600))
    else                               printf '%dd ago' $((secs/86400))
    fi
}

# Pushgateway emits floats and scientific notation — coerce to integer
# epoch seconds. Returns 0 if the input is empty / zero / unparseable.
to_epoch_int() {
    local v="${1:-}"
    if [[ -z "$v" || "$v" == "0" ]]; then echo 0; return; fi
    python3 -c "import sys; v=sys.argv[1]; print(int(float(v)))" "$v" 2>/dev/null || echo 0
}

# --- 1. Apps (Keel) ---
collect_apps() {
    local pending tracked enrolled updates_24h errors

    # Enrolled: count Deployments with keel.sh/policy != never (Keel itself
    # is policy=never). The Kyverno auto-injection labels namespaces
    # keel.sh/enrolled=true, but the annotation is what Keel watches.
    enrolled=$($KUBECTL get deploy -A -o json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
n = sum(1 for d in data["items"]
        if (d["metadata"].get("annotations") or {}).get("keel.sh/policy", "never") != "never")
print(n)
' 2>/dev/null || echo 0)
    APPS_ENROLLED="$enrolled"

    # Pending approvals (sum across Keel pods).
    pending=$(prom_q 'sum(pending_approvals)' | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)["data"]["result"]
    print(int(float(r[0]["value"][1])) if r else 0)
except Exception:
    print(0)
' 2>/dev/null || echo 0)
    APPS_PENDING="$pending"

    # Tracked images — proxy for "is the scrape live?".
    tracked=$(prom_q 'count(count by (image) (registries_scanned_total))' | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)["data"]["result"]
    print(int(float(r[0]["value"][1])) if r else 0)
except Exception:
    print(0)
' 2>/dev/null || echo 0)

    # Last scrape age — `up{job="kubernetes-pods", app="keel"}` is 1 if the
    # most recent scrape succeeded. We surface the wallclock age via a tiny
    # `time() - timestamp(up{...})` query.
    APPS_LAST_CHECK=$(prom_q 'time()-timestamp(up{job="kubernetes-pods",app="keel"})' | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)["data"]["result"]
    if not r: print("scrape not live")
    else:
        secs = int(float(r[0]["value"][1]))
        if secs < 60:  print(f"{secs}s ago")
        elif secs < 3600: print(f"{secs//60}m ago")
        else: print(f"{secs//3600}h ago")
except Exception:
    print("?")
' 2>/dev/null || echo "?")

    # Recent updates: count lines in Keel logs that report a successful
    # rollout. Keel logs an "update completed" message per rollout.
    local log_24h
    log_24h=$($KUBECTL -n keel logs deploy/keel --since=24h --tail=2000 2>/dev/null || true)
    updates_24h=$(echo "$log_24h" | grep -cE 'update completed|successfully updated|deployment updated' 2>/dev/null || true)
    [[ -z "$updates_24h" ]] && updates_24h=0
    APPS_UPDATES_LINE="$updates_24h in last 24h (tracked images: $tracked)"

    errors=$(echo "$log_24h" | grep -iE '"level":"(error|fatal)"|level=error' | tail -3 || true)
    if [[ -z "$errors" ]]; then
        APPS_ERROR_LINE="(none in last 24h)"
    else
        APPS_ERROR_LINE="$(echo "$errors" | wc -l | tr -d ' ') error(s); newest: $(echo "$errors" | tail -1 | cut -c1-120)"
    fi

    # Keel pod state.
    local pod_status
    pod_status=$($KUBECTL -n keel get pods -l app=keel -o jsonpath='{.items[*].status.phase}' 2>/dev/null || true)

    if [[ "$pod_status" != *"Running"* ]]; then
        APPS_STATUS_ICON="✗"; APPS_STATUS_TEXT="down"
        APPS_NOTES="Keel pod not Running ($pod_status)"
        raise_exit 2
    elif [[ "$pending" -gt 0 || -n "$errors" ]]; then
        APPS_STATUS_ICON="⚠"; APPS_STATUS_TEXT="attn"
        APPS_NOTES="$enrolled enrolled; $pending pending; $(echo "$errors" | wc -l | tr -d ' ') recent error(s)"
        raise_exit 1
    else
        APPS_STATUS_ICON="✓"; APPS_STATUS_TEXT="healthy"
        APPS_NOTES="$enrolled enrolled, 0 pending, 0 errors"
    fi

    APPS_NEXT="rolling, hourly poll"
}

# --- 2. OS (apt + kured) ---
collect_os() {
    local distros kernels distro_uniq kernel_uniq
    distros=$($KUBECTL get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.osImage}{"\n"}{end}' 2>/dev/null)
    kernels=$($KUBECTL get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kernelVersion}{"\n"}{end}' 2>/dev/null)
    distro_uniq=$(echo "$distros" | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    kernel_uniq=$(echo "$kernels" | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    OS_DISTRO_SUMMARY="$distro_uniq"
    OS_KERNEL_SUMMARY="$kernel_uniq"

    # SSH fan-out — parallel background subshells, write per-node results to tmp files.
    local tmpdir; tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    local entry name ip
    for entry in "${NODES[@]}"; do
        name="${entry%%:*}"; ip="${entry##*:}"
        (
            local out reboot held upgradable uu_log
            reboot=$(ssh_node "$ip" 'test -f /var/run/reboot-required && echo yes || echo no')
            held=$(ssh_node "$ip" 'apt-mark showhold 2>/dev/null')
            upgradable=$(ssh_node "$ip" 'apt list --upgradable 2>/dev/null | tail -n +2')
            uu_log=$(ssh_node "$ip" 'tail -1 /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null')
            printf 'reboot=%s\n' "$reboot"      >  "$tmpdir/$name"
            printf 'held<<<EOF\n%s\nEOF\n' "$held"         >> "$tmpdir/$name"
            printf 'upgradable<<<EOF\n%s\nEOF\n' "$upgradable" >> "$tmpdir/$name"
            printf 'uu_log=%s\n' "$uu_log"     >> "$tmpdir/$name"
        ) &
    done
    wait

    # Aggregate.
    local pending_reboots=() held_with_bumps_lines=() newest_uu_ts=0 newest_uu_iso=""
    for entry in "${NODES[@]}"; do
        name="${entry%%:*}"
        [[ -f "$tmpdir/$name" ]] || continue
        local reboot held upgradable uu_log uu_ts
        reboot=$(awk -F= '/^reboot=/{print $2}' "$tmpdir/$name")
        held=$(awk '/^held<<<EOF$/,/^EOF$/' "$tmpdir/$name" | sed '1d;$d')
        upgradable=$(awk '/^upgradable<<<EOF$/,/^EOF$/' "$tmpdir/$name" | sed '1d;$d')
        uu_log=$(awk -F= '/^uu_log=/{sub(/^uu_log=/,""); print}' "$tmpdir/$name")

        [[ "$reboot" == "yes" ]] && pending_reboots+=("$name")

        # Held + upgradable, excluding k8s components (managed by k8s pipeline).
        local pkg from to bump
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            pkg=$(echo "$line" | awk -F/ '{print $1}')
            # Skip k8s and kernel/linux-image — the chain handles those.
            case "$pkg" in
                kubeadm|kubectl|kubelet) continue ;;
                linux-image-*|linux-headers-*|linux-modules-*|linux-generic|linux-headers-generic|linux-image-generic) continue ;;
            esac
            # Only flag if the package is held.
            if echo "$held" | grep -qx "$pkg"; then
                to=$(echo "$line" | awk '{print $2}')
                from=$(echo "$line" | sed -n 's/.*from: \([^ ]*\).*/\1/p')
                bump="$pkg ${from%-*}→${to%-*}"
                held_with_bumps_lines+=("$name: $bump")
            fi
        done <<<"$upgradable"

        # Newest uu timestamp (ISO at start of log line).
        uu_ts=$(echo "$uu_log" | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}).*/\1/')
        if [[ -n "$uu_ts" ]]; then
            local epoch; epoch=$(date -u -d "$uu_ts" +%s 2>/dev/null || echo 0)
            if [[ "$epoch" -gt "$newest_uu_ts" ]]; then
                newest_uu_ts="$epoch"; newest_uu_iso="$uu_ts"
            fi
        fi
    done

    OS_PENDING_REBOOT_NODES="${pending_reboots[*]:-}"
    if [[ ${#held_with_bumps_lines[@]} -gt 0 ]]; then
        OS_HELD_DETAIL=$(printf '%s\n' "${held_with_bumps_lines[@]}" | sort -u | paste -sd '; ' -)
    fi

    if [[ "$newest_uu_ts" -gt 0 ]]; then
        local age=$((NOW_EPOCH - newest_uu_ts))
        OS_LAST_UU="$newest_uu_iso UTC ($(human_age "$age"))"
        OS_LAST_CHECK="$(human_age "$age") (uu daily)"
    else
        OS_LAST_UU="(no uu log accessible)"
        OS_LAST_CHECK="?"
    fi

    # Last kured reboot — newest Ready transition across worker nodes.
    # `Ready -> True` is what kured causes when the node returns; we surface
    # the most recent timestamp and the node it belongs to.
    local kured_raw kured_iso kured_node kured_ep kured_age
    kured_raw=$($KUBECTL get nodes -o json 2>/dev/null | python3 -c '
import json, sys
from datetime import datetime
data = json.load(sys.stdin)
best = (0, "", "")
for n in data["items"]:
    name = n["metadata"]["name"]
    for c in n["status"].get("conditions", []):
        if c["type"] == "Ready":
            dt = datetime.strptime(c["lastTransitionTime"], "%Y-%m-%dT%H:%M:%SZ")
            ep = int(dt.timestamp())
            if ep > best[0]:
                best = (ep, name, c["lastTransitionTime"])
print(f"{best[0]}|{best[1]}|{best[2]}")
' 2>/dev/null || echo "0||")
    kured_ep="${kured_raw%%|*}"
    kured_node=$(echo "$kured_raw" | cut -d'|' -f2)
    kured_iso=$(echo "$kured_raw" | cut -d'|' -f3)
    if [[ "$kured_ep" -gt 0 ]]; then
        kured_age=$((NOW_EPOCH - kured_ep))
        OS_LAST_KURED="$kured_iso ($kured_node, $(human_age "$kured_age"))"
    else
        OS_LAST_KURED="?"
    fi

    OS_NEXT="daily 02:00-06:00 London"

    # Kured pod health.
    local kured_pods kured_unhealthy
    kured_pods=$($KUBECTL -n kured get pods -l app.kubernetes.io/name=kured -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null)
    kured_unhealthy=$(echo "$kured_pods" | grep -cv '^Running$' 2>/dev/null || true)

    local notes=()
    [[ -n "$OS_HELD_DETAIL" ]]            && notes+=("held with bumps: $OS_HELD_DETAIL")
    [[ -n "$OS_PENDING_REBOOT_NODES" ]]   && notes+=("pending reboot: $OS_PENDING_REBOOT_NODES")

    if [[ "$kured_unhealthy" -gt 0 ]]; then
        OS_STATUS_ICON="✗"; OS_STATUS_TEXT="kured down"
        OS_NOTES="kured pods not all Running"
        raise_exit 2
    elif [[ ${#notes[@]} -gt 0 ]]; then
        OS_STATUS_ICON="⚠"; OS_STATUS_TEXT="attn"
        OS_NOTES="${notes[*]}"
        raise_exit 1
    else
        OS_STATUS_ICON="✓"; OS_STATUS_TEXT="healthy"
        OS_NOTES="distros uniform; no held bumps; no pending reboots"
    fi
}

# --- 3. K8s (kubeadm/kubelet/kubectl) ---
collect_k8s() {
    local kver_list kver_uniq metrics target_patch target_minor last_run in_flight started

    kver_list=$($KUBECTL get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' 2>/dev/null)
    kver_uniq=$(echo "$kver_list" | sort -u)
    local n_uniq; n_uniq=$(echo "$kver_uniq" | wc -l | tr -d ' ')
    if [[ "$n_uniq" -eq 1 ]]; then
        K8S_RUNNING="$kver_uniq across $(echo "$kver_list" | wc -l | tr -d ' ')/$(echo "$kver_list" | wc -l | tr -d ' ') nodes"
    else
        K8S_RUNNING="mixed: $(echo "$kver_uniq" | paste -sd', ' -)"
    fi
    local running_ver; running_ver=$(echo "$kver_uniq" | head -1)

    metrics=$(pg_metrics)
    # All five may legitimately be absent (cluster never ran the upgrade
    # chain, kind="minor" not detected, etc.) — `|| true` keeps pipefail
    # from killing the script on no-match.
    target_patch=$(echo "$metrics" | { grep -E '^k8s_upgrade_available\{[^}]*kind="patch"' || true; } | sed -n 's/.*target="\([^"]*\)".*/\1/p' | head -1)
    target_minor=$(echo "$metrics" | { grep -E '^k8s_upgrade_available\{[^}]*kind="minor"' || true; } | sed -n 's/.*target="\([^"]*\)".*/\1/p' | head -1)
    # Pushgateway emits these with `{instance="",job="..."}` labels — the
    # `awk '$1 ~ /^name(\{|$)/'` form matches both bare and labelled metrics.
    last_run=$(echo "$metrics"  | awk '$1 ~ /^k8s_version_check_last_run_timestamp(\{|$)/{print $2}' | head -1 || true)
    in_flight=$(echo "$metrics" | awk '$1 ~ /^k8s_upgrade_in_flight(\{|$)/{print $2}' | head -1 || true)
    started=$(echo "$metrics"   | awk '$1 ~ /^k8s_upgrade_started_timestamp(\{|$)/{print $2}' | head -1 || true)

    # Pushgateway timestamps come back in scientific notation
    # (e.g. 1.779052159e+09) — convert to plain integer seconds.
    local last_run_int started_int
    last_run_int=$(to_epoch_int "$last_run")
    started_int=$(to_epoch_int "$started")

    if [[ "$last_run_int" -gt 0 ]]; then
        local age=$((NOW_EPOCH - last_run_int))
        K8S_LAST_CHECK="$(human_age "$age") (Sun cron)"
        if [[ -n "$target_patch" ]]; then
            K8S_LAST_DETECT_LINE="last run $(human_age "$age"): available v$target_patch (patch)"
        elif [[ -n "$target_minor" ]]; then
            K8S_LAST_DETECT_LINE="last run $(human_age "$age"): available v$target_minor (minor)"
        else
            K8S_LAST_DETECT_LINE="last run $(human_age "$age"): no upgrade available"
        fi
    else
        K8S_LAST_CHECK="(metric missing)"
        K8S_LAST_DETECT_LINE="(no k8s_version_check_last_run_timestamp in Pushgateway)"
    fi
    K8S_PATCH="${target_patch:-none}"
    K8S_MINOR="${target_minor:-none}"

    # In-flight / last chain.
    if [[ "${in_flight:-0}" == "1" ]]; then
        K8S_IN_FLIGHT="yes"
        local since=0
        [[ "$started_int" -gt 0 ]] && since=$((NOW_EPOCH - started_int))
        K8S_LAST_CHAIN="in-flight (started $(human_age "$since"))"
    else
        K8S_IN_FLIGHT="no"
        if [[ "$started_int" -gt 0 ]]; then
            local age=$((NOW_EPOCH - started_int))
            K8S_LAST_CHAIN="$(human_age "$age")"
        else
            K8S_LAST_CHAIN="never (or zeroed)"
        fi
    fi

    K8S_NEXT="$(next_sunday_noon_utc)"

    # Status logic.
    local stalled=0
    if [[ "${in_flight:-0}" == "1" && "$started_int" -gt 0 ]]; then
        # K8sUpgradeStalled fires after 5400s (90m) per monitoring stack.
        local since=$((NOW_EPOCH - started_int))
        [[ "$since" -gt 5400 ]] && stalled=1
    fi
    local last_run_age=999999999
    [[ "$last_run_int" -gt 0 ]] && last_run_age=$((NOW_EPOCH - last_run_int))

    if [[ "$stalled" == "1" ]]; then
        K8S_STATUS_ICON="✗"; K8S_STATUS_TEXT="stalled"
        K8S_NOTES="K8sUpgradeStalled would fire — chain in-flight >90m"
        raise_exit 2
    elif [[ "$last_run_age" -gt $((9*86400)) ]]; then
        K8S_STATUS_ICON="✗"; K8S_STATUS_TEXT="detection stale"
        K8S_NOTES="last detection >9d ago"
        raise_exit 2
    elif [[ "${in_flight:-0}" == "1" ]]; then
        K8S_STATUS_ICON="…"; K8S_STATUS_TEXT="in-flight"
        K8S_NOTES="upgrade chain running"
        raise_exit 1
    elif [[ -n "$target_patch" ]]; then
        K8S_STATUS_ICON="→"; K8S_STATUS_TEXT="$target_patch"
        K8S_NOTES="running $running_ver → v$target_patch (patch) available"
        raise_exit 1
    elif [[ -n "$target_minor" ]]; then
        K8S_STATUS_ICON="→"; K8S_STATUS_TEXT="$target_minor"
        K8S_NOTES="running $running_ver → v$target_minor (minor) available"
        raise_exit 1
    else
        K8S_STATUS_ICON="✓"; K8S_STATUS_TEXT="current"
        K8S_NOTES="running $running_ver, nothing newer"
    fi
}

# Next Sun 12:00 UTC — pure bash date math, no croniter.
next_sunday_noon_utc() {
    local now_iso target_iso
    now_iso=$(date -u +%FT%TZ)
    # date %u: Mon=1..Sun=7. Sun=7.
    local dow; dow=$(date -u +%u)
    local days_until=$(( (7 - dow) % 7 ))
    # If today is Sunday and it's before 12:00 UTC, "next" is today.
    if [[ "$dow" == "7" ]]; then
        local hr; hr=$(date -u +%H)
        [[ "$hr" -lt 12 ]] && days_until=0 || days_until=7
    fi
    target_iso=$(date -u -d "+$days_until days" +"%Y-%m-%d 12:00 UTC")
    echo "Sun $target_iso"
}

# --- Renderers ---
# The table uses `column -t` so we don't have to compute visual widths
# manually (the status icons are multi-byte UTF-8 and ANSI escapes don't
# play nice with `printf %-Xs`). Trade-off: no in-cell colour, but the
# icon character already carries the signal.
render_table() {
    echo
    printf "${BOLD}Upgrade state — %s${NC}\n" "$(date -u +'%Y-%m-%d %H:%M UTC')"
    echo
    {
        echo "Layer|Status|Last check|Next upgrade|Notes"
        echo "-----|------|----------|------------|-----"
        printf 'Apps|%s %s|%s|%s|%s\n' "$APPS_STATUS_ICON" "$APPS_STATUS_TEXT" "$APPS_LAST_CHECK" "$APPS_NEXT" "$APPS_NOTES"
        printf 'OS  |%s %s|%s|%s|%s\n' "$OS_STATUS_ICON"   "$OS_STATUS_TEXT"   "$OS_LAST_CHECK"   "$OS_NEXT"   "$OS_NOTES"
        printf 'K8s |%s %s|%s|%s|%s\n' "$K8S_STATUS_ICON"  "$K8S_STATUS_TEXT"  "$K8S_LAST_CHECK"  "$K8S_NEXT"  "$K8S_NOTES"
    } | column -t -s '|' -o ' | '

    echo
    printf "${BOLD}--- Apps (Keel) ---${NC}\n"
    echo "Enrolled deployments: $APPS_ENROLLED"
    echo "Recent rollouts: $APPS_UPDATES_LINE"
    echo "Pending approvals: $APPS_PENDING"
    echo "Last Keel error: $APPS_ERROR_LINE"

    echo
    printf "${BOLD}--- OS (apt + kured) ---${NC}\n"
    echo "Ubuntu per node: $OS_DISTRO_SUMMARY"
    echo "Kernel per node: $OS_KERNEL_SUMMARY"
    echo "Pending reboot: ${OS_PENDING_REBOOT_NODES:-none}"
    echo "Held packages with upstream bumps: ${OS_HELD_DETAIL:-none (excluding k8s components)}"
    echo "Last uu run (newest across nodes): $OS_LAST_UU"
    echo "Last kured reboot (newest Ready transition): $OS_LAST_KURED"
    echo "Next kured window: $OS_NEXT"

    echo
    printf "${BOLD}--- K8s (kubeadm/kubelet/kubectl) ---${NC}\n"
    echo "Running: $K8S_RUNNING"
    echo "Latest patch (apt): ${K8S_PATCH}"
    echo "Next minor available: ${K8S_MINOR}"
    echo "Detection: $K8S_LAST_DETECT_LINE"
    echo "In-flight: $K8S_IN_FLIGHT  |  Last chain start: $K8S_LAST_CHAIN"
    echo "Next detection: $K8S_NEXT"
    echo
}

render_json() {
    # Pipe values into Python via env vars so we don't need to worry about
    # embedded quotes/backslashes in error lines.
    APPS_STATUS_ICON="$APPS_STATUS_ICON" APPS_STATUS_TEXT="$APPS_STATUS_TEXT" \
    APPS_LAST_CHECK="$APPS_LAST_CHECK" APPS_NEXT="$APPS_NEXT" APPS_NOTES="$APPS_NOTES" \
    APPS_ENROLLED="$APPS_ENROLLED" APPS_PENDING="$APPS_PENDING" \
    APPS_UPDATES_LINE="$APPS_UPDATES_LINE" APPS_ERROR_LINE="$APPS_ERROR_LINE" \
    OS_STATUS_ICON="$OS_STATUS_ICON" OS_STATUS_TEXT="$OS_STATUS_TEXT" \
    OS_LAST_CHECK="$OS_LAST_CHECK" OS_NEXT="$OS_NEXT" OS_NOTES="$OS_NOTES" \
    OS_DISTRO_SUMMARY="$OS_DISTRO_SUMMARY" OS_KERNEL_SUMMARY="$OS_KERNEL_SUMMARY" \
    OS_PENDING_REBOOT_NODES="$OS_PENDING_REBOOT_NODES" OS_HELD_DETAIL="$OS_HELD_DETAIL" \
    OS_LAST_UU="$OS_LAST_UU" OS_LAST_KURED="$OS_LAST_KURED" \
    K8S_STATUS_ICON="$K8S_STATUS_ICON" K8S_STATUS_TEXT="$K8S_STATUS_TEXT" \
    K8S_LAST_CHECK="$K8S_LAST_CHECK" K8S_NEXT="$K8S_NEXT" K8S_NOTES="$K8S_NOTES" \
    K8S_RUNNING="$K8S_RUNNING" K8S_PATCH="$K8S_PATCH" K8S_MINOR="$K8S_MINOR" \
    K8S_LAST_DETECT_LINE="$K8S_LAST_DETECT_LINE" K8S_IN_FLIGHT="$K8S_IN_FLIGHT" K8S_LAST_CHAIN="$K8S_LAST_CHAIN" \
    HIGHEST_EXIT="$HIGHEST_EXIT" \
    python3 -c '
import json, os
from datetime import datetime, timezone
def env(k): return os.environ.get(k, "")
out = {
    "as_of_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "highest_exit": int(env("HIGHEST_EXIT")),
    "apps": {
        "status": env("APPS_STATUS_ICON"),
        "status_text": env("APPS_STATUS_TEXT"),
        "last_check": env("APPS_LAST_CHECK"),
        "next_upgrade": env("APPS_NEXT"),
        "notes": env("APPS_NOTES"),
        "enrolled": int(env("APPS_ENROLLED") or 0),
        "pending_approvals": int(env("APPS_PENDING") or 0),
        "updates_line": env("APPS_UPDATES_LINE"),
        "errors_line": env("APPS_ERROR_LINE"),
    },
    "os": {
        "status": env("OS_STATUS_ICON"),
        "status_text": env("OS_STATUS_TEXT"),
        "last_check": env("OS_LAST_CHECK"),
        "next_upgrade": env("OS_NEXT"),
        "notes": env("OS_NOTES"),
        "distros": env("OS_DISTRO_SUMMARY"),
        "kernels": env("OS_KERNEL_SUMMARY"),
        "pending_reboot_nodes": env("OS_PENDING_REBOOT_NODES"),
        "held_with_bumps": env("OS_HELD_DETAIL"),
        "last_uu_run": env("OS_LAST_UU"),
        "last_kured_reboot": env("OS_LAST_KURED"),
    },
    "k8s": {
        "status": env("K8S_STATUS_ICON"),
        "status_text": env("K8S_STATUS_TEXT"),
        "last_check": env("K8S_LAST_CHECK"),
        "next_upgrade": env("K8S_NEXT"),
        "notes": env("K8S_NOTES"),
        "running": env("K8S_RUNNING"),
        "patch_target": env("K8S_PATCH"),
        "minor_target": env("K8S_MINOR"),
        "last_detection_line": env("K8S_LAST_DETECT_LINE"),
        "in_flight": env("K8S_IN_FLIGHT"),
        "last_chain": env("K8S_LAST_CHAIN"),
    },
}
print(json.dumps(out, indent=2))
'
}

main() {
    parse_args "$@"
    collect_apps
    collect_os
    collect_k8s
    if [[ "$JSON" == true ]]; then
        render_json
    else
        render_table
    fi
    exit "$HIGHEST_EXIT"
}

main "$@"
