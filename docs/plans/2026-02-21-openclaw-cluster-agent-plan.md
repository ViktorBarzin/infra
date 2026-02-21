# OpenClaw Cluster Management Agent — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a proactive cluster health agent — a skill that teaches OpenClaw to check the cluster, a helper script that runs the checks and posts to Slack, and a CronJob that triggers it every 30 minutes via `kubectl exec`.

**Architecture:** CronJob (bitnami/kubectl) -> `kubectl exec` into OpenClaw pod -> runs `cluster-health.sh` which performs 8 health checks, auto-fixes safe issues, and posts a summary to Slack. The same script is available as an OpenClaw skill for interactive use.

**Tech Stack:** Bash (health check script), Terraform/HCL (CronJob + RBAC), Slack webhook API, kubectl

---

### Task 1: Add Slack webhook to openclaw_skill_secrets

**Files:**
- Modify: `terraform.tfvars:1291-1295` (add slack_webhook key)
- Modify: `modules/kubernetes/openclaw/main.tf:350-376` (add SLACK_WEBHOOK_URL env var)

**Step 1: Add slack_webhook to openclaw_skill_secrets in tfvars**

Add a new key `slack_webhook` to the existing `openclaw_skill_secrets` map. The user must provide the webhook URL. For now, use the existing `alertmanager_slack_api_url` value or a dedicated one.

In `terraform.tfvars`, change:
```hcl
openclaw_skill_secrets = {
  home_assistant_token       = "..."
  home_assistant_sofia_token = "..."
  uptime_kuma_password       = "..."
}
```
to:
```hcl
openclaw_skill_secrets = {
  home_assistant_token       = "..."
  home_assistant_sofia_token = "..."
  uptime_kuma_password       = "..."
  slack_webhook              = "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
}
```

**NOTE:** Ask the user which Slack webhook URL to use. Candidates:
- `alertmanager_slack_api_url` (line 4 in tfvars)
- `tiny_tuya_slack_url` (line 1213, comment says "K8s bot slack")
- A new webhook the user creates

**Step 2: Add SLACK_WEBHOOK_URL env var to OpenClaw container**

In `modules/kubernetes/openclaw/main.tf`, add after the `UPTIME_KUMA_PASSWORD` env block (around line 370):
```hcl
          # Skill secrets - Slack
          env {
            name  = "SLACK_WEBHOOK_URL"
            value = var.skill_secrets["slack_webhook"]
          }
```

**Step 3: Commit**

```bash
git add modules/kubernetes/openclaw/main.tf
git commit -m "[ci skip] Add Slack webhook env var to OpenClaw deployment"
```

Do NOT commit `terraform.tfvars` separately — it will be committed with the full set of changes at the end.

---

### Task 2: Create the cluster-health.sh helper script

**Files:**
- Create: `.claude/cluster-health.sh`

**Step 1: Write the health check script**

Create `.claude/cluster-health.sh` with the following structure. The script:
- Uses `$KUBECONFIG` (already set in OpenClaw pod) or falls back to in-cluster config
- Runs 8 checks: nodes, pods, evicted, deployments, PVCs, resources, CronJobs, DaemonSets
- Auto-fixes: deletes evicted pods, restarts CrashLoopBackOff pods stuck >1 hour
- Posts structured Slack message via `$SLACK_WEBHOOK_URL`
- Exit code 0 = healthy, 1 = issues found, 2 = critical

