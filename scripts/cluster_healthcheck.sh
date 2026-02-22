#!/usr/bin/env bash

# Cluster health check script.
# Runs 24 diagnostic checks against the Kubernetes cluster and prints
# a colour-coded report with PASS / WARN / FAIL for each section.
#
# Usage: ./scripts/cluster_healthcheck.sh [--fix] [--quiet|-q] [--json] [--kubeconfig <path>]

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Globals ---
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
FIX=false
QUIET=false
JSON=false
KUBECONFIG_PATH="$(pwd)/config"
KUBECTL=""
JSON_RESULTS=()
TOTAL_CHECKS=24

# --- Helpers ---
info()  { [[ "$JSON" == true ]] && return 0; echo -e "${BLUE}[INFO]${NC} $*"; }
pass()  { PASS_COUNT=$((PASS_COUNT + 1)); [[ "$JSON" == true ]] && return 0; [[ "$QUIET" == true ]] && return 0; echo -e "  ${GREEN}[PASS]${NC} $*"; }
warn()  { WARN_COUNT=$((WARN_COUNT + 1)); [[ "$JSON" == true ]] && return 0; echo -e "  ${YELLOW}[WARN]${NC} $*"; }
fail()  { FAIL_COUNT=$((FAIL_COUNT + 1)); [[ "$JSON" == true ]] && return 0; echo -e "  ${RED}[FAIL]${NC} $*"; }

section() {
    local num="$1" title="$2"
    [[ "$JSON" == true ]] && return 0
    [[ "$QUIET" == true ]] && return 0
    echo ""
    echo -e "${BOLD}[$num/$TOTAL_CHECKS] $title${NC}"
}

section_always() {
    local num="$1" title="$2"
    [[ "$JSON" == true ]] && return 0
    echo ""
    echo -e "${BOLD}[$num/$TOTAL_CHECKS] $title${NC}"
}

json_add() {
    local name="$1" status="$2" detail="$3"
    local escaped
    escaped=$(echo "$detail" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')
    JSON_RESULTS+=("{\"check\":\"$name\",\"status\":\"$status\",\"detail\":$escaped}")
}

# count lines in a variable, returning 0 for empty strings
count_lines() {
    local input="$1"
    if [[ -z "$input" ]]; then
        echo 0
    else
        echo "$input" | wc -l | tr -d ' '
    fi
}

# --- Argument parsing ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix)        FIX=true; shift ;;
            --quiet|-q)   QUIET=true; shift ;;
            --json)       JSON=true; shift ;;
            --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: $0 [--fix] [--quiet|-q] [--json] [--kubeconfig <path>]"
                echo ""
                echo "Flags:"
                echo "  --fix              Auto-remediate safe issues (delete evicted pods)"
                echo "  --quiet, -q        Only show WARN and FAIL sections"
                echo "  --json             Machine-readable JSON output"
                echo "  --kubeconfig PATH  Override kubeconfig (default: \$(pwd)/config)"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done
    KUBECTL="kubectl --kubeconfig $KUBECONFIG_PATH"
}

# --- 1. Node Status ---
check_nodes() {
    section 1 "Node Status"
    local nodes not_ready versions unique_versions detail=""

    nodes=$($KUBECTL get nodes --no-headers 2>&1) || { fail "Cannot reach cluster"; json_add "node_status" "FAIL" "Cannot reach cluster"; return 0; }
    not_ready=$(echo "$nodes" | awk '$2 != "Ready" {print $1}' || true)
    versions=$(echo "$nodes" | awk '{print $5}' | sort -u)
    unique_versions=$(echo "$versions" | wc -l | tr -d ' ')

    if [[ -n "$not_ready" ]]; then
        [[ "$QUIET" == true ]] && section_always 1 "Node Status"
        fail "NotReady nodes: $not_ready"
        detail="NotReady: $not_ready"
        json_add "node_status" "FAIL" "$detail"
    elif [[ "$unique_versions" -gt 1 ]]; then
        [[ "$QUIET" == true ]] && section_always 1 "Node Status"
        warn "Version mismatch across nodes: $(echo "$versions" | tr '\n' ' ')"
        detail="Version mismatch: $(echo "$versions" | tr '\n' ' ')"
        json_add "node_status" "WARN" "$detail"
    else
        pass "All nodes Ready, version $(echo "$versions" | head -1)"
        detail="All nodes Ready"
        json_add "node_status" "PASS" "$detail"
    fi
}

