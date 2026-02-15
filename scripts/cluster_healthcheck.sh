#!/usr/bin/env bash

# Cluster health check script.
# Runs 13 diagnostic checks against the Kubernetes cluster and prints
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
    echo -e "${BOLD}[$num/13] $title${NC}"
}

section_always() {
    local num="$1" title="$2"
    [[ "$JSON" == true ]] && return 0
    echo ""
    echo -e "${BOLD}[$num/13] $title${NC}"
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

    not_running=$(echo "$cs_pods" | awk '$3 != "Running" {print $1 ": " $3}' || true)
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
