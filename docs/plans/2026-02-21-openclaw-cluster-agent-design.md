# OpenClaw Cluster Management Agent — Design

**Date**: 2026-02-21
**Status**: Approved

## Goal

Build a proactive cluster management agent that runs scheduled health checks every 30 minutes, auto-fixes safe issues, and alerts via Slack. The agent is "taught" via an OpenClaw skill and a reusable health check script.

## Architecture

```
CronJob (every 30min)
  └─ kubectl exec into OpenClaw pod
       └─ /workspace/infra/.claude/cluster-health.sh
            ├─ kubectl get nodes (check health)
            ├─ kubectl get pods -A (find problems)
            ├─ kubectl delete pod (evicted/stuck)
            └─ curl Slack webhook (report)
```

Interactive path: User asks OpenClaw via UI -> `cluster-health` skill triggers -> runs same script -> LLM analyzes output and can do deeper investigation.

## Components

### 1. `cluster-health` skill (`.claude/skills/cluster-health/SKILL.md`)

Teaches OpenClaw:
- What health checks to run
- What's safe to auto-fix vs alert-only
- How to format Slack alerts
- How to do deeper investigation when asked interactively

Trigger conditions: "check cluster", "cluster health", "what's wrong", "health check", etc.

### 2. `cluster-health.sh` helper script (`.claude/cluster-health.sh`)

Reusable script that performs all checks:

**Checks:**
- Node health (NotReady, MemoryPressure, DiskPressure, PIDPressure)
- Pod health (CrashLoopBackOff, ImagePullBackOff, Error, OOMKilled, Pending)
- Evicted pods
- Failed deployments (unavailable replicas)
- Pending PVCs
- Resource pressure (high CPU/memory allocation)
- Failed CronJobs
- DaemonSet health (missing pods)

**Safe auto-fix actions:**
- Delete evicted pods
- Delete completed/succeeded pods older than 24h
- Restart (delete) pods in CrashLoopBackOff for more than 1 hour

**Alert-only (never auto-fix):**
- Node NotReady
- Persistent OOMKilled
- ImagePullBackOff
- Pending PVCs
- Failed deployments with 0 available replicas

**Output:**
- Structured text summary
- Posts to Slack via webhook
- Exit code 0 = healthy, 1 = issues found

### 3. Kubernetes CronJob (in `modules/kubernetes/openclaw/main.tf`)

- Schedule: `*/30 * * * *`
- Container: `bitnami/kubectl` (minimal image with kubectl)
- Command: `kubectl exec deploy/openclaw -n openclaw -- /bin/bash /workspace/infra/.claude/cluster-health.sh`
- ServiceAccount with RBAC to exec into pods in `openclaw` namespace
- `concurrencyPolicy: Forbid`
- `failedJobsHistoryLimit: 3`
- `successfulJobsHistoryLimit: 3`

### 4. Slack Integration

- Webhook URL from `openclaw_skill_secrets["slack"]` (already configured)
- Passed as `SLACK_WEBHOOK_URL` env var to the OpenClaw pod

## Slack Message Format

```
:white_check_mark: Cluster Health Check — All Clear
Nodes: 5/5 Ready | Pods: 142 Running | 0 Issues
```

```
:warning: Cluster Health Check — 3 Issues Found

Auto-fixed:
- Deleted 4 evicted pods in monitoring namespace
- Restarted stuck pod calibre-web-xyz (CrashLoopBackOff >1h)

Needs attention:
- Node k8s-node3: MemoryPressure condition detected
- PVC data-tandoor pending for 45 minutes
```

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Mode | Proactive (scheduled) | Want automated monitoring |
| Alert channel | Slack | Existing webhook in openclaw_skill_secrets |
| Auto-fix | Safe fixes only | Delete evicted, restart stuck; alert for the rest |
| Frequency | 30 minutes | Balance between detection speed and overhead |
| Checks scope | Standard K8s health | Pod/node/deployment/PVC/CronJob/DaemonSet |
| Trigger mechanism | CronJob execs into OpenClaw pod | Reuses OpenClaw's tools; LLM available interactively |
| Fallback | None | Uptime Kuma monitors OpenClaw availability |