# --- 2. Node Resources ---
check_resources() {
    section 2 "Node Resources"
    local top detail="" had_issue=false status="PASS"

    top=$($KUBECTL top nodes --no-headers 2>&1) || { fail "metrics-server unavailable"; json_add "node_resources" "FAIL" "metrics-server unavailable"; return 0; }

    while IFS= read -r line; do
        local node cpu_pct mem_pct
        node=$(echo "$line" | awk '{print $1}')
        cpu_pct=$(echo "$line" | awk '{print $3}' | tr -d '%')
        mem_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')

        # Skip nodes where metrics are not yet available
        if [[ "$cpu_pct" == *"unknown"* ]] || [[ "$mem_pct" == *"unknown"* ]]; then
            detail+="$node metrics unavailable; "
            continue
        fi

        if [[ "$cpu_pct" -gt 90 ]] || [[ "$mem_pct" -gt 90 ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 2 "Node Resources"
            fail "$node: CPU ${cpu_pct}%, Mem ${mem_pct}%"
            detail+="$node CPU=${cpu_pct}% Mem=${mem_pct}% [FAIL]; "
            had_issue=true
            status="FAIL"
        elif [[ "$cpu_pct" -gt 80 ]] || [[ "$mem_pct" -gt 80 ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 2 "Node Resources"
            warn "$node: CPU ${cpu_pct}%, Mem ${mem_pct}%"
            detail+="$node CPU=${cpu_pct}% Mem=${mem_pct}% [WARN]; "
            had_issue=true
            [[ "$status" != "FAIL" ]] && status="WARN"
        else
            detail+="$node CPU=${cpu_pct}% Mem=${mem_pct}% [OK]; "
        fi
    done <<< "$top"

    [[ "$had_issue" == false ]] && pass "All nodes below 80% CPU and memory"
    json_add "node_resources" "$status" "$detail"
}

# --- 3. Node Conditions ---
check_conditions() {
    section 3 "Node Conditions"
    local conditions detail=""

    conditions=$($KUBECTL get nodes -o json | python3 -c '
import json, sys
data = json.load(sys.stdin)
for node in data["items"]:
    name = node["metadata"]["name"]
    for c in node["status"]["conditions"]:
        if c["type"] in ("MemoryPressure","DiskPressure","PIDPressure") and c["status"] == "True":
            print(name + ": " + c["type"])
' 2>&1) || true

    if [[ -n "$conditions" ]]; then
        [[ "$QUIET" == true ]] && section_always 3 "Node Conditions"
        while IFS= read -r line; do
            fail "$line"
        done <<< "$conditions"
        detail="$conditions"
        json_add "node_conditions" "FAIL" "$detail"
    else
        pass "No pressure conditions on any node"
        json_add "node_conditions" "PASS" "No pressure conditions"
    fi
}

# --- 4. Problematic Pods ---
check_pods() {
    section 4 "Problematic Pods"
    local bad count detail="" status="PASS"

    bad=$( {
        $KUBECTL get pods -A --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null \
            | grep -E 'CrashLoopBackOff|Error|Pending|Init:|ImagePullBackOff|ErrImagePull' || true
        $KUBECTL get pods -A --no-headers 2>/dev/null \
            | grep -E 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull' || true
    } | awk '!seen[$1,$2]++' | sed '/^$/d') || true

    count=$(count_lines "$bad")

    if [[ "$count" -eq 0 ]]; then
        pass "No problematic pods"
        detail="None"
    elif [[ "$count" -le 10 ]]; then
        [[ "$QUIET" == true ]] && section_always 4 "Problematic Pods"
        warn "$count problematic pod(s):"
        [[ "$JSON" != true ]] && echo "$bad" | while IFS= read -r line; do echo "    $line"; done
        detail="$count pods"
        status="WARN"
    else
        [[ "$QUIET" == true ]] && section_always 4 "Problematic Pods"
        fail "$count problematic pods (showing first 10):"
        [[ "$JSON" != true ]] && echo "$bad" | head -10 | while IFS= read -r line; do echo "    $line"; done
        detail="$count pods"
        status="FAIL"
    fi
    json_add "problematic_pods" "$status" "$detail"
}

# --- 5. Evicted/Failed Pods ---
check_evicted() {
    section 5 "Evicted/Failed Pods"
    local evicted count detail="" status="PASS"

    evicted=$($KUBECTL get pods -A --no-headers --field-selector=status.phase=Failed 2>/dev/null || true)
    count=$(count_lines "$evicted")

    if [[ "$count" -eq 0 ]]; then
        pass "No evicted or failed pods"
        detail="0"
    elif [[ "$count" -le 50 ]]; then
        [[ "$QUIET" == true ]] && section_always 5 "Evicted/Failed Pods"
        warn "$count evicted/failed pod(s)"
        detail="$count pods"
        status="WARN"
    else
        [[ "$QUIET" == true ]] && section_always 5 "Evicted/Failed Pods"
        fail "$count evicted/failed pods"
        detail="$count pods"
        status="FAIL"
    fi

    if [[ "$FIX" == true && "$count" -gt 0 ]]; then
        info "Deleting $count evicted/failed pods..."
        $KUBECTL delete pods -A --field-selector=status.phase=Failed 2>/dev/null || true
        info "Deleted evicted/failed pods"
    fi
    json_add "evicted_pods" "$status" "$detail"
}

# --- 6. DaemonSets ---
check_daemonsets() {
    section 6 "DaemonSets"
    local ds detail="" had_issue=false

    ds=$($KUBECTL get daemonsets -A --no-headers 2>&1) || { fail "Cannot list DaemonSets"; json_add "daemonsets" "FAIL" "Cannot list"; return 0; }

    while IFS= read -r line; do
        local ns name desired ready
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        desired=$(echo "$line" | awk '{print $3}')
        ready=$(echo "$line" | awk '{print $5}')

        if [[ "$desired" != "$ready" ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 6 "DaemonSets"
            fail "$ns/$name: desired=$desired ready=$ready"
            detail+="$ns/$name desired=$desired ready=$ready; "
            had_issue=true
        fi
    done <<< "$ds"

    if [[ "$had_issue" == false ]]; then
        pass "All DaemonSets healthy (desired == ready)"
        json_add "daemonsets" "PASS" "All healthy"
    else
        json_add "daemonsets" "FAIL" "$detail"
    fi
}

# --- 7. Deployments ---
check_deployments() {
    section 7 "Deployments"
    local deps detail="" had_issue=false

    deps=$($KUBECTL get deployments -A --no-headers 2>&1) || { fail "Cannot list Deployments"; json_add "deployments" "FAIL" "Cannot list"; return 0; }

    while IFS= read -r line; do
        local ns name ready current desired
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        ready=$(echo "$line" | awk '{print $3}')
        current=$(echo "$ready" | cut -d/ -f1)
        desired=$(echo "$ready" | cut -d/ -f2)

        if [[ "$current" != "$desired" ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 7 "Deployments"
            fail "$ns/$name: $current/$desired ready"
            detail+="$ns/$name $current/$desired; "
            had_issue=true
        fi
    done <<< "$deps"

    if [[ "$had_issue" == false ]]; then
        pass "All deployments fully available"
        json_add "deployments" "PASS" "All available"
    else
        json_add "deployments" "FAIL" "$detail"
    fi
}

# --- 8. PVC Status ---
check_pvcs() {
    section 8 "PVC Status"
    local pvcs detail="" had_issue=false

    pvcs=$($KUBECTL get pvc -A --no-headers 2>&1) || true
    if [[ -z "$pvcs" || "$pvcs" == *"No resources found"* ]]; then
        pass "No PVCs in cluster"
        json_add "pvcs" "PASS" "No PVCs"
        return 0
    fi

    while IFS= read -r line; do
        local ns name status
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3}')

        if [[ "$status" != "Bound" ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 8 "PVC Status"
            fail "$ns/$name: $status"
            detail+="$ns/$name=$status; "
            had_issue=true
        fi
    done <<< "$pvcs"

    if [[ "$had_issue" == false ]]; then
        pass "All PVCs Bound"
        json_add "pvcs" "PASS" "All Bound"
    else
        json_add "pvcs" "FAIL" "$detail"
    fi
}

# --- 9. HPA Health ---
check_hpa() {
    section 9 "HPA Health"
    local hpas detail="" had_issue=false status="PASS"

    hpas=$($KUBECTL get hpa -A --no-headers 2>&1) || true
    if [[ -z "$hpas" || "$hpas" == *"No resources found"* ]]; then
        pass "No HPAs configured"
        json_add "hpa" "PASS" "No HPAs"
        return 0
    fi

    while IFS= read -r line; do
        local ns name targets
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        targets=$(echo "$line" | awk '{print $3}')

        if echo "$targets" | grep -q '<unknown>'; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 9 "HPA Health"
            fail "$ns/$name: targets=$targets (unknown metrics)"
            detail+="$ns/$name=unknown; "
            had_issue=true
            status="FAIL"
        else
            # Parse percentage values from targets like "45%/80%, 30%/50%"
            local pcts
            pcts=$(echo "$targets" | grep -oE '[0-9]+%/' | tr -d '%/' || true)
            if [[ -n "$pcts" ]]; then
                while IFS= read -r pct; do
                    [[ -z "$pct" ]] && continue
                    if [[ "$pct" -gt 150 ]]; then
                        [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 9 "HPA Health"
                        fail "$ns/$name: utilization at ${pct}%"
                        detail+="$ns/$name=${pct}%; "
                        had_issue=true
                        status="FAIL"
                        break
                    elif [[ "$pct" -gt 100 ]]; then
                        [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 9 "HPA Health"
                        warn "$ns/$name: utilization at ${pct}%"
                        detail+="$ns/$name=${pct}%; "
                        had_issue=true
                        [[ "$status" != "FAIL" ]] && status="WARN"
                        break
                    fi
                done <<< "$pcts"
            fi
        fi
    done <<< "$hpas"

    [[ "$had_issue" == false ]] && pass "All HPAs healthy"
    json_add "hpa" "$status" "${detail:-All healthy}"
}

# --- 10. CronJob Failures ---
check_cronjobs() {
    section 10 "CronJob Failures"
    local failures detail=""

    failures=$($KUBECTL get jobs -A -o json 2>/dev/null | python3 -c '
import json, sys
from datetime import datetime, timezone, timedelta

data = json.load(sys.stdin)
cutoff = datetime.now(timezone.utc) - timedelta(hours=24)

for job in data.get("items", []):
    meta = job.get("metadata", {})
    ns = meta.get("namespace", "")
    name = meta.get("name", "")

    owners = meta.get("ownerReferences", [])
    is_cronjob = any(o.get("kind") == "CronJob" for o in owners)
    if not is_cronjob:
        continue

    conditions = job.get("status", {}).get("conditions", [])
    for c in conditions:
        if c.get("type") == "Failed" and c.get("status") == "True":
            ts = c.get("lastTransitionTime", "")
            if ts:
                try:
                    t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    if t > cutoff:
                        print(f"{ns}/{name}: {c.get(\"reason\", \"Unknown\")}")
                except:
                    print(f"{ns}/{name}: {c.get(\"reason\", \"Unknown\")}")
' 2>/dev/null) || true

    if [[ -z "$failures" ]]; then
        pass "No CronJob failures in last 24h"
        json_add "cronjob_failures" "PASS" "None"
    else
        [[ "$QUIET" == true ]] && section_always 10 "CronJob Failures"
        local count
        count=$(count_lines "$failures")
        fail "$count CronJob failure(s) in last 24h:"
        [[ "$JSON" != true ]] && echo "$failures" | while IFS= read -r line; do echo "    $line"; done
        json_add "cronjob_failures" "FAIL" "$count failures"
    fi
}

# --- 11. CrowdSec ---
check_crowdsec() {
    section 11 "CrowdSec Agents"
    local cs_pods not_running

    cs_pods=$($KUBECTL get pods -n crowdsec --no-headers 2>/dev/null || true)
    if [[ -z "$cs_pods" ]]; then
        [[ "$QUIET" == true ]] && section_always 11 "CrowdSec Agents"
        warn "CrowdSec namespace not found or empty"
        json_add "crowdsec" "WARN" "No CrowdSec pods found"
        return 0
    fi

    not_running=$(echo "$cs_pods" | awk '$3 != "Running" && $3 != "Completed" {print $1 ": " $3}' || true)
    if [[ -n "$not_running" ]]; then
        [[ "$QUIET" == true ]] && section_always 11 "CrowdSec Agents"
        while IFS= read -r line; do
            fail "CrowdSec pod not running: $line"
        done <<< "$not_running"
        json_add "crowdsec" "FAIL" "$not_running"
    else
        local total
        total=$(count_lines "$cs_pods")
        pass "All $total CrowdSec pods running"
        json_add "crowdsec" "PASS" "$total pods running"
    fi
}

# --- 12. Ingress ---
check_ingresses() {
    section 12 "Ingress Routes"
    local ingresses no_lb detail="" had_issue=false

    ingresses=$($KUBECTL get ingress -A --no-headers 2>/dev/null || true)
    if [[ -n "$ingresses" ]]; then
        no_lb=$(echo "$ingresses" | awk '{if ($5 == "" || $5 == "<none>") print $1"/"$2}' || true)
        if [[ -n "$no_lb" ]]; then
            [[ "$QUIET" == true ]] && section_always 12 "Ingress Routes"
            while IFS= read -r line; do
                fail "Ingress missing LB IP: $line"
            done <<< "$no_lb"
            detail="Missing LB: $no_lb"
            had_issue=true
        fi
    fi

    # Check Traefik LB service
    local traefik_svc_ip
    traefik_svc_ip=$($KUBECTL get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -z "$traefik_svc_ip" ]]; then
        [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 12 "Ingress Routes"
        fail "Traefik LoadBalancer has no external IP"
        detail+="Traefik LB missing IP; "
        had_issue=true
    else
        detail+="Traefik LB=$traefik_svc_ip; "
    fi

    if [[ "$had_issue" == false ]]; then
        pass "All ingresses have LB assignment (Traefik LB=$traefik_svc_ip)"
        json_add "ingresses" "PASS" "$detail"
    else
        json_add "ingresses" "FAIL" "$detail"
    fi
}

# --- 13. Prometheus Alerts ---
check_alerts() {
    section 13 "Prometheus Alerts"
    local alerts firing_count

    # Try alertmanager first, then prometheus server
    alerts=$($KUBECTL exec -n monitoring deploy/prometheus-alertmanager -- \
        wget -q -O- http://localhost:9093/api/v2/alerts 2>/dev/null || true)

    if [[ -z "$alerts" ]]; then
        alerts=$($KUBECTL exec -n monitoring deploy/prometheus-server -- \
            wget -q -O- http://localhost:9090/api/v1/alerts 2>/dev/null || true)
    fi

    if [[ -z "$alerts" ]]; then
        [[ "$QUIET" == true ]] && section_always 13 "Prometheus Alerts"
        warn "Could not query Prometheus/Alertmanager"
        json_add "prometheus_alerts" "WARN" "Cannot query"
        return 0
    fi

    firing_count=$(echo "$alerts" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        active = [a for a in data if a.get("status", {}).get("state") == "active"]
        count = len(active)
        names = [a.get("labels", {}).get("alertname", "?") for a in active]
        print(f"{count}:" + ",".join(names) if count > 0 else "0:")
    elif isinstance(data, dict) and "data" in data:
        alerts_list = data["data"].get("alerts", [])
        firing = [a for a in alerts_list if a.get("state") == "firing"]
        count = len(firing)
        names = [a.get("labels", {}).get("alertname", "?") for a in firing]
        print(f"{count}:" + ",".join(names) if count > 0 else "0:")
    else:
        print("0:")
except:
    print("-1:")
' 2>/dev/null || echo "-1:")

    local count names
    count=$(echo "$firing_count" | cut -d: -f1)
    names=$(echo "$firing_count" | cut -d: -f2-)

    if [[ "$count" == "-1" ]]; then
        [[ "$QUIET" == true ]] && section_always 13 "Prometheus Alerts"
        warn "Failed to parse alert data"
        json_add "prometheus_alerts" "WARN" "Parse error"
    elif [[ "$count" -eq 0 ]]; then
        pass "No firing alerts"
        json_add "prometheus_alerts" "PASS" "0 firing"
    elif [[ "$count" -le 3 ]]; then
        [[ "$QUIET" == true ]] && section_always 13 "Prometheus Alerts"
        warn "$count firing alert(s): $names"
        json_add "prometheus_alerts" "WARN" "$count firing: $names"
    else
        [[ "$QUIET" == true ]] && section_always 13 "Prometheus Alerts"
        fail "$count firing alerts: $names"
        json_add "prometheus_alerts" "FAIL" "$count firing: $names"
    fi
}

# --- 14. Uptime Kuma ---
check_uptime_kuma() {
    section 14 "Uptime Kuma Monitors"
    local result

    result=$(~/.venvs/claude/bin/python3 -c '
import sys
try:
    from uptime_kuma_api import UptimeKumaApi
except ImportError:
    print("ERROR:uptime-kuma-api not installed")
    sys.exit(0)

try:
    api = UptimeKumaApi("https://uptime.viktorbarzin.me", timeout=30)
    api.login("admin", "EUxhLr4w4NFsGehy")

    monitors = api.get_monitors()
    # Build id->name map and track active/paused
    id_to_name = {}
    paused_count = 0
    for m in monitors:
        mid = m.get("id")
        name = m.get("name", "unknown")
        active = m.get("active", True)
        if not active:
            paused_count += 1
        else:
            id_to_name[mid] = name

    # Use bulk heartbeat fetch (single API call) instead of per-monitor calls
    heartbeats = api.get_heartbeats()

    down = []
    up_count = 0
    for mid, name in id_to_name.items():
        beats = heartbeats.get(mid, [])
        if beats:
            status = beats[-1].get("status", 0)
            if status == 1:
                up_count += 1
            elif status == 3:
                paused_count += 1
            else:
                down.append(name)
        else:
            down.append(name)

    api.disconnect()

    down_count = len(down)
    total_active = up_count + down_count
    down_names = ", ".join(down) if down else ""
    print(f"{down_count}:{up_count}:{paused_count}:{total_active}:{down_names}")
except Exception as e:
    print(f"CONN_ERROR:{e}")
' 2>/dev/null) || result="CONN_ERROR:python execution failed"

    if [[ "$result" == "ERROR:"* ]]; then
        [[ "$QUIET" == true ]] && section_always 14 "Uptime Kuma Monitors"
        warn "Uptime Kuma: ${result#ERROR:}"
        json_add "uptime_kuma" "WARN" "${result#ERROR:}"
    elif [[ "$result" == "CONN_ERROR:"* ]]; then
        [[ "$QUIET" == true ]] && section_always 14 "Uptime Kuma Monitors"
        warn "Cannot connect to Uptime Kuma: ${result#CONN_ERROR:}"
        json_add "uptime_kuma" "WARN" "Connection failed"
    else
        local down_count up_count paused_count total_active down_names
        down_count=$(echo "$result" | cut -d: -f1)
        up_count=$(echo "$result" | cut -d: -f2)
        paused_count=$(echo "$result" | cut -d: -f3)
        total_active=$(echo "$result" | cut -d: -f4)
        down_names=$(echo "$result" | cut -d: -f5-)

        if [[ "$down_count" -eq 0 ]]; then
            pass "All $total_active active monitors up ($paused_count paused)"
            json_add "uptime_kuma" "PASS" "$total_active up, $paused_count paused"
        elif [[ "$down_count" -le 3 ]]; then
            [[ "$QUIET" == true ]] && section_always 14 "Uptime Kuma Monitors"
            warn "$down_count/$total_active monitor(s) down: $down_names"
            json_add "uptime_kuma" "WARN" "$down_count down: $down_names"
        else
            [[ "$QUIET" == true ]] && section_always 14 "Uptime Kuma Monitors"
            fail "$down_count/$total_active monitors down: $down_names"
            json_add "uptime_kuma" "FAIL" "$down_count down: $down_names"
        fi
    fi
}

# --- 15. ResourceQuota Pressure ---
check_resourcequota() {
    section 15 "ResourceQuota Pressure"
    local quotas detail="" had_issue=false status="PASS"

    quotas=$($KUBECTL get resourcequota -A -o json 2>/dev/null) || { pass "No ResourceQuotas configured"; json_add "resourcequota" "PASS" "No quotas"; return 0; }

    local pressure
    pressure=$(echo "$quotas" | python3 -c '
import json, sys, re

def parse_cpu(val):
    """Convert CPU value to millicores."""
    val = str(val)
    if val.endswith("m"):
        return float(val[:-1])
    return float(val) * 1000

def parse_mem(val):
    """Convert memory value to bytes."""
    val = str(val)
    units = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4}
    for suffix, mult in units.items():
        if val.endswith(suffix):
            return float(val[:-len(suffix)]) * mult
    # Plain bytes or numeric
    return float(val)

data = json.load(sys.stdin)
for item in data.get("items", []):
    ns = item["metadata"]["namespace"]
    name = item["metadata"]["name"]
    status = item.get("status", {})
    hard = status.get("hard", {})
    used = status.get("used", {})

    for resource, hard_val in hard.items():
        used_val = used.get(resource, "0")
        try:
            if "cpu" in resource:
                h = parse_cpu(hard_val)
                u = parse_cpu(used_val)
            elif "memory" in resource or "storage" in resource:
                h = parse_mem(hard_val)
                u = parse_mem(used_val)
            elif resource == "pods":
                h = float(hard_val)
                u = float(used_val)
            else:
                continue
            if h <= 0:
                continue
            pct = (u / h) * 100
            if pct > 80:
                level = "FAIL" if pct > 95 else "WARN"
                print(f"{level}:{ns}/{name}:{resource}:{pct:.0f}%")
        except (ValueError, ZeroDivisionError):
            pass
' 2>/dev/null) || true

    if [[ -z "$pressure" ]]; then
        pass "All ResourceQuotas below 80% usage"
        json_add "resourcequota" "PASS" "All below 80%"
    else
        [[ "$QUIET" == true ]] && section_always 15 "ResourceQuota Pressure"
        while IFS= read -r line; do
            local level ns_res resource pct
            level=$(echo "$line" | cut -d: -f1)
            ns_res=$(echo "$line" | cut -d: -f2)
            resource=$(echo "$line" | cut -d: -f3)
            pct=$(echo "$line" | cut -d: -f4)
            if [[ "$level" == "FAIL" ]]; then
                fail "$ns_res: $resource at $pct"
                status="FAIL"
            else
                warn "$ns_res: $resource at $pct"
                [[ "$status" != "FAIL" ]] && status="WARN"
            fi
            detail+="$ns_res $resource=$pct; "
            had_issue=true
        done <<< "$pressure"
        json_add "resourcequota" "$status" "$detail"
    fi
}

# --- 16. StatefulSets ---
check_statefulsets() {
    section 16 "StatefulSets"
    local sts detail="" had_issue=false

    sts=$($KUBECTL get statefulsets -A --no-headers 2>&1) || true
    if [[ -z "$sts" || "$sts" == *"No resources found"* ]]; then
        pass "No StatefulSets in cluster"
        json_add "statefulsets" "PASS" "No StatefulSets"
        return 0
    fi

    while IFS= read -r line; do
        local ns name ready current desired
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        ready=$(echo "$line" | awk '{print $3}')
        current=$(echo "$ready" | cut -d/ -f1)
        desired=$(echo "$ready" | cut -d/ -f2)

        if [[ "$current" != "$desired" ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 16 "StatefulSets"
            fail "$ns/$name: $current/$desired ready"
            detail+="$ns/$name $current/$desired; "
            had_issue=true
        fi
    done <<< "$sts"

    if [[ "$had_issue" == false ]]; then
        pass "All StatefulSets fully available"
        json_add "statefulsets" "PASS" "All available"
    else
        json_add "statefulsets" "FAIL" "$detail"
    fi
}

# --- 17. Node Disk Usage ---
check_node_disk() {
    section 17 "Node Disk Usage"
    local node_json detail="" had_issue=false status="PASS"

    node_json=$($KUBECTL get nodes -o json 2>/dev/null) || { fail "Cannot get node info"; json_add "node_disk" "FAIL" "Cannot get nodes"; return 0; }

    local disk_info
    disk_info=$(echo "$node_json" | python3 -c '
import json, sys

def parse_storage(val):
    """Convert storage value to bytes."""
    val = str(val)
    units = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4}
    for suffix, mult in units.items():
        if val.endswith(suffix):
            return float(val[:-len(suffix)]) * mult
    return float(val)

data = json.load(sys.stdin)
for node in data["items"]:
    name = node["metadata"]["name"]
    cap = node["status"].get("capacity", {})
    alloc = node["status"].get("allocatable", {})
    es_cap = cap.get("ephemeral-storage", "0")
    es_alloc = alloc.get("ephemeral-storage", "0")
    try:
        c = parse_storage(es_cap)
        a = parse_storage(es_alloc)
        if c > 0:
            used_pct = ((c - a) / c) * 100
            if used_pct > 80:
                level = "FAIL" if used_pct > 90 else "WARN"
                print(f"{level}:{name}:{used_pct:.0f}")
    except (ValueError, ZeroDivisionError):
        pass
' 2>/dev/null) || true

    if [[ -z "$disk_info" ]]; then
        pass "All nodes below 80% ephemeral-storage usage"
        json_add "node_disk" "PASS" "All below 80%"
    else
        [[ "$QUIET" == true ]] && section_always 17 "Node Disk Usage"
        while IFS= read -r line; do
            local level node pct
            level=$(echo "$line" | cut -d: -f1)
            node=$(echo "$line" | cut -d: -f2)
            pct=$(echo "$line" | cut -d: -f3)
            if [[ "$level" == "FAIL" ]]; then
                fail "$node: ephemeral-storage at ${pct}%"
                status="FAIL"
            else
                warn "$node: ephemeral-storage at ${pct}%"
                [[ "$status" != "FAIL" ]] && status="WARN"
            fi
            detail+="$node=${pct}%; "
            had_issue=true
        done <<< "$disk_info"
        json_add "node_disk" "$status" "$detail"
    fi
}

# --- 18. Helm Release Health ---
check_helm_releases() {
    section 18 "Helm Release Health"
    local releases detail="" had_issue=false status="PASS"

    releases=$(helm list -A --kubeconfig "$KUBECONFIG_PATH" --all -o json 2>/dev/null) || {
        [[ "$QUIET" == true ]] && section_always 18 "Helm Release Health"
        warn "Cannot list Helm releases"
        json_add "helm_releases" "WARN" "Cannot list"
        return 0
    }

    local bad_releases
    bad_releases=$(echo "$releases" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data:
    name = r.get("name", "?")
    ns = r.get("namespace", "?")
    st = r.get("status", "unknown")
    if st != "deployed":
        level = "FAIL" if st.startswith("pending") else "WARN"
        print(f"{level}:{ns}/{name}:{st}")
' 2>/dev/null) || true

    if [[ -z "$bad_releases" ]]; then
        pass "All Helm releases in deployed state"
        json_add "helm_releases" "PASS" "All deployed"
    else
        [[ "$QUIET" == true ]] && section_always 18 "Helm Release Health"
        while IFS= read -r line; do
            local level release_name release_status
            level=$(echo "$line" | cut -d: -f1)
            release_name=$(echo "$line" | cut -d: -f2)
            release_status=$(echo "$line" | cut -d: -f3)
            if [[ "$level" == "FAIL" ]]; then
                fail "Helm release $release_name: $release_status (blocks terraform)"
                status="FAIL"
            else
                warn "Helm release $release_name: $release_status"
                [[ "$status" != "FAIL" ]] && status="WARN"
            fi
            detail+="$release_name=$release_status; "
            had_issue=true
        done <<< "$bad_releases"
        json_add "helm_releases" "$status" "$detail"
    fi
}

# --- 19. Kyverno Policy Engine ---
check_kyverno() {
    section 19 "Kyverno Policy Engine"
    local kv_pods not_running

    kv_pods=$($KUBECTL get pods -n kyverno --no-headers 2>/dev/null || true)
    if [[ -z "$kv_pods" ]]; then
        [[ "$QUIET" == true ]] && section_always 19 "Kyverno Policy Engine"
        fail "Kyverno namespace not found or empty — policy engine down, cascading cluster impact"
        json_add "kyverno" "FAIL" "No Kyverno pods found"
        return 0
    fi

    not_running=$(echo "$kv_pods" | awk '$3 != "Running" && $3 != "Completed" {print $1 ": " $3}' || true)
    if [[ -n "$not_running" ]]; then
        [[ "$QUIET" == true ]] && section_always 19 "Kyverno Policy Engine"
        while IFS= read -r line; do
            fail "Kyverno pod not running: $line"
        done <<< "$not_running"
        json_add "kyverno" "FAIL" "$not_running"
    else
        local total
        total=$(count_lines "$kv_pods")
        pass "All $total Kyverno pods running"
        json_add "kyverno" "PASS" "$total pods running"
    fi
}

# --- 20. NFS Connectivity ---
check_nfs() {
    section 20 "NFS Connectivity"

    if showmount -e 10.0.10.15 &>/dev/null; then
        pass "NFS server 10.0.10.15 reachable (exports listed)"
        json_add "nfs" "PASS" "NFS reachable"
    elif nc -z -G 3 10.0.10.15 2049 &>/dev/null; then
        pass "NFS server 10.0.10.15 port 2049 open"
        json_add "nfs" "PASS" "NFS port open"
    else
        [[ "$QUIET" == true ]] && section_always 20 "NFS Connectivity"
        fail "NFS server 10.0.10.15 unreachable — 30+ services depend on NFS"
        json_add "nfs" "FAIL" "NFS unreachable"
    fi
}

# --- 21. DNS Resolution ---
check_dns() {
    section 21 "DNS Resolution"
    local internal_ok=false external_ok=false detail=""

    if dig @10.0.20.101 viktorbarzin.me +short +time=3 +tries=1 &>/dev/null; then
        internal_ok=true
    fi
    if dig @10.0.20.101 google.com +short +time=3 +tries=1 &>/dev/null; then
        external_ok=true
    fi

    if [[ "$internal_ok" == true && "$external_ok" == true ]]; then
        pass "DNS resolves both internal (viktorbarzin.me) and external (google.com)"
        json_add "dns" "PASS" "Both resolve"
    elif [[ "$internal_ok" == true || "$external_ok" == true ]]; then
        [[ "$QUIET" == true ]] && section_always 21 "DNS Resolution"
        if [[ "$internal_ok" == false ]]; then
            warn "DNS: internal (viktorbarzin.me) failed, external (google.com) OK"
            detail="Internal failed"
        else
            warn "DNS: internal (viktorbarzin.me) OK, external (google.com) failed"
            detail="External failed"
        fi
        json_add "dns" "WARN" "$detail"
    else
        [[ "$QUIET" == true ]] && section_always 21 "DNS Resolution"
        fail "DNS server 10.0.20.101 not resolving — both internal and external failed"
        json_add "dns" "FAIL" "Both failed"
    fi
}

# --- 22. TLS Certificate Expiry ---
check_tls_certs() {
    section 22 "TLS Certificate Expiry"
    local secrets detail="" had_issue=false status="PASS"

    secrets=$($KUBECTL get secrets -A -o json 2>/dev/null) || {
        [[ "$QUIET" == true ]] && section_always 22 "TLS Certificate Expiry"
        warn "Cannot list secrets"
        json_add "tls_certs" "WARN" "Cannot list secrets"
        return 0
    }

    local cert_issues
    cert_issues=$(echo "$secrets" | python3 -c '
import json, sys, base64, subprocess, hashlib
from datetime import datetime, timezone

data = json.load(sys.stdin)
seen_fingerprints = set()
results = []

for item in data.get("items", []):
    if item.get("type") != "kubernetes.io/tls":
        continue
    ns = item["metadata"]["namespace"]
    name = item["metadata"]["name"]
    cert_data = item.get("data", {}).get("tls.crt", "")
    if not cert_data:
        continue

    # Deduplicate by cert fingerprint
    raw = base64.b64decode(cert_data)
    fp = hashlib.sha256(raw).hexdigest()[:16]
    if fp in seen_fingerprints:
        continue
    seen_fingerprints.add(fp)

    # Parse certificate expiry with openssl
    try:
        result = subprocess.run(
            ["openssl", "x509", "-noout", "-enddate", "-subject"],
            input=raw, capture_output=True, timeout=5
        )
        output = result.stdout.decode()
        for line in output.splitlines():
            if line.startswith("notAfter="):
                date_str = line.split("=", 1)[1]
                # Parse openssl date format: "Mon DD HH:MM:SS YYYY GMT"
                try:
                    expiry = datetime.strptime(date_str.strip(), "%b %d %H:%M:%S %Y %Z")
                    expiry = expiry.replace(tzinfo=timezone.utc)
                    days_left = (expiry - datetime.now(timezone.utc)).days
                    if days_left <= 7:
                        print(f"FAIL:{ns}/{name}:{days_left}d")
                    elif days_left <= 30:
                        print(f"WARN:{ns}/{name}:{days_left}d")
                except ValueError:
                    pass
    except (subprocess.TimeoutExpired, Exception):
        pass
' 2>/dev/null) || true

    if [[ -z "$cert_issues" ]]; then
        pass "All TLS certificates valid for >30 days"
        json_add "tls_certs" "PASS" "All valid >30d"
    else
        [[ "$QUIET" == true ]] && section_always 22 "TLS Certificate Expiry"
        while IFS= read -r line; do
            local level cert_name days
            level=$(echo "$line" | cut -d: -f1)
            cert_name=$(echo "$line" | cut -d: -f2)
            days=$(echo "$line" | cut -d: -f3)
            if [[ "$level" == "FAIL" ]]; then
                fail "TLS cert $cert_name expires in $days"
                status="FAIL"
            else
                warn "TLS cert $cert_name expires in $days"
                [[ "$status" != "FAIL" ]] && status="WARN"
            fi
            detail+="$cert_name=$days; "
            had_issue=true
        done <<< "$cert_issues"
        json_add "tls_certs" "$status" "$detail"
    fi
}

# --- 23. GPU Health ---
check_gpu() {
    section 23 "GPU Health"
    local gpu_pods not_running

    gpu_pods=$($KUBECTL get pods -n nvidia --no-headers 2>/dev/null || true)
    if [[ -z "$gpu_pods" ]]; then
        [[ "$QUIET" == true ]] && section_always 23 "GPU Health"
        warn "NVIDIA namespace not found or empty"
        json_add "gpu" "WARN" "No GPU pods found"
        return 0
    fi

    # Check specifically for device-plugin (critical for GPU scheduling)
    local device_plugin_down=false
    local other_down=false
    local detail=""

    while IFS= read -r line; do
        local pod_name pod_status
        pod_name=$(echo "$line" | awk '{print $1}')
        pod_status=$(echo "$line" | awk '{print $3}')
        if [[ "$pod_status" != "Running" && "$pod_status" != "Completed" ]]; then
            if echo "$pod_name" | grep -q "device-plugin"; then
                device_plugin_down=true
                detail+="device-plugin $pod_name: $pod_status; "
            else
                other_down=true
                detail+="$pod_name: $pod_status; "
            fi
        fi
    done <<< "$gpu_pods"

    if [[ "$device_plugin_down" == true ]]; then
        [[ "$QUIET" == true ]] && section_always 23 "GPU Health"
        fail "GPU device-plugin is down — GPU workloads cannot schedule"
        json_add "gpu" "FAIL" "$detail"
    elif [[ "$other_down" == true ]]; then
        [[ "$QUIET" == true ]] && section_always 23 "GPU Health"
        warn "Some GPU pods not running: $detail"
        json_add "gpu" "WARN" "$detail"
    else
        local total
        total=$(count_lines "$gpu_pods")
        pass "All $total GPU pods running"
        json_add "gpu" "PASS" "$total pods running"
    fi
}

# --- 24. Cloudflare Tunnel ---
check_cloudflare_tunnel() {
    section 24 "Cloudflare Tunnel"
    local cf_pods running_count total_count

    cf_pods=$($KUBECTL get pods -n cloudflared --no-headers 2>/dev/null || true)
    if [[ -z "$cf_pods" ]]; then
        [[ "$QUIET" == true ]] && section_always 24 "Cloudflare Tunnel"
        fail "Cloudflare tunnel namespace not found or empty — external access broken"
        json_add "cloudflare_tunnel" "FAIL" "No pods found"
        return 0
    fi

    total_count=$(count_lines "$cf_pods")
    running_count=$(echo "$cf_pods" | awk '$3 == "Running"' | wc -l | tr -d ' ')

    if [[ "$running_count" -eq 0 ]]; then
        [[ "$QUIET" == true ]] && section_always 24 "Cloudflare Tunnel"
        fail "Cloudflare tunnel: 0/$total_count pods running — external access broken"
        json_add "cloudflare_tunnel" "FAIL" "0/$total_count running"
    elif [[ "$running_count" -lt "$total_count" ]]; then
        [[ "$QUIET" == true ]] && section_always 24 "Cloudflare Tunnel"
        warn "Cloudflare tunnel: $running_count/$total_count pods running (degraded)"
        json_add "cloudflare_tunnel" "WARN" "$running_count/$total_count running"
    else
        pass "Cloudflare tunnel: all $total_count pods running"
        json_add "cloudflare_tunnel" "PASS" "$total_count pods running"
    fi
}

# --- Summary ---
print_summary() {
    if [[ "$JSON" == true ]]; then
        echo "{"
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"pass\": $PASS_COUNT,"
        echo "  \"warn\": $WARN_COUNT,"
        echo "  \"fail\": $FAIL_COUNT,"
        echo "  \"checks\": ["
        local first=true
        for r in "${JSON_RESULTS[@]}"; do
            if [[ "$first" == true ]]; then
                echo "    $r"
                first=false
            else
                echo "    ,$r"
            fi
        done
        echo "  ]"
        echo "}"
        return 0
    fi

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}  Cluster Health Summary${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "  ${GREEN}PASS${NC}: $PASS_COUNT    ${YELLOW}WARN${NC}: $WARN_COUNT    ${RED}FAIL${NC}: $FAIL_COUNT"
    echo ""

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        echo -e "  Overall: ${RED}UNHEALTHY${NC}"
    elif [[ "$WARN_COUNT" -gt 0 ]]; then
        echo -e "  Overall: ${YELLOW}DEGRADED${NC}"
    else
        echo -e "  Overall: ${GREEN}HEALTHY${NC}"
    fi
    echo ""
}

# --- Main ---
main() {
    parse_args "$@"

    if [[ "$JSON" != true ]]; then
        echo -e "${BOLD}Cluster Health Check${NC} — $(date '+%Y-%m-%d %H:%M:%S')"
        echo -e "Kubeconfig: $KUBECONFIG_PATH"
        if [[ "$FIX" == true ]]; then
            echo -e "${YELLOW}Auto-fix mode enabled${NC}"
        fi
    fi

    check_nodes
    check_resources
    check_conditions
    check_pods
    check_evicted
    check_daemonsets
    check_deployments
    check_pvcs
    check_hpa
    check_cronjobs
    check_crowdsec
    check_ingresses
    check_alerts
    check_uptime_kuma
    check_resourcequota
    check_statefulsets
    check_node_disk
    check_helm_releases
    check_kyverno
    check_nfs
    check_dns
    check_tls_certs
    check_gpu
    check_cloudflare_tunnel
    print_summary

    # Exit code: 2 for failures, 1 for warnings, 0 for clean
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 2
    elif [[ "$WARN_COUNT" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
