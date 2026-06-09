# Security Observability Layer — Design Document

**Date**: 2026-03-02
**Status**: Approved
**Approach**: Tetragon-Centric (Approach A)

## Problem Statement

The cluster has strong perimeter security (CrowdSec, Traefik middleware chain, Cloudflare WAF) and good monitoring (Prometheus, Loki, Grafana), but lacks:
- Runtime security monitoring (syscall-level container activity)
- Egress visibility (what pods connect to externally)
- HTTPS inspection capability (even on-demand)
- Network segmentation (no NetworkPolicies — any pod can reach any pod)
- Firewall log centralization (pfSense logs not in Loki)
- Unified security dashboard

## Requirements

- **Threat model**: Defense in depth — external attacks, compromised containers, lateral movement, data exfiltration
- **TLS inspection**: Connection metadata (SNI/IP/bytes) by default, selective deep inspection on-demand
- **Alerting**: Slack (existing channel)
- **Resource budget**: <5GB RAM total for new tooling
- **Enforcement**: Observe & alert now, enforce later
- **CNI**: Calico (confirmed, with GlobalNetworkPolicy CRD support)

## Architecture

```
                    ┌─────────────────────────────────────────────────┐
                    │              Existing Stack                      │
                    │  Prometheus ← scrape ← Tetragon metrics         │
                    │  Loki ← Alloy ← Tetragon event logs            │
                    │                   ← pfSense syslog              │
                    │                   ← CoreDNS query logs          │
                    │  Grafana ← Unified Security Dashboard           │
                    │  Alertmanager → Slack                           │
                    └─────────────────────────────────────────────────┘

    ┌─────────────┐   ┌──────────────────┐   ┌─────────────────────┐
    │  Tetragon   │   │ Kyverno Policy   │   │  mitmproxy          │
    │ (DaemonSet) │   │ Reporter (1 pod) │   │ (on-demand, 1 pod)  │
    │ eBPF agent  │   │                  │   │ HTTPS inspection    │
    │ per node    │   │ Violations →     │   │ for suspect pods    │
    │             │   │ Prometheus +     │   │                     │
    │ Monitors:   │   │ Grafana          │   │ Transparent proxy   │
    │ • processes │   │                  │   │ via NetworkPolicy   │
    │ • network   │   └──────────────────┘   └─────────────────────┘
    │ • files     │
    │ • syscalls  │   ┌──────────────────┐
    │             │   │ Inspektor Gadget │
    └─────────────┘   │ (temporary)      │
                      │ Auto-generate    │
                      │ NetworkPolicies  │
                      │ from observed    │
                      │ traffic baseline │
                      └──────────────────┘

    ┌────────────────────────────────────────────────┐
    │           Calico NetworkPolicies               │
    │  (Generated from baseline, enforced gradually) │
    │  Default deny egress + allow known connections │
    └────────────────────────────────────────────────┘
```

### Data Flows

1. **Tetragon** → Prometheus (metrics) + stdout → Alloy → Loki (events)
2. **pfSense** → syslog UDP → Alloy syslog receiver → Loki
3. **CoreDNS** → uncomment `log` → stdout → Alloy → Loki
4. **Kyverno Policy Reporter** → Prometheus (violation metrics)
5. **Grafana** ← queries all sources → Unified Security Dashboard
6. **Alertmanager** → Slack (security-specific alert rules)

## Component Details

### 1. Tetragon (Runtime Security + Network Visibility)

**Purpose**: eBPF-based kernel-level monitoring of process execution, network connections, file access, and privilege escalation.

**Deployment**:
- Helm chart: `cilium/tetragon` (CNCF project, part of Cilium ecosystem)
- Type: DaemonSet on all 5 nodes
- Resources: ~80-120MB RAM/node, ~50m CPU idle
- Tier: `1-cluster`
- Namespace: `tetragon`
- New stack: `stacks/tetragon/`

**TracingPolicy CRDs** (what to monitor):

| Policy | Detects | Severity |
|--------|---------|----------|
| Privilege escalation | `setuid(0)`, `setgid(0)`, dangerous capabilities | Critical |
| Reverse shell | Shell process with outbound connection to external IP | Critical |
| Crypto miner | Connections to mining pool ports (3333, 14444, etc.) | Warning |
| Container escape | `mount` syscalls, `/proc/self/ns/*` access, `nsenter` | Critical |
| Sensitive file access | Reads of `/etc/shadow`, K8s service account tokens | Warning |
| Unexpected egress | Outbound connections to non-private IPs (log all) | Info |
| Unexpected binaries | Shells spawning in non-shell containers | Warning |

