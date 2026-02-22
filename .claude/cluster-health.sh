#!/usr/bin/env bash
# Cluster health check script for OpenClaw pod.
# Runs 8 health checks, auto-fixes safe issues, and posts results to Slack.
#
# Usage: bash cluster-health.sh [--no-slack] [--no-fix]
#
# Environment:
#   KUBECONFIG       — path to kubeconfig (set automatically in the pod)
#   SLACK_WEBHOOK_URL — Slack incoming webhook URL (required unless --no-slack)

set -euo pipefail

# --- Globals ---
KUBECTL="kubectl"
SEND_SLACK=true
AUTO_FIX=true
ISSUES=()
FIXES=()
WARNINGS=()

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-slack) SEND_SLACK=false; shift ;;
        --no-fix)   AUTO_FIX=false; shift ;;
        -h|--help)
            echo "Usage: $0 [--no-slack] [--no-fix]"
            echo ""
            echo "Flags:"
            echo "  --no-slack  Skip Slack notification"
            echo "  --no-fix   Skip auto-fix actions (report only)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# --- Helpers ---
count_lines() {
    local input="$1"
    if [[ -z "$input" ]]; then
        echo 0
    else
        echo "$input" | wc -l | tr -d ' '
    fi
}

# --- 1. Node Health ---
echo "=== [1/8] Node Health ==="

node_issues=false
not_ready=$($KUBECTL get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}' || true)
if [[ -n "$not_ready" ]]; then
    while IFS= read -r node; do
        ISSUES+=("Node $node is NotReady")
        echo "  ISSUE: Node $node is NotReady"
    done <<< "$not_ready"
    node_issues=true
fi

# Check node conditions (MemoryPressure, DiskPressure, PIDPressure)
pressure_conditions=$($KUBECTL get nodes -o json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for node in data["items"]:
    name = node["metadata"]["name"]
    for c in node["status"]["conditions"]:
        if c["type"] in ("MemoryPressure", "DiskPressure", "PIDPressure") and c["status"] == "True":
            print(f"{name}: {c[\"type\"]}")
' 2>/dev/null) || true

if [[ -n "$pressure_conditions" ]]; then
    while IFS= read -r line; do
        ISSUES+=("$line")
        echo "  ISSUE: $line"
    done <<< "$pressure_conditions"
    node_issues=true
fi

if [[ "$node_issues" == false ]]; then
    echo "  OK"
fi

# --- 2. Pod Health ---
echo "=== [2/8] Pod Health ==="

bad_pods=$($KUBECTL get pods -A --no-headers 2>/dev/null \
    | grep -E 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Error' || true)

if [[ -n "$bad_pods" ]]; then
    while IFS= read -r line; do
        ns=$(echo "$line" | awk '{print $1}')
        pod=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $4}')
        restarts=$(echo "$line" | awk '{print $5}')

        # Clean up restart count (remove trailing characters like "d", "h" from age-based formats)
        restarts_clean=$(echo "$restarts" | grep -oE '^[0-9]+' || echo "0")

        if [[ "$status" == "CrashLoopBackOff" ]] && [[ "$restarts_clean" -gt 10 ]]; then
            if [[ "$AUTO_FIX" == true ]]; then
                echo "  FIX: Deleting CrashLoopBackOff pod $ns/$pod (restarts: $restarts_clean)"
                $KUBECTL delete pod -n "$ns" "$pod" --grace-period=0 2>/dev/null || true
                FIXES+=("Deleted CrashLoopBackOff pod $ns/$pod ($restarts_clean restarts)")
            else
                ISSUES+=("CrashLoopBackOff pod $ns/$pod with $restarts_clean restarts (would auto-fix)")
                echo "  ISSUE: CrashLoopBackOff pod $ns/$pod with $restarts_clean restarts"
            fi
        else
            ISSUES+=("Pod $ns/$pod in $status state")
            echo "  ISSUE: Pod $ns/$pod in $status state"
        fi
    done <<< "$bad_pods"
else
    echo "  OK"
fi

# --- 3. Evicted/Failed Pods ---
echo "=== [3/8] Evicted/Failed Pods ==="

failed_pods=$($KUBECTL get pods -A --no-headers --field-selector=status.phase=Failed 2>/dev/null || true)
failed_count=$(count_lines "$failed_pods")

if [[ "$failed_count" -gt 0 ]]; then
    if [[ "$AUTO_FIX" == true ]]; then
        echo "  FIX: Deleting $failed_count evicted/failed pods"
        $KUBECTL delete pods -A --field-selector=status.phase=Failed 2>/dev/null || true
        FIXES+=("Deleted $failed_count evicted/failed pods")
    else
        ISSUES+=("$failed_count evicted/failed pods (would auto-fix)")
        echo "  ISSUE: $failed_count evicted/failed pods"
    fi
else
    echo "  OK"
fi

# --- 4. Failed Deployments ---
echo "=== [4/8] Failed Deployments ==="

deploy_issues=false
deployments=$($KUBECTL get deployments -A --no-headers 2>/dev/null || true)

if [[ -n "$deployments" ]]; then
    while IFS= read -r line; do
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        ready_col=$(echo "$line" | awk '{print $3}')
        current=$(echo "$ready_col" | cut -d/ -f1)
        desired=$(echo "$ready_col" | cut -d/ -f2)

        if [[ "$current" != "$desired" ]]; then
            ISSUES+=("Deployment $ns/$name: $current/$desired replicas ready")
            echo "  ISSUE: Deployment $ns/$name: $current/$desired replicas ready"
            deploy_issues=true
        fi
    done <<< "$deployments"
fi

if [[ "$deploy_issues" == false ]]; then
    echo "  OK"
fi

# --- 5. Pending PVCs ---
echo "=== [5/8] Pending PVCs ==="

pvc_issues=false
pvcs=$($KUBECTL get pvc -A --no-headers 2>/dev/null || true)

if [[ -n "$pvcs" && "$pvcs" != *"No resources found"* ]]; then
    while IFS= read -r line; do
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3}')

        if [[ "$status" != "Bound" ]]; then
            ISSUES+=("PVC $ns/$name in $status state")
            echo "  ISSUE: PVC $ns/$name in $status state"
            pvc_issues=true
        fi
    done <<< "$pvcs"
