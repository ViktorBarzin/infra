# Network Traffic Visualization Design

**Date**: 2026-02-28
**Goal**: Real-time visualization of all network traffic — pod-to-pod (K8s) and full network (up to 192.168.1.1) — using Grafana as the single pane of glass.

## Architecture

```
192.168.1.1 (ISP router)
  └── 10.0.20.1 (pfSense + softflowd) ──NetFlow UDP──► GoFlow2 (K8s)
        ├── Proxmox (192.168.1.127)                        │
        │     └── K8s nodes (10.0.20.100-104)              ▼
        │           └── Pods ◄──eBPF──► Caretta        Prometheus
        ├── TrueNAS (10.0.10.15)                           │
        └── Other devices                                  ▼
                                                       Grafana
                                                    (Node Graph panels)
```

Two complementary data paths:
1. **Caretta** (eBPF DaemonSet) → tracks pod-to-pod TCP connections → Prometheus metrics → Grafana Node Graph
2. **GoFlow2** (NetFlow collector) ← pfSense softflowd → Prometheus metrics → Grafana dashboards

## Component 1: Caretta

- **Stack**: `stacks/caretta/`
- **Namespace**: `caretta`
- **Deployment**: Helm release from `https://helm.groundcover.com/`, chart `caretta`
- **Config**:
  - Disable bundled Grafana (`grafana.enabled: false`)
  - Disable bundled VictoriaMetrics (`victoria-metrics-single.enabled: false`)
  - DaemonSet runs eBPF agent on each node
  - Exposes Prometheus metrics on port 7117
- **Key metric**: `caretta_links_observed{client_name, client_namespace, server_name, server_namespace, server_port}`
- **Grafana**: ConfigMap dashboard with Node Graph panel, label `grafana_dashboard: "1"`
- **Resources**: ~100Mi RAM, ~50m CPU per node

## Component 2: GoFlow2

- **Stack**: `stacks/goflow2/`
- **Namespace**: `goflow2`
- **Deployment**: Raw Terraform (Deployment + Service) — single binary, no Helm chart needed
- **Image**: `netsampler/goflow2`
- **Ports**:
  - UDP 2055: NetFlow v9 receiver (from pfSense)
  - TCP 8080: Prometheus metrics endpoint
- **Service**: NodePort for UDP 2055 so pfSense (10.0.20.1) can reach it on any node IP
- **Key metrics**: `flow_bytes`, `flow_packets` with labels for src/dst IP, port, protocol
- **Grafana**: ConfigMap dashboard showing network flows (top talkers, protocol breakdown, inter-VLAN traffic)
- **Resources**: ~100Mi RAM, ~50m CPU (single pod, not DaemonSet)

## Component 3: pfSense softflowd

- **Host**: 10.0.20.1 (SSH as admin)
- **Package**: `softflowd` (install via pfSense package manager)
- **Config**:
  - Monitor LAN interface(s)
  - Export NetFlow v9 to `<k8s-node-ip>:<goflow2-nodeport>` (UDP)
  - Tracking level: full (track individual connections)
- **Note**: This is a manual SSH step — pfSense is not Terraform-managed

## Component 4: Prometheus Integration

Two new scrape targets in `stacks/platform/modules/monitoring/prometheus_chart_values.tpl` (`extraScrapeConfigs`):

```yaml
- job_name: 'caretta'
  static_configs:
    - targets: ["caretta.caretta.svc.cluster.local:7117"]

- job_name: 'goflow2'
  static_configs:
    - targets: ["goflow2.goflow2.svc.cluster.local:8080"]
```

Requires re-applying the platform stack.

## Deployment Order

1. Apply `stacks/caretta/` — deploys eBPF DaemonSet
2. Apply `stacks/goflow2/` — deploys NetFlow collector
3. Re-apply `stacks/platform/` — adds Prometheus scrape targets
4. SSH to pfSense — install softflowd, configure NetFlow export to GoFlow2 NodePort
5. Verify in Grafana — confirm both dashboards show data

## Grafana Dashboards

Two dashboards, both auto-loaded via sidecar (ConfigMap label `grafana_dashboard: "1"`):

1. **K8s Pod Topology** (Caretta): Node Graph panel showing pods as nodes, TCP connections as edges, byte counts as edge weights
2. **Network Flows** (GoFlow2): Top talkers, protocol breakdown, inter-VLAN traffic, external destinations