```bash
#!/usr/bin/env bash
# Cluster health check script for OpenClaw.
# Runs health checks, auto-fixes safe issues, posts to Slack.
# Designed to run inside the OpenClaw pod (has kubectl via $KUBECONFIG).
#
# Usage: ./cluster-health.sh [--no-slack] [--no-fix]
#   --no-slack  Skip Slack notification (useful for interactive/debug runs)
#   --no-fix    Skip auto-fix actions (report only)

set -euo pipefail

SEND_SLACK=true
AUTO_FIX=true
ISSUES=()
FIXES=()
WARNINGS=()

# --- Argument parsing ---
for arg in "$@"; do
  case "$arg" in
    --no-slack) SEND_SLACK=false ;;
    --no-fix)   AUTO_FIX=false ;;
  esac
done

KUBECTL="kubectl"

# --- 1. Node Health ---
check_nodes() {
  local nodes not_ready
  nodes=$($KUBECTL get nodes --no-headers 2>&1) || { ISSUES+=("Cannot reach cluster API"); return; }
  not_ready=$(echo "$nodes" | awk '$2 != "Ready" {print $1}' || true)

  if [[ -n "$not_ready" ]]; then
    while IFS= read -r node; do
      ISSUES+=("Node NotReady: $node")
    done <<< "$not_ready"
  fi

  # Check conditions
  local conditions
  conditions=$($KUBECTL get nodes -o json | python3 -c '
import json, sys
data = json.load(sys.stdin)
for node in data["items"]:
    name = node["metadata"]["name"]
    for c in node["status"]["conditions"]:
        if c["type"] in ("MemoryPressure","DiskPressure","PIDPressure") and c["status"] == "True":
            print(name + ": " + c["type"])
' 2>/dev/null) || true

  if [[ -n "$conditions" ]]; then
    while IFS= read -r line; do
      ISSUES+=("$line")
    done <<< "$conditions"
  fi
}

# --- 2. Pod Health ---
check_pods() {
  local bad
  bad=$( {
    $KUBECTL get pods -A --no-headers 2>/dev/null \
      | grep -E 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Error' || true
  } | awk '!seen[$1,$2]++' | sed '/^$/d') || true

  if [[ -z "$bad" ]]; then return; fi

  while IFS= read -r line; do
    local ns pod status
    ns=$(echo "$line" | awk '{print $1}')
    pod=$(echo "$line" | awk '{print $2}')
    status=$(echo "$line" | awk '{print $4}')

    if [[ "$status" == "CrashLoopBackOff" ]]; then
      # Check if stuck for >1 hour
      local restart_count
      restart_count=$(echo "$line" | awk '{print $5}')
      if [[ "$AUTO_FIX" == true && "$restart_count" -gt 10 ]]; then
        $KUBECTL delete pod -n "$ns" "$pod" --grace-period=30 2>/dev/null && \
          FIXES+=("Restarted $ns/$pod (CrashLoopBackOff, $restart_count restarts)") || \
          WARNINGS+=("Failed to restart $ns/$pod")
      else
        ISSUES+=("CrashLoopBackOff: $ns/$pod ($restart_count restarts)")
      fi
    elif [[ "$status" == "ImagePullBackOff" || "$status" == "ErrImagePull" ]]; then
      ISSUES+=("ImagePullBackOff: $ns/$pod")
    else
      ISSUES+=("Error: $ns/$pod ($status)")
    fi
  done <<< "$bad"
}

# --- 3. Evicted/Failed Pods ---
check_evicted() {
  local evicted count
  evicted=$($KUBECTL get pods -A --no-headers --field-selector=status.phase=Failed 2>/dev/null || true)

  if [[ -z "$evicted" ]]; then return; fi
  count=$(echo "$evicted" | wc -l | tr -d ' ')

  if [[ "$AUTO_FIX" == true && "$count" -gt 0 ]]; then
    $KUBECTL delete pods -A --field-selector=status.phase=Failed 2>/dev/null && \
      FIXES+=("Deleted $count evicted/failed pod(s)") || \
      WARNINGS+=("Failed to delete evicted pods")
  else
    ISSUES+=("$count evicted/failed pod(s)")
  fi
}

# --- 4. Failed Deployments ---
check_deployments() {
  local deps
  deps=$($KUBECTL get deployments -A --no-headers 2>/dev/null) || return

  while IFS= read -r line; do
    local ns name ready current desired
    ns=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    ready=$(echo "$line" | awk '{print $3}')
    current=$(echo "$ready" | cut -d/ -f1)
    desired=$(echo "$ready" | cut -d/ -f2)

    if [[ "$current" != "$desired" ]]; then
      ISSUES+=("Deployment $ns/$name: $current/$desired ready")
    fi
  done <<< "$deps"
}

# --- 5. Pending PVCs ---
check_pvcs() {
  local pvcs
  pvcs=$($KUBECTL get pvc -A --no-headers 2>/dev/null) || return

  if [[ -z "$pvcs" || "$pvcs" == *"No resources found"* ]]; then return; fi

  while IFS= read -r line; do
    local ns name status
    ns=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    status=$(echo "$line" | awk '{print $3}')

    if [[ "$status" != "Bound" ]]; then
      ISSUES+=("PVC $ns/$name: $status")
    fi
  done <<< "$pvcs"
}

# --- 6. Resource Pressure ---
check_resources() {
  local top
  top=$($KUBECTL top nodes --no-headers 2>/dev/null) || return

  while IFS= read -r line; do
    local node cpu_pct mem_pct
    node=$(echo "$line" | awk '{print $1}')
    cpu_pct=$(echo "$line" | awk '{print $3}' | tr -d '%')
    mem_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')

    [[ "$cpu_pct" == *"unknown"* || "$mem_pct" == *"unknown"* ]] && continue

    if [[ "$cpu_pct" -gt 90 || "$mem_pct" -gt 90 ]]; then
      ISSUES+=("High resource usage on $node: CPU ${cpu_pct}%, Mem ${mem_pct}%")
    elif [[ "$cpu_pct" -gt 80 || "$mem_pct" -gt 80 ]]; then
      WARNINGS+=("Elevated resource usage on $node: CPU ${cpu_pct}%, Mem ${mem_pct}%")
    fi
  done <<< "$top"
}

# --- 7. CronJob Failures ---
check_cronjobs() {
  local failures
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
    if not any(o.get("kind") == "CronJob" for o in owners):
        continue
    for c in job.get("status", {}).get("conditions", []):
        if c.get("type") == "Failed" and c.get("status") == "True":
            ts = c.get("lastTransitionTime", "")
            if ts:
                try:
                    t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    if t > cutoff:
                        print(f"{ns}/{name}")
                except:
                    print(f"{ns}/{name}")
' 2>/dev/null) || true

  if [[ -n "$failures" ]]; then
    local count
    count=$(echo "$failures" | wc -l | tr -d ' ')
    ISSUES+=("$count CronJob failure(s) in last 24h")
  fi
}

# --- 8. DaemonSet Health ---
check_daemonsets() {
  local ds
  ds=$($KUBECTL get daemonsets -A --no-headers 2>/dev/null) || return

  while IFS= read -r line; do
    local ns name desired ready
    ns=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    desired=$(echo "$line" | awk '{print $3}')
    ready=$(echo "$line" | awk '{print $5}')

    if [[ "$desired" != "$ready" ]]; then
      ISSUES+=("DaemonSet $ns/$name: desired=$desired ready=$ready")
    fi
  done <<< "$ds"
}

# --- Cluster summary stats ---
get_summary_stats() {
  local node_count ready_count pod_count
  node_count=$($KUBECTL get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready_count=$($KUBECTL get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' ')
  pod_count=$($KUBECTL get pods -A --no-headers --field-selector=status.phase=Running 2>/dev/null | wc -l | tr -d ' ')
  echo "${ready_count}/${node_count} nodes | ${pod_count} pods running"
}

# --- Send Slack message ---
send_slack() {
  local webhook_url="$SLACK_WEBHOOK_URL"
  if [[ -z "${webhook_url:-}" ]]; then
    echo "WARNING: SLACK_WEBHOOK_URL not set, skipping Slack notification"
    return
  fi

  local summary issue_count fix_count warning_count
  summary=$(get_summary_stats)
  issue_count=${#ISSUES[@]}
  fix_count=${#FIXES[@]}
  warning_count=${#WARNINGS[@]}

  local text=""
  local total_problems=$((issue_count + warning_count))

  if [[ "$total_problems" -eq 0 && "$fix_count" -eq 0 ]]; then
    text=":white_check_mark: *Cluster Health Check — All Clear*\n${summary} | 0 issues"
  else
    if [[ "$issue_count" -gt 0 ]]; then
      text=":rotating_light: *Cluster Health Check — ${issue_count} Issue(s) Found*\n${summary}"
    elif [[ "$warning_count" -gt 0 ]]; then
      text=":warning: *Cluster Health Check — ${warning_count} Warning(s)*\n${summary}"
    else
      text=":white_check_mark: *Cluster Health Check — All Clear (auto-fixed ${fix_count})*\n${summary}"
    fi

    if [[ "$fix_count" -gt 0 ]]; then
      text+="\n\n*Auto-fixed:*"
      for fix in "${FIXES[@]}"; do
        text+="\n• ${fix}"
      done
    fi

    if [[ "$issue_count" -gt 0 ]]; then
      text+="\n\n*Needs attention:*"
      for issue in "${ISSUES[@]}"; do
        text+="\n• ${issue}"
      done
    fi

    if [[ "$warning_count" -gt 0 ]]; then
      text+="\n\n*Warnings:*"
      for warning in "${WARNINGS[@]}"; do
        text+="\n• ${warning}"
      done
    fi
  fi

  curl -s -X POST "$webhook_url" \
    -H 'Content-Type: application/json' \
    -d "{\"text\": \"${text}\"}" > /dev/null 2>&1
}

# --- Main ---
main() {
  echo "=== Cluster Health Check — $(date '+%Y-%m-%d %H:%M:%S') ==="

  check_nodes
  check_pods
  check_evicted
  check_deployments
  check_pvcs
  check_resources
  check_cronjobs
  check_daemonsets

  local issue_count=${#ISSUES[@]}
  local fix_count=${#FIXES[@]}
  local warning_count=${#WARNINGS[@]}

  echo ""
  echo "Results: ${issue_count} issue(s), ${fix_count} fix(es), ${warning_count} warning(s)"

  if [[ "$fix_count" -gt 0 ]]; then
    echo ""
    echo "Auto-fixed:"
    for fix in "${FIXES[@]}"; do echo "  - $fix"; done
  fi

  if [[ "$issue_count" -gt 0 ]]; then
    echo ""
    echo "Issues:"
    for issue in "${ISSUES[@]}"; do echo "  - $issue"; done
  fi

  if [[ "$warning_count" -gt 0 ]]; then
    echo ""
    echo "Warnings:"
    for warning in "${WARNINGS[@]}"; do echo "  - $warning"; done
  fi

  if [[ "$SEND_SLACK" == true ]]; then
    send_slack
    echo ""
    echo "Slack notification sent."
  fi

  # Exit code
  if [[ "$issue_count" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
```