fi

if [[ "$pvc_issues" == false ]]; then
    echo "  OK"
fi

# --- 6. Resource Pressure ---
echo "=== [6/8] Resource Pressure ==="

resource_issues=false
top_output=$($KUBECTL top nodes --no-headers 2>/dev/null || true)

if [[ -n "$top_output" ]]; then
    while IFS= read -r line; do
        node=$(echo "$line" | awk '{print $1}')
        cpu_pct=$(echo "$line" | awk '{print $3}' | tr -d '%')
        mem_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')

        # Skip unknown metrics
        if [[ "$cpu_pct" == *"unknown"* ]] || [[ "$mem_pct" == *"unknown"* ]]; then
            continue
        fi

        if [[ "$cpu_pct" -gt 90 ]] || [[ "$mem_pct" -gt 90 ]]; then
            ISSUES+=("Node $node under pressure: CPU ${cpu_pct}%, Mem ${mem_pct}%")
            echo "  ISSUE: Node $node under pressure: CPU ${cpu_pct}%, Mem ${mem_pct}%"
            resource_issues=true
        elif [[ "$cpu_pct" -gt 80 ]] || [[ "$mem_pct" -gt 80 ]]; then
            WARNINGS+=("Node $node elevated usage: CPU ${cpu_pct}%, Mem ${mem_pct}%")
            echo "  WARN: Node $node elevated usage: CPU ${cpu_pct}%, Mem ${mem_pct}%"
            resource_issues=true
        fi
    done <<< "$top_output"
else
    WARNINGS+=("metrics-server unavailable, cannot check resource pressure")
    echo "  WARN: metrics-server unavailable"
    resource_issues=true
fi

if [[ "$resource_issues" == false ]]; then
    echo "  OK"
fi

# --- 7. CronJob Failures ---
echo "=== [7/8] CronJob Failures ==="

