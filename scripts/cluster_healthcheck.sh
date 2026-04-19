#!/usr/bin/env bash

# Cluster health check script.
# Runs 42 diagnostic checks against the Kubernetes cluster and prints
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
TOTAL_CHECKS=42

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
            --no-fix)     FIX=false; shift ;;
            --quiet|-q)   QUIET=true; shift ;;
            --json)       JSON=true; shift ;;
            --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: $0 [--fix|--no-fix] [--quiet|-q] [--json] [--kubeconfig <path>]"
                echo ""
                echo "Flags:"
                echo "  --fix              Auto-remediate safe issues (delete evicted pods)"
                echo "  --no-fix           Disable auto-remediation (default)"
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

    # Get password from Vault (or env var fallback)
    local uk_pass="${UPTIME_KUMA_PASSWORD:-}"
    if [[ -z "$uk_pass" ]]; then
        uk_pass=$(vault kv get -field=uptime_kuma_admin_password secret/viktor 2>/dev/null) || true
    fi
    if [[ -z "$uk_pass" ]]; then
        warn "Uptime Kuma: password not available (set UPTIME_KUMA_PASSWORD or vault login)"
        json_add "uptime_kuma" "WARN" "password not available"
        return 0
    fi

    result=$(UPTIME_KUMA_PASSWORD="$uk_pass" ~/.venvs/claude/bin/python3 -c '
import sys, os
try:
    from uptime_kuma_api import UptimeKumaApi
except ImportError:
    print("ERROR:uptime-kuma-api not installed")
    sys.exit(0)

try:
    api = UptimeKumaApi("https://uptime.viktorbarzin.me", timeout=120, wait_events=0.2)
    api.login("admin", os.environ["UPTIME_KUMA_PASSWORD"])

    monitors = api.get_monitors()
    heartbeats = api.get_heartbeats()

    # Separate internal and external monitors
    internal_up = 0
    internal_down = []
    external_up = 0
    external_down = []
    paused_count = 0

    for m in monitors:
        mid = m.get("id")
        name = m.get("name", "unknown")
        active = m.get("active", True)
        is_external = name.startswith("[External] ")

        if not active:
            paused_count += 1
            continue

        beats = heartbeats.get(mid, [])
        if beats:
            last_beat = beats[-1]
            if isinstance(last_beat, list):
                last_beat = last_beat[-1] if last_beat else {}
            status = last_beat.get("status", 0) if isinstance(last_beat, dict) else 0
            if hasattr(status, "value"):
                status = status.value
            is_up = (status == 1)
        else:
            is_up = False

        if is_external:
            if is_up:
                external_up += 1
            else:
                external_down.append(name.replace("[External] ", ""))
        else:
            if is_up:
                internal_up += 1
            else:
                internal_down.append(name)

    api.disconnect()

    int_down_names = ", ".join(internal_down) if internal_down else ""
    ext_down_names = ", ".join(external_down) if external_down else ""
    # Format: int_down:int_up:ext_down:ext_up:paused:int_down_names|ext_down_names
    print(f"{len(internal_down)}:{internal_up}:{len(external_down)}:{external_up}:{paused_count}:{int_down_names}|{ext_down_names}")
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
        local int_down int_up ext_down ext_up paused_count down_details
        int_down=$(echo "$result" | cut -d: -f1)
        int_up=$(echo "$result" | cut -d: -f2)
        ext_down=$(echo "$result" | cut -d: -f3)
        ext_up=$(echo "$result" | cut -d: -f4)
        paused_count=$(echo "$result" | cut -d: -f5)
        down_details=$(echo "$result" | cut -d: -f6-)
        local int_down_names="${down_details%%|*}"
        local ext_down_names="${down_details#*|}"

        local total_down=$((int_down + ext_down))
        local total_up=$((int_up + ext_up))
        local total_active=$((total_up + total_down))

        if [[ "$total_down" -eq 0 ]]; then
            pass "All monitors up — internal: ${int_up}, external: ${ext_up} ($paused_count paused)"
            json_add "uptime_kuma" "PASS" "internal: $int_up up, external: $ext_up up, $paused_count paused"
        else
            [[ "$QUIET" == true ]] && section_always 14 "Uptime Kuma Monitors"
            local details=""
            [[ "$int_down" -gt 0 ]] && details="internal down($int_down): $int_down_names"
            [[ "$ext_down" -gt 0 ]] && { [[ -n "$details" ]] && details="$details; "; details="${details}external down($ext_down): $ext_down_names"; }
            if [[ "$total_down" -le 3 ]]; then
                warn "$total_down/$total_active down: $details"
                json_add "uptime_kuma" "WARN" "$details"
            else
                fail "$total_down/$total_active down: $details"
                json_add "uptime_kuma" "FAIL" "$details"
            fi
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

    releases=$(helm list -A --kubeconfig "$KUBECONFIG_PATH" -o json 2>/dev/null) || {
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

    if showmount -e 192.168.1.127 &>/dev/null; then
        pass "NFS server 192.168.1.127 (Proxmox) reachable (exports listed)"
        json_add "nfs" "PASS" "NFS reachable"
    elif nc -z -G 3 192.168.1.127 2049 &>/dev/null; then
        pass "NFS server 192.168.1.127 port 2049 open"
        json_add "nfs" "PASS" "NFS port open"
    else
        [[ "$QUIET" == true ]] && section_always 20 "NFS Connectivity"
        fail "NFS server 192.168.1.127 (Proxmox) unreachable — 30+ services depend on NFS"
        json_add "nfs" "FAIL" "NFS unreachable"
    fi
}

# --- 21. DNS Resolution ---
check_dns() {
    section 21 "DNS Resolution"
    local internal_ok=false external_ok=false detail=""

    # Test DNS from inside the cluster via kubectl exec (MetalLB IPs may not be
    # reachable from outside the L2 network)
    local dns_pod
    dns_pod=$($KUBECTL get pods -n technitium -l app=technitium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$dns_pod" ]]; then
        if $KUBECTL exec -n technitium "$dns_pod" -- nslookup viktorbarzin.me 127.0.0.1 &>/dev/null; then
            internal_ok=true
        fi
        if $KUBECTL exec -n technitium "$dns_pod" -- nslookup google.com 127.0.0.1 &>/dev/null; then
            external_ok=true
        fi
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
        fail "DNS server (Technitium) not resolving — both internal and external failed"
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

# --- 25. Resource Usage ---
check_overcommit() {
    section 25 "Resource Usage"
    local detail="" had_issue=false status="PASS"

    local usage
    usage=$($KUBECTL top nodes --no-headers 2>/dev/null) || { fail "Cannot get node metrics"; json_add "overcommit" "FAIL" "No metrics"; return 0; }

    if [[ -z "$usage" ]]; then
        fail "metrics-server returned no data"
        json_add "overcommit" "FAIL" "No data"
        return 0
    fi

    while IFS= read -r line; do
        local name cpu_pct mem_pct cpu_cores mem_bytes level node_detail
        name=$(echo "$line" | awk '{print $1}')
        cpu_pct=$(echo "$line" | awk '{print $3}' | tr -d '%')
        mem_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
        cpu_cores=$(echo "$line" | awk '{print $2}')
        mem_bytes=$(echo "$line" | awk '{print $4}')

        if [[ "$cpu_pct" -gt 90 || "$mem_pct" -gt 90 ]]; then
            level="FAIL"
        elif [[ "$cpu_pct" -gt 80 || "$mem_pct" -gt 80 ]]; then
            level="WARN"
        else
            level="OK"
        fi

        node_detail="${name}: cpu ${cpu_cores} (${cpu_pct}%), mem ${mem_bytes} (${mem_pct}%)"

        if [[ "$level" == "FAIL" ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 25 "Resource Usage"
            fail "$node_detail"
            had_issue=true
            status="FAIL"
        elif [[ "$level" == "WARN" ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 25 "Resource Usage"
            warn "$node_detail"
            had_issue=true
            [[ "$status" != "FAIL" ]] && status="WARN"
        else
            pass "$node_detail"
        fi
        detail+="$node_detail; "
    done <<< "$usage"

    json_add "overcommit" "$status" "$detail"
}

# --- HA helpers ---
HA_CACHE_DIR=""

ha_sofia_available() {
    if [[ -z "${HOME_ASSISTANT_SOFIA_URL:-}" ]]; then
        export HOME_ASSISTANT_SOFIA_URL="https://ha-sofia.viktorbarzin.me"
    fi
    if [[ -z "${HOME_ASSISTANT_SOFIA_TOKEN:-}" ]]; then
        if command -v vault >/dev/null 2>&1 && [[ -n "${VAULT_TOKEN:-}${HOME:-}" ]]; then
            local t
            t=$(vault kv get -field=haos_api_token secret/viktor 2>/dev/null || true)
            [[ -n "$t" ]] && export HOME_ASSISTANT_SOFIA_TOKEN="$t"
        fi
    fi
    [[ -n "${HOME_ASSISTANT_SOFIA_TOKEN:-}" ]] || return 1
    return 0
}

# Fetch all HA data once and cache in temp files
ha_sofia_fetch_cache() {
    if [[ -n "$HA_CACHE_DIR" ]]; then
        return 0
    fi
    HA_CACHE_DIR=$(mktemp -d)
    export HA_CACHE_DIR
    trap "rm -rf $HA_CACHE_DIR" EXIT

    python3 << 'HA_FETCH_EOF'
import os, json, requests, sys

url = os.environ["HOME_ASSISTANT_SOFIA_URL"]
token = os.environ["HOME_ASSISTANT_SOFIA_TOKEN"]
cache = os.environ["HA_CACHE_DIR"]
headers = {"Authorization": f"Bearer {token}"}

errors = []

# Fetch states (used by checks 26, 28)
try:
    resp = requests.get(f"{url}/api/states", headers=headers, timeout=30)
    resp.raise_for_status()
    with open(f"{cache}/states.json", "w") as f:
        json.dump(resp.json(), f)
except Exception as e:
    errors.append(f"states:{e}")

# Fetch config entries (used by check 27)
try:
    resp = requests.get(f"{url}/api/config/config_entries/entry", headers=headers, timeout=30)
    resp.raise_for_status()
    with open(f"{cache}/entries.json", "w") as f:
        json.dump(resp.json(), f)
except Exception as e:
    errors.append(f"entries:{e}")

# Fetch config (used by check 29)
try:
    resp = requests.get(f"{url}/api/config", headers=headers, timeout=10)
    resp.raise_for_status()
    with open(f"{cache}/config.json", "w") as f:
        json.dump(resp.json(), f)
except Exception as e:
    errors.append(f"config:{e}")

if errors:
    with open(f"{cache}/errors.txt", "w") as f:
        f.write("\n".join(errors))
HA_FETCH_EOF
}

# --- 26. HA Entity Availability ---
check_ha_entities() {
    section 26 "HA Sofia — Entity Availability"

    if ! ha_sofia_available; then
        warn "HA Sofia token not configured — skipping"
        json_add "ha_entities" "WARN" "Token not configured"
        return 0
    fi

    ha_sofia_fetch_cache

    if [[ ! -f "$HA_CACHE_DIR/states.json" ]]; then
        local err=""
        [[ -f "$HA_CACHE_DIR/errors.txt" ]] && err=$(grep "^states:" "$HA_CACHE_DIR/errors.txt" | head -1)
        [[ "$QUIET" == true ]] && section_always 26 "HA Sofia — Entity Availability"
        warn "HA Sofia API unreachable: ${err:-unknown error}"
        json_add "ha_entities" "WARN" "API unreachable"
        return 0
    fi

    local result
    result=$(export HA_CACHE_DIR; python3 << 'PYEOF'
import os, json

cache = os.environ["HA_CACHE_DIR"]
with open(f"{cache}/states.json") as f:
    states = json.load(f)

unavail = [s for s in states if s.get("state") in ("unavailable", "unknown")]
domains = {}
for s in unavail:
    d = s["entity_id"].split(".")[0]
    domains[d] = domains.get(d, 0) + 1

total = len(states)
count = len(unavail)
summary = ", ".join(f"{d}:{n}" for d, n in sorted(domains.items(), key=lambda x: -x[1]))
entity_list = "\n".join("ENTITY:" + s["entity_id"] for s in unavail)
print(f"{count}:{total}:{summary}")
if entity_list:
    print(entity_list)
PYEOF
) || result="ERROR:python execution failed"

    if [[ "$result" == "ERROR:"* ]]; then
        [[ "$QUIET" == true ]] && section_always 26 "HA Sofia — Entity Availability"
        warn "HA Sofia: ${result#ERROR:}"
        json_add "ha_entities" "WARN" "${result#ERROR:}"
        return 0
    fi

    local first_line count total summary
    first_line=$(echo "$result" | head -1)
    count=$(echo "$first_line" | cut -d: -f1)
    total=$(echo "$first_line" | cut -d: -f2)
    summary=$(echo "$first_line" | cut -d: -f3-)

    if [[ "$count" -eq 0 ]]; then
        pass "All $total HA entities available"
        json_add "ha_entities" "PASS" "0/$total unavailable"
    elif [[ "$count" -le 10 ]]; then
        [[ "$QUIET" == true ]] && section_always 26 "HA Sofia — Entity Availability"
        warn "$count/$total entities unavailable ($summary)"
        if [[ "$JSON" != true && "$QUIET" != true ]]; then
            echo "$result" | grep "^ENTITY:" | sed 's/^ENTITY:/    /'
        fi
        json_add "ha_entities" "WARN" "$count/$total: $summary"
    else
        [[ "$QUIET" == true ]] && section_always 26 "HA Sofia — Entity Availability"
        fail "$count/$total entities unavailable ($summary)"
        if [[ "$JSON" != true && "$QUIET" != true ]]; then
            echo "$result" | grep "^ENTITY:" | head -20 | sed 's/^ENTITY:/    /'
            local entity_count
            entity_count=$(echo "$result" | grep -c "^ENTITY:" || true)
            if [[ "$entity_count" -gt 20 ]]; then
                echo "    ... and $((entity_count - 20)) more"
            fi
        fi
        json_add "ha_entities" "FAIL" "$count/$total: $summary"
    fi
}

# --- 27. HA Integration Health ---
check_ha_integrations() {
    section 27 "HA Sofia — Integration Health"

    if ! ha_sofia_available; then
        warn "HA Sofia token not configured — skipping"
        json_add "ha_integrations" "WARN" "Token not configured"
        return 0
    fi

    ha_sofia_fetch_cache

    if [[ ! -f "$HA_CACHE_DIR/entries.json" ]]; then
        [[ "$QUIET" == true ]] && section_always 27 "HA Sofia — Integration Health"
        warn "HA Sofia config entries API unavailable"
        json_add "ha_integrations" "WARN" "API unavailable"
        return 0
    fi

    local result
    result=$(export HA_CACHE_DIR; python3 << 'PYEOF'
import os, json

cache = os.environ["HA_CACHE_DIR"]
with open(f"{cache}/entries.json") as f:
    entries = json.load(f)

total = len(entries)
not_loaded = []
setup_error = []
for e in entries:
    state = e.get("state", "loaded")
    domain = e.get("domain", "?")
    title = e.get("title", "?")
    if state == "setup_error" or state == "setup_retry":
        setup_error.append(f"{domain} ({title})")
    elif state == "not_loaded":
        not_loaded.append(f"{domain} ({title})")

error_count = len(setup_error)
unloaded_count = len(not_loaded)
error_names = "; ".join(setup_error) if setup_error else ""
unloaded_names = "; ".join(not_loaded) if not_loaded else ""
print(f"{total}:{error_count}:{unloaded_count}:{error_names}:{unloaded_names}")
PYEOF
) || result="ERROR:python execution failed"

    if [[ "$result" == "ERROR:"* ]]; then
        [[ "$QUIET" == true ]] && section_always 27 "HA Sofia — Integration Health"
        warn "HA Sofia: ${result#ERROR:}"
        json_add "ha_integrations" "WARN" "${result#ERROR:}"
        return 0
    fi

    local total error_count unloaded_count error_names unloaded_names
    total=$(echo "$result" | cut -d: -f1)
    error_count=$(echo "$result" | cut -d: -f2)
    unloaded_count=$(echo "$result" | cut -d: -f3)
    error_names=$(echo "$result" | cut -d: -f4)
    unloaded_names=$(echo "$result" | cut -d: -f5-)

    if [[ "$error_count" -gt 0 ]]; then
        [[ "$QUIET" == true ]] && section_always 27 "HA Sofia — Integration Health"
        fail "$error_count integration(s) in error state: $error_names"
        json_add "ha_integrations" "FAIL" "$error_count errors: $error_names"
    elif [[ "$unloaded_count" -gt 0 ]]; then
        [[ "$QUIET" == true ]] && section_always 27 "HA Sofia — Integration Health"
        warn "$unloaded_count integration(s) not loaded: $unloaded_names"
        json_add "ha_integrations" "WARN" "$unloaded_count not loaded: $unloaded_names"
    else
        pass "All $total integrations loaded"
        json_add "ha_integrations" "PASS" "All $total loaded"
    fi
}

# --- 28. HA Automation Status ---
check_ha_automations() {
    section 28 "HA Sofia — Automation Status"

    if ! ha_sofia_available; then
        warn "HA Sofia token not configured — skipping"
        json_add "ha_automations" "WARN" "Token not configured"
        return 0
    fi

    ha_sofia_fetch_cache

    if [[ ! -f "$HA_CACHE_DIR/states.json" ]]; then
        [[ "$QUIET" == true ]] && section_always 28 "HA Sofia — Automation Status"
        warn "HA Sofia states API unavailable"
        json_add "ha_automations" "WARN" "API unavailable"
        return 0
    fi

    local result
    result=$(export HA_CACHE_DIR; python3 << 'PYEOF'
import os, json
from datetime import datetime, timezone

cache = os.environ["HA_CACHE_DIR"]
with open(f"{cache}/states.json") as f:
    states = json.load(f)

autos = [s for s in states if s["entity_id"].startswith("automation.")]
total = len(autos)
disabled = [a["entity_id"] for a in autos if a["state"] == "off"]
disabled_count = len(disabled)

now = datetime.now(timezone.utc)
stale = []
for a in autos:
    if a["state"] == "off":
        continue
    lt = a.get("attributes", {}).get("last_triggered")
    if lt:
        try:
            t = datetime.fromisoformat(lt.replace("Z", "+00:00"))
            days = (now - t).days
            if days > 30:
                stale.append(a["entity_id"] + "=" + str(days) + "d")
        except:
            pass

stale_count = len(stale)
disabled_names = "; ".join(disabled)
stale_names = "; ".join(stale[:10])
print(f"{total}:{disabled_count}:{stale_count}:{disabled_names}:{stale_names}")
PYEOF
) || result="ERROR:python execution failed"

    if [[ "$result" == "ERROR:"* ]]; then
        [[ "$QUIET" == true ]] && section_always 28 "HA Sofia — Automation Status"
        warn "HA Sofia: ${result#ERROR:}"
        json_add "ha_automations" "WARN" "${result#ERROR:}"
        return 0
    fi

    local total disabled_count stale_count disabled_names stale_names
    total=$(echo "$result" | cut -d: -f1)
    disabled_count=$(echo "$result" | cut -d: -f2)
    stale_count=$(echo "$result" | cut -d: -f3)
    disabled_names=$(echo "$result" | cut -d: -f4)
    stale_names=$(echo "$result" | cut -d: -f5-)

    local status="PASS" detail=""
    if [[ "$disabled_count" -gt 0 ]]; then
        [[ "$QUIET" == true ]] && section_always 28 "HA Sofia — Automation Status"
        warn "$disabled_count/$total automation(s) disabled"
        if [[ "$JSON" != true && "$QUIET" != true && -n "$disabled_names" ]]; then
            echo "$disabled_names" | tr ';' '\n' | sed 's/^ */    /'
        fi
        status="WARN"
        detail+="$disabled_count disabled; "
    fi

    if [[ "$stale_count" -gt 0 ]]; then
        [[ "$status" == "PASS" && "$QUIET" == true ]] && section_always 28 "HA Sofia — Automation Status"
        warn "$stale_count automation(s) not triggered in 30+ days"
        if [[ "$JSON" != true && "$QUIET" != true && -n "$stale_names" ]]; then
            echo "$stale_names" | tr ';' '\n' | sed 's/^ */    /'
        fi
        [[ "$status" == "PASS" ]] && status="WARN"
        detail+="$stale_count stale; "
    fi

    if [[ "$status" == "PASS" ]]; then
        pass "All $total automations enabled and recently active"
        json_add "ha_automations" "PASS" "All $total active"
    else
        json_add "ha_automations" "$status" "$detail"
    fi
}

# --- 29. HA System Resources ---
check_ha_system() {
    section 29 "HA Sofia — System Resources"

    if ! ha_sofia_available; then
        warn "HA Sofia token not configured — skipping"
        json_add "ha_system" "WARN" "Token not configured"
        return 0
    fi

    ha_sofia_fetch_cache

    if [[ ! -f "$HA_CACHE_DIR/states.json" ]] || [[ ! -f "$HA_CACHE_DIR/config.json" ]]; then
        [[ "$QUIET" == true ]] && section_always 29 "HA Sofia — System Resources"
        warn "HA Sofia API unavailable for system check"
        json_add "ha_system" "WARN" "API unavailable"
        return 0
    fi

    local result
    result=$(export HA_CACHE_DIR; python3 << 'PYEOF'
import os, json

cache = os.environ["HA_CACHE_DIR"]
with open(f"{cache}/states.json") as f:
    states = json.load(f)
with open(f"{cache}/config.json") as f:
    config = json.load(f)

version = config.get("version", "unknown")
entity_map = {s["entity_id"]: s for s in states}

cpu_patterns = ["sensor.processor_use", "sensor.system_monitor_processor_use"]
mem_patterns = ["sensor.memory_use_percent", "sensor.system_monitor_memory_use_percent"]
disk_patterns = ["sensor.disk_use_percent", "sensor.disk_use_percent_", "sensor.system_monitor_disk_use_percent"]

def find_entity(patterns):
    for p in patterns:
        if p in entity_map:
            try:
                return float(entity_map[p]["state"])
            except (ValueError, TypeError):
                pass
    for eid, s in entity_map.items():
        for p in patterns:
            if p.rstrip("_") in eid and "percent" in eid:
                try:
                    return float(s["state"])
                except (ValueError, TypeError):
                    pass
    return None

cpu = find_entity(cpu_patterns)
mem = find_entity(mem_patterns)
disk = find_entity(disk_patterns)

parts = ["version=" + version]
if cpu is not None:
    parts.append("cpu=" + str(int(cpu)))
if mem is not None:
    parts.append("mem=" + str(int(mem)))
if disk is not None:
    parts.append("disk=" + str(int(disk)))

level = "PASS"
for val in [cpu, mem, disk]:
    if val is not None:
        if val > 90:
            level = "FAIL"
            break
        elif val > 80:
            level = "WARN"

print(level + ":" + ":".join(parts))
PYEOF
) || result="ERROR:python execution failed"

    if [[ "$result" == "ERROR:"* ]]; then
        [[ "$QUIET" == true ]] && section_always 29 "HA Sofia — System Resources"
        warn "HA Sofia: ${result#ERROR:}"
        json_add "ha_system" "WARN" "${result#ERROR:}"
        return 0
    fi

    local level detail
    level=$(echo "$result" | cut -d: -f1)
    detail=$(echo "$result" | cut -d: -f2-)

    if [[ "$level" == "FAIL" ]]; then
        [[ "$QUIET" == true ]] && section_always 29 "HA Sofia — System Resources"
        fail "HA Sofia resources critical: $detail"
        json_add "ha_system" "FAIL" "$detail"
    elif [[ "$level" == "WARN" ]]; then
        [[ "$QUIET" == true ]] && section_always 29 "HA Sofia — System Resources"
        warn "HA Sofia resources elevated: $detail"
        json_add "ha_system" "WARN" "$detail"
    else
        pass "HA Sofia healthy ($detail)"
        json_add "ha_system" "PASS" "$detail"
    fi
}

# --- 30. Hardware Exporters ---
check_hardware_exporters() {
    section 30 "Hardware Exporters"
    local detail="" had_issue=false status="PASS"

    # Check exporter pods are Running
    local exporters=(
        "monitoring:snmp-exporter"
        "monitoring:idrac-redfish-exporter"
        "monitoring:proxmox-exporter"
        "tuya-bridge:tuya-bridge"
    )

    for entry in "${exporters[@]}"; do
        local ns="${entry%%:*}"
        local name="${entry##*:}"
        local pods
        pods=$($KUBECTL get pods -n "$ns" -l "app=$name" --no-headers 2>/dev/null || true)

        # If label selector returns nothing, try matching by deployment name prefix
        if [[ -z "$pods" ]]; then
            pods=$($KUBECTL get pods -n "$ns" --no-headers 2>/dev/null | grep "^${name}-" || true)
        fi

        if [[ -z "$pods" ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 30 "Hardware Exporters"
            fail "$ns/$name: no pods found"
            detail+="$ns/$name=missing; "
            had_issue=true
            status="FAIL"
            continue
        fi

        local not_running
        not_running=$(echo "$pods" | awk '$3 != "Running" && $3 != "Completed" {print $1 ": " $3}' || true)
        if [[ -n "$not_running" ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 30 "Hardware Exporters"
            fail "$ns/$name pod not running: $not_running"
            detail+="$ns/$name=not-running; "
            had_issue=true
            status="FAIL"
        fi
    done

    # Check Prometheus scrape targets for hardware exporters
    local prom_jobs=("snmp-idrac" "snmp-ups" "redfish-idrac" "proxmox-host")
    local up_result
    up_result=$($KUBECTL exec -n monitoring deploy/prometheus-server -- \
        wget -q -O- 'http://localhost:9090/api/v1/query?query=up' 2>/dev/null || true)

    if [[ -n "$up_result" ]]; then
        for job in "${prom_jobs[@]}"; do
            local job_up
            job_up=$(echo "$up_result" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('data', {}).get('result', []):
    if r.get('metric', {}).get('job') == '$job':
        print(r.get('value', [0, '0'])[1])
        break
else:
    print('missing')
" 2>/dev/null) || job_up="error"

            if [[ "$job_up" == "1" ]]; then
                detail+="$job=up; "
            elif [[ "$job_up" == "missing" ]]; then
                [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 30 "Hardware Exporters"
                warn "Prometheus target '$job' not found"
                detail+="$job=missing; "
                had_issue=true
                [[ "$status" != "FAIL" ]] && status="WARN"
            else
                [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 30 "Hardware Exporters"
                fail "Prometheus target '$job' is down (up=$job_up)"
                detail+="$job=down; "
                had_issue=true
                status="FAIL"
            fi
        done
    else
        [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 30 "Hardware Exporters"
        warn "Cannot query Prometheus for exporter targets"
        detail+="prometheus-query-failed; "
        had_issue=true
        [[ "$status" != "FAIL" ]] && status="WARN"
    fi

    if [[ "$had_issue" == false ]]; then
        pass "All hardware exporters running and scraped by Prometheus"
    fi
    json_add "hardware_exporters" "$status" "${detail:-All healthy}"
}

# Returns 0 if cert-manager CRDs are installed, 1 otherwise.
cert_manager_installed() {
    $KUBECTL get crd certificates.cert-manager.io -o name >/dev/null 2>&1
}

# --- 31. cert-manager: Certificate Readiness ---
check_cert_manager_certificates() {
    section 31 "cert-manager — Certificate Readiness"
    local certs not_ready detail="" status="PASS"

    if ! cert_manager_installed; then
        pass "cert-manager not installed — N/A"
        json_add "certmanager_certificates" "PASS" "N/A (cert-manager not installed)"
        return 0
    fi

    certs=$($KUBECTL get certificates.cert-manager.io -A -o json 2>/dev/null) || {
        warn "cert-manager CRDs installed but API query failed"
        json_add "certmanager_certificates" "WARN" "API query failed"
        return 0
    }

    not_ready=$(echo "$certs" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    ns = item["metadata"]["namespace"]
    name = item["metadata"]["name"]
    conds = item.get("status", {}).get("conditions", [])
    ready = next((c for c in conds if c.get("type") == "Ready"), None)
    if not ready or ready.get("status") != "True":
        reason = ready.get("reason", "NoCondition") if ready else "NoCondition"
        print(f"{ns}/{name}:{reason}")
' 2>/dev/null) || true

    if [[ -z "$not_ready" ]]; then
        pass "All Certificate CRs Ready"
        json_add "certmanager_certificates" "PASS" "All Ready"
    else
        [[ "$QUIET" == true ]] && section_always 31 "cert-manager — Certificate Readiness"
        local count
        count=$(count_lines "$not_ready")
        while IFS= read -r line; do
            fail "Certificate not Ready: $line"
            detail+="$line; "
        done <<< "$not_ready"
        status="FAIL"
        json_add "certmanager_certificates" "$status" "$count not Ready: $detail"
    fi
}

# --- 32. cert-manager: Certificate Expiry (<14d) ---
check_cert_manager_expiry() {
    section 32 "cert-manager — Certificate Expiry (<14d)"
    local certs expiring detail="" status="PASS"

    if ! cert_manager_installed; then
        pass "cert-manager not installed — N/A"
        json_add "certmanager_expiry" "PASS" "N/A (cert-manager not installed)"
        return 0
    fi

    certs=$($KUBECTL get certificates.cert-manager.io -A -o json 2>/dev/null) || {
        warn "cert-manager CRDs installed but API query failed"
        json_add "certmanager_expiry" "WARN" "API query failed"
        return 0
    }

    expiring=$(echo "$certs" | python3 -c '
import json, sys
from datetime import datetime, timezone, timedelta
data = json.load(sys.stdin)
cutoff = datetime.now(timezone.utc) + timedelta(days=14)
for item in data.get("items", []):
    ns = item["metadata"]["namespace"]
    name = item["metadata"]["name"]
    not_after = item.get("status", {}).get("notAfter")
    if not not_after:
        continue
    try:
        expiry = datetime.fromisoformat(not_after.replace("Z", "+00:00"))
        if expiry < cutoff:
            days = (expiry - datetime.now(timezone.utc)).days
            level = "FAIL" if days <= 3 else "WARN"
            print(f"{level}:{ns}/{name}:{days}")
    except ValueError:
        pass
' 2>/dev/null) || true

    if [[ -z "$expiring" ]]; then
        pass "No Certificate CRs expiring within 14 days"
        json_add "certmanager_expiry" "PASS" "None expiring <14d"
    else
        [[ "$QUIET" == true ]] && section_always 32 "cert-manager — Certificate Expiry (<14d)"
        while IFS= read -r line; do
            local level cert_name days
            level=$(echo "$line" | cut -d: -f1)
            cert_name=$(echo "$line" | cut -d: -f2)
            days=$(echo "$line" | cut -d: -f3)
            if [[ "$level" == "FAIL" ]]; then
                fail "Certificate $cert_name expires in ${days}d"
                status="FAIL"
            else
                warn "Certificate $cert_name expires in ${days}d"
                [[ "$status" != "FAIL" ]] && status="WARN"
            fi
            detail+="$cert_name=${days}d; "
        done <<< "$expiring"
        json_add "certmanager_expiry" "$status" "$detail"
    fi
}

# --- 33. cert-manager: Failed CertificateRequests ---
check_cert_manager_requests() {
    section 33 "cert-manager — Failed CertificateRequests"
    local requests failed detail="" status="PASS"

    if ! cert_manager_installed; then
        pass "cert-manager not installed — N/A"
        json_add "certmanager_requests" "PASS" "N/A (cert-manager not installed)"
        return 0
    fi

    requests=$($KUBECTL get certificaterequests.cert-manager.io -A -o json 2>/dev/null) || {
        warn "cert-manager CRDs installed but API query failed"
        json_add "certmanager_requests" "WARN" "API query failed"
        return 0
    }

    failed=$(echo "$requests" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    ns = item["metadata"]["namespace"]
    name = item["metadata"]["name"]
    conds = item.get("status", {}).get("conditions", [])
    for c in conds:
        if c.get("type") == "Ready" and c.get("status") == "False" and c.get("reason") == "Failed":
            print(f"{ns}/{name}:{c.get(\"message\", \"\")[:80]}")
            break
' 2>/dev/null) || true

    if [[ -z "$failed" ]]; then
        pass "No failed CertificateRequests"
        json_add "certmanager_requests" "PASS" "None failed"
    else
        [[ "$QUIET" == true ]] && section_always 33 "cert-manager — Failed CertificateRequests"
        local count
        count=$(count_lines "$failed")
        while IFS= read -r line; do
            fail "CertificateRequest failed: $line"
            detail+="$line; "
        done <<< "$failed"
        status="FAIL"
        json_add "certmanager_requests" "$status" "$count failed: $detail"
    fi
}

# --- 34. Backup Freshness: Per-DB Dumps ---
check_backup_per_db() {
    section 34 "Backup Freshness — Per-DB Dumps"
    local detail="" had_issue=false status="PASS"

    # Freshness threshold: 25 hours
    local now_epoch max_age_sec
    now_epoch=$(date -u +%s)
    max_age_sec=$((25 * 3600))

    _check_cronjob_fresh() {
        local ns="$1" cj="$2" label="$3"
        local ts age_sec
        ts=$($KUBECTL get cronjob -n "$ns" "$cj" -o jsonpath='{.status.lastSuccessfulTime}' 2>/dev/null || true)
        if [[ -z "$ts" ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 34 "Backup Freshness — Per-DB Dumps"
            fail "$label: CronJob $ns/$cj has no lastSuccessfulTime"
            detail+="${label}=no-success; "
            had_issue=true
            status="FAIL"
            return 0
        fi
        local ts_epoch
        ts_epoch=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
        age_sec=$((now_epoch - ts_epoch))
        if [[ "$age_sec" -gt "$max_age_sec" ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 34 "Backup Freshness — Per-DB Dumps"
            local age_h=$((age_sec / 3600))
            fail "$label: last success ${age_h}h ago (>25h)"
            detail+="${label}=${age_h}h; "
            had_issue=true
            status="FAIL"
        else
            local age_h=$((age_sec / 3600))
            detail+="${label}=${age_h}h; "
        fi
    }

    _check_cronjob_fresh dbaas mysql-backup-per-db mysql
    _check_cronjob_fresh dbaas postgresql-backup-per-db pg

    [[ "$had_issue" == false ]] && pass "Per-DB dumps fresh — $detail"
    json_add "backup_per_db" "$status" "$detail"
}

# --- 35. Backup Freshness: Offsite Sync ---
check_backup_offsite_sync() {
    section 35 "Backup Freshness — Offsite Sync"
    local metrics detail="" status="PASS"

    metrics=$($KUBECTL exec -n monitoring deploy/prometheus-server -- \
        wget -qO- "http://prometheus-prometheus-pushgateway:9091/metrics" 2>/dev/null || true)

    if [[ -z "$metrics" ]]; then
        [[ "$QUIET" == true ]] && section_always 35 "Backup Freshness — Offsite Sync"
        warn "Cannot query Pushgateway"
        json_add "backup_offsite_sync" "WARN" "Pushgateway unreachable"
        return 0
    fi

    local age_hours
    age_hours=$(echo "$metrics" | python3 -c '
import sys, re, time
ts = None
for line in sys.stdin:
    if line.startswith("#"):
        continue
    if "backup_last_success_timestamp" in line and "offsite-backup-sync" in line:
        m = re.search(r"\s([0-9.eE+]+)\s*$", line.strip())
        if m:
            try:
                ts = float(m.group(1))
                break
            except ValueError:
                pass
if ts is None:
    print("missing")
else:
    age = (time.time() - ts) / 3600
    print(f"{age:.1f}")
' 2>/dev/null) || age_hours="error"

    if [[ "$age_hours" == "missing" ]]; then
        [[ "$QUIET" == true ]] && section_always 35 "Backup Freshness — Offsite Sync"
        fail "backup_last_success_timestamp metric missing for offsite-backup-sync"
        json_add "backup_offsite_sync" "FAIL" "Metric missing"
    elif [[ "$age_hours" == "error" ]]; then
        [[ "$QUIET" == true ]] && section_always 35 "Backup Freshness — Offsite Sync"
        warn "Failed to parse Pushgateway metric"
        json_add "backup_offsite_sync" "WARN" "Parse error"
    else
        local age_int
        age_int=$(printf '%.0f' "$age_hours")
        if [[ "$age_int" -gt 27 ]]; then
            [[ "$QUIET" == true ]] && section_always 35 "Backup Freshness — Offsite Sync"
            fail "Offsite sync last success ${age_hours}h ago (>27h)"
            status="FAIL"
        else
            pass "Offsite sync last success ${age_hours}h ago"
        fi
        detail="age=${age_hours}h"
        json_add "backup_offsite_sync" "$status" "$detail"
    fi
}

# --- 36. Backup Freshness: LVM PVC Snapshots ---
check_backup_lvm_snapshots() {
    section 36 "Backup Freshness — LVM PVC Snapshots"
    local snap_output detail="" status="PASS"

    snap_output=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        root@192.168.1.127 "lvs -o lv_name,lv_time --noheadings 2>/dev/null | grep _snap" 2>/dev/null || true)

    if [[ -z "$snap_output" ]]; then
        [[ "$QUIET" == true ]] && section_always 36 "Backup Freshness — LVM PVC Snapshots"
        warn "No LVM PVC snapshots found or SSH to 192.168.1.127 failed (BatchMode)"
        json_add "backup_lvm_snapshots" "WARN" "SSH failed or no snapshots"
        return 0
    fi

    local newest_age_hours
    newest_age_hours=$(echo "$snap_output" | python3 -c '
import sys, re, time
from datetime import datetime
newest = None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split(None, 1)
    if len(parts) < 2:
        continue
    date_str = parts[1].strip()
    # lv_time format: "2026-04-19 03:00:01 +0000" or similar
    for fmt in ("%Y-%m-%d %H:%M:%S %z", "%Y-%m-%d %H:%M:%S"):
        try:
            dt = datetime.strptime(date_str, fmt)
            ts = dt.timestamp()
            if newest is None or ts > newest:
                newest = ts
            break
        except ValueError:
            continue
if newest is None:
    print("parse_error")
else:
    age = (time.time() - newest) / 3600
    print(f"{age:.1f}")
' 2>/dev/null) || newest_age_hours="error"

    if [[ "$newest_age_hours" == "parse_error" || "$newest_age_hours" == "error" ]]; then
        [[ "$QUIET" == true ]] && section_always 36 "Backup Freshness — LVM PVC Snapshots"
        warn "Could not parse LVM snapshot timestamps"
        json_add "backup_lvm_snapshots" "WARN" "Parse error"
    else
        local count age_int
        count=$(count_lines "$snap_output")
        age_int=$(printf '%.0f' "$newest_age_hours")
        if [[ "$age_int" -gt 25 ]]; then
            [[ "$QUIET" == true ]] && section_always 36 "Backup Freshness — LVM PVC Snapshots"
            fail "Newest LVM snapshot ${newest_age_hours}h old (>25h); $count total"
            status="FAIL"
        else
            pass "LVM snapshots fresh — $count total, newest ${newest_age_hours}h old"
        fi
        detail="count=$count newest=${newest_age_hours}h"
        json_add "backup_lvm_snapshots" "$status" "$detail"
    fi
}

# --- 37. Monitoring: Prometheus + Alertmanager ---
check_monitoring_prom_am() {
    section 37 "Monitoring — Prometheus + Alertmanager"
    local detail="" had_issue=false status="PASS"

    # Prometheus /-/ready
    local prom_ready
    prom_ready=$($KUBECTL exec -n monitoring deploy/prometheus-server -- \
        wget -qO- "http://localhost:9090/-/ready" 2>/dev/null || true)
    if echo "$prom_ready" | grep -qi "ready"; then
        detail+="prometheus=ready; "
    else
        [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 37 "Monitoring — Prometheus + Alertmanager"
        fail "Prometheus /-/ready returned no Ready response"
        detail+="prometheus=not-ready; "
        had_issue=true
        status="FAIL"
    fi

    # Alertmanager running pod count
    local am_running
    am_running=$($KUBECTL get pods -n monitoring --no-headers 2>/dev/null | \
        grep alertmanager | awk '$3 == "Running"' | wc -l | tr -d ' ')
    if [[ "$am_running" -gt 0 ]]; then
        detail+="alertmanager=${am_running} running; "
    else
        [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 37 "Monitoring — Prometheus + Alertmanager"
        fail "Alertmanager: 0 Running pods"
        detail+="alertmanager=none-running; "
        had_issue=true
        status="FAIL"
    fi

    [[ "$had_issue" == false ]] && pass "Prometheus Ready, $am_running Alertmanager pod(s) Running"
    json_add "monitoring_prom_am" "$status" "$detail"
}

# --- 38. Monitoring: Vault Sealed Status ---
check_monitoring_vault() {
    section 38 "Monitoring — Vault Sealed Status"
    local output detail="" status="PASS"

    output=$($KUBECTL exec -n vault vault-0 -- \
        sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status' 2>&1 || true)

    if [[ -z "$output" ]]; then
        [[ "$QUIET" == true ]] && section_always 38 "Monitoring — Vault Sealed Status"
        fail "Cannot exec vault status on vault-0"
        json_add "monitoring_vault" "FAIL" "Exec failed"
        return 0
    fi

    if echo "$output" | grep -qi "^Sealed[[:space:]]*false"; then
        pass "Vault unsealed"
        detail="sealed=false"
        json_add "monitoring_vault" "PASS" "$detail"
    elif echo "$output" | grep -qi "^Sealed[[:space:]]*true"; then
        [[ "$QUIET" == true ]] && section_always 38 "Monitoring — Vault Sealed Status"
        fail "Vault is SEALED — secrets unavailable"
        detail="sealed=true"
        status="FAIL"
        json_add "monitoring_vault" "$status" "$detail"
    else
        [[ "$QUIET" == true ]] && section_always 38 "Monitoring — Vault Sealed Status"
        warn "Cannot parse vault status output"
        json_add "monitoring_vault" "WARN" "Parse error"
    fi
}

# --- 39. Monitoring: ClusterSecretStore Ready ---
check_monitoring_css() {
    section 39 "Monitoring — ClusterSecretStore Ready"
    local css not_ready detail="" status="PASS"

    css=$($KUBECTL get clustersecretstore -o json 2>/dev/null) || {
        [[ "$QUIET" == true ]] && section_always 39 "Monitoring — ClusterSecretStore Ready"
        warn "ClusterSecretStore CRD not installed"
        json_add "monitoring_css" "WARN" "CRD missing"
        return 0
    }

    not_ready=$(echo "$css" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    name = item["metadata"]["name"]
    conds = item.get("status", {}).get("conditions", [])
    ready = next((c for c in conds if c.get("type") == "Ready"), None)
    if not ready or ready.get("status") != "True":
        print(f"{name}:{ready.get(\"reason\", \"NoCondition\") if ready else \"NoCondition\"}")
' 2>/dev/null) || true

    if [[ -z "$not_ready" ]]; then
        local total
        total=$(echo "$css" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items",[])))' 2>/dev/null || echo "?")
        pass "All $total ClusterSecretStores Ready"
        json_add "monitoring_css" "PASS" "$total Ready"
    else
        [[ "$QUIET" == true ]] && section_always 39 "Monitoring — ClusterSecretStore Ready"
        while IFS= read -r line; do
            fail "ClusterSecretStore not Ready: $line"
            detail+="$line; "
        done <<< "$not_ready"
        status="FAIL"
        json_add "monitoring_css" "$status" "$detail"
    fi
}

# --- 40. External Reachability: Cloudflared + Authentik Replicas ---
check_external_replicas() {
    section 40 "External — Cloudflared + Authentik Replicas"
    local detail="" had_issue=false status="PASS"

    # Cloudflared
    local cf_json cf_ready cf_desired
    cf_json=$($KUBECTL get deployment cloudflared -n cloudflared -o json 2>/dev/null || true)
    if [[ -z "$cf_json" ]]; then
        [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 40 "External — Cloudflared + Authentik Replicas"
        fail "Cloudflared deployment not found"
        detail+="cloudflared=missing; "
        had_issue=true
        status="FAIL"
    else
        cf_ready=$(echo "$cf_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",{}).get("readyReplicas",0) or 0)' 2>/dev/null || echo "0")
        cf_desired=$(echo "$cf_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("spec",{}).get("replicas",0) or 0)' 2>/dev/null || echo "0")
        if [[ "$cf_ready" != "$cf_desired" ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 40 "External — Cloudflared + Authentik Replicas"
            fail "Cloudflared: $cf_ready/$cf_desired ready (external access degraded)"
            detail+="cloudflared=${cf_ready}/${cf_desired}; "
            had_issue=true
            status="FAIL"
        else
            detail+="cloudflared=${cf_ready}/${cf_desired}; "
        fi
    fi

    # Authentik server (Helm chart names the deployment goauthentik-server)
    local auth_json auth_ready auth_desired
    auth_json=$($KUBECTL get deployment goauthentik-server -n authentik -o json 2>/dev/null || true)
    if [[ -z "$auth_json" ]]; then
        [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 40 "External — Cloudflared + Authentik Replicas"
        warn "goauthentik-server deployment not found in authentik namespace"
        detail+="authentik=missing; "
        had_issue=true
        [[ "$status" != "FAIL" ]] && status="WARN"
    else
        auth_ready=$(echo "$auth_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",{}).get("readyReplicas",0) or 0)' 2>/dev/null || echo "0")
        auth_desired=$(echo "$auth_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("spec",{}).get("replicas",0) or 0)' 2>/dev/null || echo "0")
        if [[ "$auth_ready" != "$auth_desired" ]]; then
            [[ "$had_issue" == false && "$QUIET" == true ]] && section_always 40 "External — Cloudflared + Authentik Replicas"
            fail "goauthentik-server: $auth_ready/$auth_desired ready (auth degraded)"
            detail+="authentik=${auth_ready}/${auth_desired}; "
            had_issue=true
            status="FAIL"
        else
            detail+="authentik=${auth_ready}/${auth_desired}; "
        fi
    fi

    [[ "$had_issue" == false ]] && pass "Cloudflared + authentik-server at full replicas ($detail)"
    json_add "external_replicas" "$status" "$detail"
}

# --- 41. External Reachability: ExternalAccessDivergence Alert ---
check_external_divergence() {
    section 41 "External — ExternalAccessDivergence Alert"
    local alerts result detail="" status="PASS"

    alerts=$($KUBECTL exec -n monitoring deploy/prometheus-server -- \
        wget -qO- "http://localhost:9090/api/v1/alerts" 2>/dev/null || true)

    if [[ -z "$alerts" ]]; then
        [[ "$QUIET" == true ]] && section_always 41 "External — ExternalAccessDivergence Alert"
        warn "Cannot query Prometheus alerts"
        json_add "external_divergence" "WARN" "Cannot query"
        return 0
    fi

    result=$(echo "$alerts" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    alerts = data.get("data", {}).get("alerts", []) if isinstance(data, dict) else data
    firing = [a for a in alerts
              if a.get("labels", {}).get("alertname") == "ExternalAccessDivergence"
              and a.get("state") == "firing"]
    if firing:
        hosts = [a.get("labels", {}).get("host") or a.get("labels", {}).get("service") or "?" for a in firing]
        print(f"{len(firing)}:" + ",".join(hosts))
    else:
        print("0:")
except Exception as e:
    print(f"error:{e}")
' 2>/dev/null) || result="error:parse"

    if [[ "$result" == error:* ]]; then
        [[ "$QUIET" == true ]] && section_always 41 "External — ExternalAccessDivergence Alert"
        warn "Failed to parse alerts JSON: ${result#error:}"
        json_add "external_divergence" "WARN" "Parse error"
        return 0
    fi

    local count names
    count=$(echo "$result" | cut -d: -f1)
    names=$(echo "$result" | cut -d: -f2-)

    if [[ "$count" -eq 0 ]]; then
        pass "ExternalAccessDivergence not firing"
        json_add "external_divergence" "PASS" "Not firing"
    else
        [[ "$QUIET" == true ]] && section_always 41 "External — ExternalAccessDivergence Alert"
        fail "ExternalAccessDivergence firing for $count target(s): $names"
        status="FAIL"
        detail="$count firing: $names"
        json_add "external_divergence" "$status" "$detail"
    fi
}

# --- 42. External Reachability: Traefik 5xx Rate ---
check_external_traefik_5xx() {
    section 42 "External — Traefik 5xx Rate (15m)"
    local query_result detail="" status="PASS"

    query_result=$($KUBECTL exec -n monitoring deploy/prometheus-server -- \
        wget -qO- 'http://localhost:9090/api/v1/query?query=topk(10,rate(traefik_service_requests_total{code=~%225..%22}%5B15m%5D))' 2>/dev/null || true)

    if [[ -z "$query_result" ]]; then
        [[ "$QUIET" == true ]] && section_always 42 "External — Traefik 5xx Rate (15m)"
        warn "Cannot query Prometheus for traefik 5xx rate"
        json_add "external_traefik_5xx" "WARN" "Query failed"
        return 0
    fi

    local parsed
    parsed=$(echo "$query_result" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    results = data.get("data", {}).get("result", [])
    hot = [(r.get("metric", {}).get("service", "?"), float(r.get("value", [0, "0"])[1])) for r in results]
    hot = [(s, v) for s, v in hot if v > 0.01]  # 1% req/s threshold
    hot.sort(key=lambda x: -x[1])
    if not hot:
        print("0:")
    else:
        top = [f"{s}={v:.2f}/s" for s, v in hot[:5]]
        print(f"{len(hot)}:" + "; ".join(top))
except Exception as e:
    print(f"error:{e}")
' 2>/dev/null) || parsed="error:parse"

    if [[ "$parsed" == error:* ]]; then
        [[ "$QUIET" == true ]] && section_always 42 "External — Traefik 5xx Rate (15m)"
        warn "Parse failed: ${parsed#error:}"
        json_add "external_traefik_5xx" "WARN" "Parse error"
        return 0
    fi

    local count top
    count=$(echo "$parsed" | cut -d: -f1)
    top=$(echo "$parsed" | cut -d: -f2-)

    if [[ "$count" -eq 0 ]]; then
        pass "No Traefik services with 5xx rate >0.01 req/s (last 15m)"
        json_add "external_traefik_5xx" "PASS" "None above threshold"
    else
        [[ "$QUIET" == true ]] && section_always 42 "External — Traefik 5xx Rate (15m)"
        # WARN at any 5xx; FAIL if top service >1 req/s
        local top_rate
        top_rate=$(echo "$top" | grep -oE '[0-9.]+/s' | head -1 | tr -d '/s')
        if awk "BEGIN{exit !($top_rate > 1.0)}" 2>/dev/null; then
            fail "$count Traefik service(s) with elevated 5xx: $top"
            status="FAIL"
        else
            warn "$count Traefik service(s) emitting 5xx: $top"
            status="WARN"
        fi
        detail="$count services: $top"
        json_add "external_traefik_5xx" "$status" "$detail"
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
    check_overcommit
    check_ha_entities
    check_ha_integrations
    check_ha_automations
    check_ha_system
    check_hardware_exporters
    check_cert_manager_certificates
    check_cert_manager_expiry
    check_cert_manager_requests
    check_backup_per_db
    check_backup_offsite_sync
    check_backup_lvm_snapshots
    check_monitoring_prom_am
    check_monitoring_vault
    check_monitoring_css
    check_external_replicas
    check_external_divergence
    check_external_traefik_5xx
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