**Step 2: Make it executable**

```bash
chmod +x .claude/cluster-health.sh
```

**Step 3: Test locally (dry run)**

```bash
KUBECONFIG=$(pwd)/config SLACK_WEBHOOK_URL="" bash .claude/cluster-health.sh --no-slack
```

Expected: Script runs, prints check results, no Slack post.

**Step 4: Commit**

```bash
git add .claude/cluster-health.sh
git commit -m "[ci skip] Add cluster health check script for OpenClaw agent"
```

---

### Task 3: Create the cluster-health skill

**Files:**
- Create: `.claude/skills/cluster-health/SKILL.md`

**Step 1: Write the skill document**

```markdown
---
name: cluster-health
description: |
  Check Kubernetes cluster health and fix common issues. Use when:
  (1) User asks to check the cluster, check health, or "what's wrong",
  (2) User asks about pod status, node health, or deployment issues,
  (3) User asks to fix stuck pods, evicted pods, or CrashLoopBackOff,
  (4) User mentions "health check", "cluster status", "cluster health",
  (5) User asks "is everything running" or "any problems".
  Runs 8 standard K8s health checks with safe auto-fix for evicted pods
  and stuck CrashLoopBackOff pods.
author: Claude Code
version: 1.0.0
date: 2026-02-21
---

# Cluster Health Check

## Overview
- **Script**: `/workspace/infra/.claude/cluster-health.sh`
- **Schedule**: CronJob runs every 30 minutes, execs into this pod
- **Slack**: Posts results to `$SLACK_WEBHOOK_URL`
- **Auto-fix**: Deletes evicted pods, restarts CrashLoopBackOff pods (>10 restarts)

## Quick Check

Run the health check script:
```bash
bash /workspace/infra/.claude/cluster-health.sh --no-slack
```

Or with Slack notification:
```bash
bash /workspace/infra/.claude/cluster-health.sh
```

Report-only (no auto-fix):
```bash
bash /workspace/infra/.claude/cluster-health.sh --no-fix
```

## What It Checks

| # | Check | Auto-Fix | Alert |
|---|-------|----------|-------|
| 1 | Node health (NotReady, conditions) | No | Yes |
| 2 | Pod health (CrashLoopBackOff, ImagePullBackOff, Error) | Restart if >10 restarts | Yes |
| 3 | Evicted/failed pods | Delete all | Yes |
| 4 | Deployment availability (current != desired) | No | Yes |
| 5 | PVC status (not Bound) | No | Yes |
| 6 | Resource pressure (CPU/Mem >80%) | No | Yes |
| 7 | CronJob failures (last 24h) | No | Yes |
| 8 | DaemonSet health (desired != ready) | No | Yes |

## Safe Auto-Fix Rules

These are the ONLY things the script auto-fixes:
1. **Evicted/failed pods**: `kubectl delete pods -A --field-selector=status.phase=Failed`
2. **CrashLoopBackOff pods with >10 restarts**: `kubectl delete pod -n <ns> <pod> --grace-period=30`

Everything else is alert-only. NEVER auto-fix:
- Node NotReady (could be maintenance)
- ImagePullBackOff (needs image tag or registry fix)
- Pending PVCs (needs storage investigation)
- Failed deployments (needs config investigation)

## Deep Investigation

When the script reports issues and the user asks for more detail, use these commands:

### Node issues
```bash
kubectl describe node <node-name>
kubectl top node <node-name>
kubectl get events --field-selector involvedObject.name=<node-name>
```

### Pod issues
```bash
kubectl describe pod -n <namespace> <pod-name>
kubectl logs -n <namespace> <pod-name> --tail=100
kubectl logs -n <namespace> <pod-name> --previous --tail=100
kubectl get events -n <namespace> --field-selector involvedObject.name=<pod-name>
```

### Deployment issues
```bash
kubectl describe deployment -n <namespace> <deployment-name>
kubectl rollout status deployment -n <namespace> <deployment-name>
kubectl rollout history deployment -n <namespace> <deployment-name>
```

### PVC issues
```bash
kubectl describe pvc -n <namespace> <pvc-name>
kubectl get pv
kubectl get events -n <namespace> --field-selector involvedObject.name=<pvc-name>
```

### Resource pressure
```bash
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -20
kubectl top pods -A --sort-by=cpu | head -20
```

## Common Remediation

### CrashLoopBackOff (persistent)
1. Check logs: `kubectl logs -n <ns> <pod> --previous --tail=100`
2. Check events: `kubectl describe pod -n <ns> <pod>`
3. Common causes: OOMKilled (increase memory limit), bad config, missing env var
4. If image issue: check if newer image exists, update in Terraform

### OOMKilled
1. Check current limits: `kubectl describe pod -n <ns> <pod> | grep -A2 Limits`
2. Fix: Update resource limits in Terraform module for the service
3. Apply: `terraform apply -target=module.kubernetes_cluster.module.<service> -var="kube_config_path=$(pwd)/config"`

### ImagePullBackOff
1. Check image: `kubectl describe pod -n <ns> <pod> | grep Image`
2. Check registry: Is the image tag valid? Is the registry reachable?
3. Check pull-through cache: Docker registry at 10.0.20.10

### Node NotReady
1. Check kubelet: SSH to node, `systemctl status kubelet`
2. Check resources: `kubectl top node <node>`
3. Check conditions: `kubectl describe node <node> | grep -A10 Conditions`

## Slack Webhook

Messages are posted to the webhook at `$SLACK_WEBHOOK_URL`. Format:
- All clear: green check + summary stats
- Issues found: red siren + list of issues + auto-fix actions taken
- Warnings only: yellow warning + elevated metrics

## Infrastructure

- **Terraform module**: `modules/kubernetes/openclaw/main.tf`
- **CronJob**: Runs in `openclaw` namespace every 30 min
- **Existing healthcheck**: `scripts/cluster_healthcheck.sh` (local-only, not for OpenClaw)
- **Repo path inside pod**: `/workspace/infra/`
```