cronjob_failures=$($KUBECTL get jobs -A -o json 2>/dev/null | python3 -c '
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
                except Exception:
                    print(f"{ns}/{name}: {c.get(\"reason\", \"Unknown\")}")
' 2>/dev/null) || true

if [[ -n "$cronjob_failures" ]]; then
    while IFS= read -r line; do
        ISSUES+=("CronJob failure: $line")
        echo "  ISSUE: CronJob failure: $line"
    done <<< "$cronjob_failures"
else
    echo "  OK"
fi

# --- 8. DaemonSet Health ---
echo "=== [8/8] DaemonSet Health ==="

ds_issues=false
daemonsets=$($KUBECTL get daemonsets -A --no-headers 2>/dev/null || true)

if [[ -n "$daemonsets" ]]; then
    while IFS= read -r line; do
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        desired=$(echo "$line" | awk '{print $3}')
        ready=$(echo "$line" | awk '{print $5}')

        if [[ "$desired" != "$ready" ]]; then
            ISSUES+=("DaemonSet $ns/$name: desired=$desired ready=$ready")
            echo "  ISSUE: DaemonSet $ns/$name: desired=$desired ready=$ready"
            ds_issues=true
        fi
    done <<< "$daemonsets"
fi

if [[ "$ds_issues" == false ]]; then
    echo "  OK"
fi

# --- Summary ---
echo ""
echo "==============================="
echo "  Summary"
echo "==============================="

# Gather stats for the summary line
node_count=$($KUBECTL get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
pod_count=$($KUBECTL get pods -A --no-headers --field-selector=status.phase=Running 2>/dev/null | wc -l | tr -d ' ')
issue_count=${#ISSUES[@]}
fix_count=${#FIXES[@]}
warning_count=${#WARNINGS[@]}

stats="${node_count} nodes | ${pod_count} pods running | ${issue_count} issue(s)"

echo "  $stats"

if [[ "$fix_count" -gt 0 ]]; then
    echo ""
    echo "  Auto-fixed:"
    for fix in "${FIXES[@]}"; do
        echo "    - $fix"
    done
fi

if [[ "$issue_count" -gt 0 ]]; then
    echo ""
    echo "  Needs attention:"
    for issue in "${ISSUES[@]}"; do
        echo "    - $issue"
    done
fi

if [[ "$warning_count" -gt 0 ]]; then
    echo ""
    echo "  Warnings:"
    for w in "${WARNINGS[@]}"; do
        echo "    - $w"
    done
fi

# --- Slack notification ---
if [[ "$SEND_SLACK" == true ]]; then
    if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
        echo ""
        echo "WARNING: SLACK_WEBHOOK_URL not set, skipping Slack notification"
    else
        # Build Slack message
        if [[ "$issue_count" -eq 0 && "$warning_count" -eq 0 ]]; then
            slack_text=":white_check_mark: *Cluster Health Check — All Clear*\n${stats}"
        elif [[ "$issue_count" -eq 0 && "$warning_count" -gt 0 ]]; then
            slack_text=":warning: *Cluster Health Check — ${warning_count} Warning(s)*\n${stats}"
            for w in "${WARNINGS[@]}"; do
                slack_text+="\n• ${w}"
            done
        else
            slack_text=":rotating_light: *Cluster Health Check — ${issue_count} Issue(s) Found*\n${stats}"

            if [[ "$fix_count" -gt 0 ]]; then
                slack_text+="\n\n*Auto-fixed:*"
                for fix in "${FIXES[@]}"; do
                    slack_text+="\n• ${fix}"
                done
            fi

            if [[ "$issue_count" -gt 0 ]]; then
                slack_text+="\n\n*Needs attention:*"
                for issue in "${ISSUES[@]}"; do
                    slack_text+="\n• ${issue}"
                done
            fi

            if [[ "$warning_count" -gt 0 ]]; then
                slack_text+="\n\n*Warnings:*"
                for w in "${WARNINGS[@]}"; do
                    slack_text+="\n• ${w}"
                done
            fi
        fi

        # Use python3 to JSON-escape the message body safely
        json_payload=$(python3 -c "
import json, sys
text = sys.stdin.read()
print(json.dumps({'text': text}))
" <<< "$slack_text")

        curl -s -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d "$json_payload" >/dev/null 2>&1 || echo "WARNING: Failed to send Slack notification"

        echo ""
        echo "Slack notification sent."
    fi
fi

# --- Exit code ---
if [[ "$issue_count" -gt 0 ]]; then
    exit 1
fi
exit 0