**Observe → Enforce path**:
- Start: `TracingPolicy` (observe + alert only)
- Later: `TracingPolicyEnforced` (can SIGKILL processes)

**Integration**:
- Prometheus metrics via pod annotations (auto-scraped by existing `kubernetes-pods` job)
- Events as JSON to stdout → Alloy → Loki
- New Prometheus alert rules for critical Tetragon events

### 2. pfSense Log Collection

**Purpose**: Centralize firewall logs into Loki for correlation with cluster security events.

**Implementation**:
- Deploy a small syslog-receiver Deployment (1 replica) with a MetalLB LoadBalancer IP
- Forward received syslog to Loki via `loki.write`
- OR add `loki.source.syslog` to existing Alloy config
- Configure pfSense: Status → System Logs → Settings → Remote Logging → point to syslog receiver IP:1514

**Recommended approach**: Dedicated syslog receiver Deployment (not Alloy DaemonSet) because:
- Stable LoadBalancer IP for pfSense to target
- Doesn't couple to a specific node
- Can parse `filterlog` CSV format independently

**Parse pfSense filterlog**: Extract interface, action (pass/block), direction, source IP, dest IP, protocol, port into Loki labels.

**Resource cost**: ~50-100MB for the syslog receiver pod.

### 3. CoreDNS Query Logging

**Purpose**: Detect DNS tunneling, C2 callbacks, unusual domain lookups.

**Implementation**: Uncomment `#log` → `log` in CoreDNS ConfigMap (`stacks/platform/modules/technitium/main.tf`).

**Scope**: Only enable on the main zone (`.`), NOT the `viktorbarzin.lan` zone (Technitium already logs those to MySQL).

**Alert rules for Loki**:
- High NX domain rate from a single pod
- DNS tunneling signatures (subdomain labels >40 chars)
- Queries to known malicious TLDs

**Resource cost**: 0 additional (just increased log volume in Loki).

### 4. NetworkPolicy Strategy (Calico)

**Purpose**: Restrict pod-to-pod and pod-to-external traffic using Calico NetworkPolicies.

**Phased rollout**:

| Phase | Action | Timeline |
|-------|--------|----------|
| Observe | Deploy Inspektor Gadget, capture 24-48h traffic baseline | Week 1 |
| Generate | `kubectl gadget advise network-policy` per namespace | Week 1 |
| Review | Convert to Terraform `kubernetes_network_policy` resources | Week 2 |
| Enforce (low-risk) | Apply to aux-tier namespaces first | Week 3 |
| Enforce (all) | Gradually apply to edge, cluster, core tiers | Week 4+ |

**Key policies**:
- Default deny egress for aux-tier namespaces
- Allow DNS (port 53) + known external endpoints per service
- Block inter-namespace traffic except known dependencies (redis, postgresql, loki)

**Inspektor Gadget**:
- CNCF Sandbox project, ~80MB/node as DaemonSet
- Temporary deployment — remove after baseline capture (~400MB total while running)
- `kubectl gadget advise network-policy` auto-generates policies from observed traffic

**Resource cost**: 0 permanent (Calico already enforces). ~400MB temporary.

### 5. mitmproxy (On-Demand HTTPS Inspection)

**Purpose**: Deep HTTPS traffic inspection for specific suspicious pods during incident investigation.

**Deployment**:
- Single-replica Deployment, **scaled to 0 by default**
- Namespace: `mitmproxy`
- New stack: `stacks/mitmproxy/`
- Web UI at `mitmproxy.viktorbarzin.lan` (local-only access)

**Usage workflow**:
1. Scale to 1: `kubectl scale deployment mitmproxy --replicas=1 -n mitmproxy`
2. Apply Calico NetworkPolicy redirecting suspect pod's egress through mitmproxy
3. Mount mitmproxy CA cert into target pod's trust store
4. Inspect traffic via web UI
5. Scale back to 0 when done

**Resource cost**: ~200MB when active, 0 when scaled to 0.

### 6. Kyverno Policy Reporter