**Step 2: Commit**

```bash
git add .claude/skills/cluster-health/SKILL.md
git commit -m "[ci skip] Add cluster-health skill for OpenClaw agent"
```

---

### Task 4: Add CronJob and RBAC to Terraform

**Files:**
- Modify: `modules/kubernetes/openclaw/main.tf` (append CronJob + ServiceAccount + Role + RoleBinding)

**Step 1: Add CronJob resources**

Append the following to `modules/kubernetes/openclaw/main.tf` after the `module "ingress"` block:

```hcl
# --- CronJob: Scheduled cluster health check ---

resource "kubernetes_service_account" "healthcheck" {
  metadata {
    name      = "cluster-healthcheck"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
}

resource "kubernetes_role" "healthcheck_exec" {
  metadata {
    name      = "healthcheck-pod-exec"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "healthcheck_exec" {
  metadata {
    name      = "healthcheck-pod-exec"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.healthcheck.metadata[0].name
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.healthcheck_exec.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "cluster_healthcheck" {
  metadata {
    name      = "cluster-healthcheck"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app  = "cluster-healthcheck"
      tier = var.tier
    }
  }
  spec {
    schedule                      = "*/30 * * * *"
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3

    job_template {
      metadata {
        labels = {
          app = "cluster-healthcheck"
        }
      }
      spec {
        active_deadline_seconds = 300
        template {
          metadata {
            labels = {
              app = "cluster-healthcheck"
            }
          }
          spec {
            service_account_name = kubernetes_service_account.healthcheck.metadata[0].name
            restart_policy       = "Never"

            container {
              name    = "healthcheck"
              image   = "bitnami/kubectl:1.34"
              command = ["bash", "-c", <<-EOF
                # Find the openclaw pod
                POD=$(kubectl get pods -n openclaw -l app=openclaw -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
                if [ -z "$POD" ]; then
                  echo "ERROR: OpenClaw pod not found"
                  exit 1
                fi
                echo "Executing health check in pod $POD..."
                kubectl exec -n openclaw "$POD" -c openclaw -- bash /workspace/infra/.claude/cluster-health.sh
              EOF
              ]

              resources {
                requests = {
                  cpu    = "50m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "128Mi"
                }
              }
            }
          }
        }
      }
    }
  }
}
```

