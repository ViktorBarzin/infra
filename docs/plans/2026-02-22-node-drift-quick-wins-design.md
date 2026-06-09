# Node Configuration Drift Quick Wins — Design

**Date**: 2026-02-22
**Status**: Approved
**Context**: From Talos Linux evaluation — these close 95% of the drift gap without changing the OS

## Quick Win 1: Add GPU Label to Terraform

**File**: `stacks/platform/modules/nvidia/main.tf`

Extend the existing `null_resource.gpu_node_taint` to also apply the `gpu=true` label. Rename to `gpu_node_config`. Both commands are idempotent (`--overwrite` for taint, label is a no-op if already set).

## Quick Win 2: Improve API Server OIDC/Audit Idempotency

**Files**: `stacks/platform/modules/rbac/apiserver-oidc.tf`, `audit-policy.tf`

Current grep-before-sed checks prevent duplicate entries but don't handle value changes. Improve the OIDC check to compare the actual issuer URL value, not just the flag name. Audit policy file is always re-uploaded (good), manifest edit is skipped if already configured (acceptable).

## Quick Win 3: Enable Node-Exporter via Prometheus Helm Chart

**File**: `stacks/platform/modules/monitoring/prometheus_chart_values.tpl`

Uncomment `prometheus-node-exporter: enabled: true`. Delete `playbooks/deploy_node_exporter.yaml` (unused, superseded by DaemonSet).

## Quick Win 4: Document Node Rebuild Procedure

**File**: `.claude/CLAUDE.md`

Add a "Node Rebuild Procedure" section documenting the full sequence: VM creation from template → cloud-init → kubeadm join → verify mirrors/labels/taints.