**Purpose**: Surface Kyverno policy violations (currently in audit mode) in Grafana dashboards.

**Deployment**:
- Add as sub-chart or separate Helm release in Kyverno stack
- 1 replica Deployment
- Exports metrics to Prometheus
- ~50MB RAM

**Integration**:
- Prometheus scrapes Policy Reporter metrics
- Grafana dashboard shows violations by policy, namespace, severity

### 7. Unified Security Dashboard + Alert Rules

**Grafana Dashboard** layout:

| Row | Panels | Data Source |
|-----|--------|-------------|
| Overview | Active CrowdSec bans, Tetragon alerts/24h, Kyverno violations/24h, pfSense blocks/24h | Prometheus |
| Attack Timeline | Combined time series of all security events | Prometheus |
| Runtime Security | Suspicious processes, privilege escalations, file access alerts | Loki (Tetragon) |
| Network | Top egress destinations by namespace, unusual DNS queries, pfSense blocks | Loki + Prometheus |
| Policy | Kyverno violations by policy/namespace/severity | Prometheus (Policy Reporter) |

**New Prometheus Alert Rules**:

| Alert | Trigger | Severity |
|-------|---------|----------|
| `TetragonPrivilegeEscalation` | setuid(0) in non-system container | Critical |
| `TetragonReverseShell` | Shell + outbound connection | Critical |
| `TetragonCryptoMiner` | Connection to mining pool ports | Warning |
| `TetragonUnexpectedEgress` | Pod → unexpected external IP | Warning |
| `SuspiciousDNSQuery` | High NX rate or long subdomains | Warning |
| `PfSenseHighBlockRate` | >100 blocks/min from single source | Warning |
| `KyvernoViolationSpike` | >10 violations in 5 minutes | Warning |

## Resource Budget

| Component | Type | Steady-State RAM | Notes |
|-----------|------|-----------------|-------|
| Tetragon | DaemonSet (5 nodes) | ~500MB | Runtime security + egress |
| Syslog receiver | Deployment (1) | ~75MB | pfSense logs |
| Kyverno Policy Reporter | Deployment (1) | ~50MB | Violation metrics |
| mitmproxy | Deployment (0/1) | 0 (200MB active) | On-demand only |
| CoreDNS logging | Config change | 0 | More Loki volume |
| Inspektor Gadget | Temporary DaemonSet | 0 (~400MB while running) | Removed after baseline |
| **Total steady-state** | | **~625MB** | Well under 5GB budget |

## Implementation Phases

### Phase 1: Core Observability (~625MB)
1. Deploy Tetragon with TracingPolicy CRDs
2. Enable CoreDNS query logging
3. Deploy Kyverno Policy Reporter
4. Add Prometheus alert rules for Tetragon events

### Phase 2: Log Centralization (+0MB permanent)
5. Deploy syslog receiver for pfSense logs
6. Configure pfSense remote syslog
7. Build unified Grafana security dashboard

### Phase 3: Network Segmentation (+0MB permanent, ~400MB temporary)
8. Deploy Inspektor Gadget temporarily
9. Capture 24-48h traffic baseline
10. Generate and review NetworkPolicies
11. Apply policies gradually (aux → edge → cluster → core)
12. Remove Inspektor Gadget

### Phase 4: On-Demand Inspection (+0MB permanent)
13. Deploy mitmproxy (scaled to 0)
14. Document investigation workflow

## New Terraform Stacks

- `stacks/tetragon/` — Helm chart + TracingPolicy CRDs + Prometheus rules
- `stacks/mitmproxy/` — On-demand HTTPS inspection proxy

## Modified Stacks

- `stacks/platform/modules/monitoring/` — Alloy syslog or syslog receiver, Grafana dashboard, alert rules
- `stacks/platform/modules/technitium/` — CoreDNS log uncomment
- `stacks/platform/modules/kyverno/` — Policy Reporter sub-chart

## Existing Stack (No Changes Needed)

- CrowdSec (IDS/IPS with Traefik bouncer) — already covers external attack detection
- Prometheus + Alertmanager — alert routing infrastructure ready
- Loki + Alloy — log pipeline ready, just needs new sources
- Caretta — eBPF service map complements Tetragon's process-level view
- GoFlow2 — NetFlow data complements Tetragon's connection tracking
- Calico — CNI with full NetworkPolicy enforcement ready