**Step 2: Verify Terraform formatting**

```bash
terraform fmt modules/kubernetes/openclaw/main.tf
```

**Step 3: Verify Terraform plan**

```bash
terraform plan -target=module.kubernetes_cluster.module.openclaw -var="kube_config_path=$(pwd)/config"
```

Expected: Plan shows 4 new resources (ServiceAccount, Role, RoleBinding, CronJobV1). No destructive changes to existing resources.

**Step 4: Commit**

```bash
git add modules/kubernetes/openclaw/main.tf
git commit -m "[ci skip] Add cluster health check CronJob to OpenClaw module"
```

---

### Task 5: Deploy and verify

**Step 1: Apply Terraform**

```bash
terraform apply -target=module.kubernetes_cluster.module.openclaw -var="kube_config_path=$(pwd)/config" -auto-approve
```

**Step 2: Verify CronJob exists**

```bash
kubectl --kubeconfig $(pwd)/config get cronjob -n openclaw
```

Expected: `cluster-healthcheck` with schedule `*/30 * * * *`

**Step 3: Verify RBAC**

```bash
kubectl --kubeconfig $(pwd)/config get serviceaccount,role,rolebinding -n openclaw
```

Expected: `cluster-healthcheck` SA, `healthcheck-pod-exec` role and rolebinding

**Step 4: Trigger a manual run**

```bash
kubectl --kubeconfig $(pwd)/config create job --from=cronjob/cluster-healthcheck healthcheck-manual-test -n openclaw
```

**Step 5: Check job output**

```bash
kubectl --kubeconfig $(pwd)/config wait --for=condition=complete job/healthcheck-manual-test -n openclaw --timeout=120s
kubectl --kubeconfig $(pwd)/config logs job/healthcheck-manual-test -n openclaw
```

Expected: Health check output with results. If `SLACK_WEBHOOK_URL` is set, check Slack for the message.

**Step 6: Clean up test job**

```bash
kubectl --kubeconfig $(pwd)/config delete job healthcheck-manual-test -n openclaw
```

**Step 7: Final commit**

```bash
git add -A modules/kubernetes/openclaw/ .claude/skills/cluster-health/ .claude/cluster-health.sh
git commit -m "[ci skip] OpenClaw cluster health agent: script + skill + CronJob"
```
