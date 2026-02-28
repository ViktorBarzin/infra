# Network Traffic Visualization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy Caretta (pod-to-pod eBPF topology) and GoFlow2 + pfSense softflowd (full network NetFlow) with Grafana dashboards for real-time network visualization.

**Architecture:** Two data paths feed into existing Prometheus+Grafana: (1) Caretta eBPF DaemonSet tracks pod TCP connections, (2) pfSense exports NetFlow to GoFlow2 collector pod. Both expose Prometheus metrics scraped by existing Prometheus, visualized in Grafana Node Graph panels.

**Tech Stack:** Terraform/Terragrunt, Helm (Caretta), raw K8s resources (GoFlow2), pfSense SSH (softflowd), Prometheus, Grafana

**Design doc:** `docs/plans/2026-02-28-network-visualization-design.md`

---

### Task 1: Create Caretta Terraform stack

**Files:**
- Create: `stacks/caretta/terragrunt.hcl`
- Create: `stacks/caretta/main.tf`

**Step 1: Create the terragrunt.hcl**

```hcl
# stacks/caretta/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}
```

**Step 2: Create main.tf with Helm release**

```hcl
variable "tls_secret_name" { type = string }

resource "kubernetes_namespace" "caretta" {
  metadata {
    name = "caretta"
    labels = {
      tier = local.tiers.cluster
    }
  }
}

resource "helm_release" "caretta" {
  namespace  = kubernetes_namespace.caretta.metadata[0].name
  name       = "caretta"
  repository = "https://helm.groundcover.com/"
  chart      = "caretta"
  version    = "0.0.16"

  set {
    name  = "victoria-metrics-single.enabled"
    value = "false"
  }
  set {
    name  = "grafana.enabled"
    value = "false"
  }
}
```

**Step 3: Create secrets symlink**

Run: `cd stacks/caretta && ln -s ../../secrets secrets`

**Step 4: Apply**

Run: `cd stacks/caretta && terragrunt apply --non-interactive`

**Step 5: Verify DaemonSet is running**

Run: `kubectl --kubeconfig $(pwd)/config get daemonset -n caretta`
Expected: Caretta DaemonSet with 5 pods (one per node)

**Step 6: Commit**

```bash
git add stacks/caretta/
git commit -m "[ci skip] deploy caretta eBPF pod topology visualization"
```

---

### Task 2: Add Caretta Grafana dashboard

**Files:**
- Modify: `stacks/caretta/main.tf`

**Step 1: Download dashboard JSON**

Run: `curl -sL https://raw.githubusercontent.com/groundcover-com/caretta/master/chart/dashboard.json > stacks/caretta/dashboard.json`

**Step 2: Add ConfigMap to main.tf**

Append to `stacks/caretta/main.tf`:

```hcl
resource "kubernetes_config_map" "caretta_dashboard" {
  metadata {
    name      = "caretta-grafana-dashboard"
    namespace = kubernetes_namespace.caretta.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }
  data = {
    "caretta-dashboard.json" = file("${path.module}/dashboard.json")
  }
}
```

**Step 3: Apply**

Run: `cd stacks/caretta && terragrunt apply --non-interactive`

**Step 4: Verify dashboard appears in Grafana**

Open `https://grafana.viktorbarzin.me` → Dashboards → search "Caretta"
Expected: Dashboard visible with Node Graph panel (may be empty until Prometheus scrape is configured)

**Step 5: Commit**

```bash
git add stacks/caretta/
git commit -m "[ci skip] add caretta grafana dashboard via sidecar configmap"
```

---

### Task 3: Create GoFlow2 Terraform stack

**Files:**
- Create: `stacks/goflow2/terragrunt.hcl`
- Create: `stacks/goflow2/main.tf`

**Step 1: Create the terragrunt.hcl**

```hcl
# stacks/goflow2/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}
```

**Step 2: Create main.tf with Deployment + Services**

```hcl
variable "tls_secret_name" { type = string }

resource "kubernetes_namespace" "goflow2" {
  metadata {
    name = "goflow2"
    labels = {
      tier = local.tiers.cluster
    }
  }
}

resource "kubernetes_deployment" "goflow2" {
  metadata {
    name      = "goflow2"
    namespace = kubernetes_namespace.goflow2.metadata[0].name
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "goflow2"
      }
    }
    template {
      metadata {
        labels = {
          app = "goflow2"
        }
      }
      spec {
        container {
          name  = "goflow2"
          image = "netsampler/goflow2:v2.2.1"
          args  = ["-listen", "netflow://:2055", "-transport", "stdout", "-format", "json"]

          port {
            name           = "netflow"
            container_port = 2055
            protocol       = "UDP"
          }
          port {
            name           = "metrics"
            container_port = 8080
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "goflow2_metrics" {
  metadata {
    name      = "goflow2"
    namespace = kubernetes_namespace.goflow2.metadata[0].name
  }
  spec {
    selector = {
      app = "goflow2"
    }
    port {
      name        = "metrics"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_service" "goflow2_netflow" {
  metadata {
    name      = "goflow2-netflow"
    namespace = kubernetes_namespace.goflow2.metadata[0].name
  }
  spec {
    type = "NodePort"
    selector = {
      app = "goflow2"
    }
    port {
      name        = "netflow"
      port        = 2055
      target_port = 2055
      protocol    = "UDP"
      node_port   = 32055
    }
  }
}
```

**Step 3: Create secrets symlink**

Run: `cd stacks/goflow2 && ln -s ../../secrets secrets`

**Step 4: Apply**

Run: `cd stacks/goflow2 && terragrunt apply --non-interactive`

**Step 5: Verify pod is running**

Run: `kubectl --kubeconfig $(pwd)/config get pods -n goflow2`
Expected: 1 goflow2 pod running

**Step 6: Verify NodePort is accessible**

Run: `kubectl --kubeconfig $(pwd)/config get svc -n goflow2 goflow2-netflow`
Expected: NodePort 32055/UDP

**Step 7: Commit**

```bash
git add stacks/goflow2/
git commit -m "[ci skip] deploy goflow2 netflow collector for network visualization"
```

---

### Task 4: Add Prometheus scrape targets for Caretta and GoFlow2

**Files:**
- Modify: `stacks/platform/modules/monitoring/prometheus_chart_values.tpl` (append to extraScrapeConfigs)

**Step 1: Append scrape jobs**

Add at the end of `extraScrapeConfigs` (before the final blank line at line 882):

```yaml
  - job_name: 'caretta'
    static_configs:
        - targets:
          - "caretta-caretta.caretta.svc.cluster.local:7117"
    metrics_path: '/metrics'
  - job_name: 'goflow2'
    static_configs:
        - targets:
          - "goflow2.goflow2.svc.cluster.local:8080"
    metrics_path: '/metrics'
```

**Step 2: Apply platform stack**

Run: `cd stacks/platform && terragrunt apply --non-interactive`

**Step 3: Verify Prometheus targets**

Open `https://grafana.viktorbarzin.me` → Explore → Prometheus → query `up{job="caretta"}` and `up{job="goflow2"}`
Expected: Both return `1`

**Step 4: Verify Caretta metrics flowing**

Query: `caretta_links_observed`
Expected: Multiple time series with client_name/server_name labels showing pod connections

**Step 5: Commit**

```bash
git add stacks/platform/modules/monitoring/prometheus_chart_values.tpl
git commit -m "[ci skip] add caretta and goflow2 prometheus scrape targets"
```

---

### Task 5: Install and configure softflowd on pfSense

**Files:** None (SSH to pfSense)

**Step 1: SSH to pfSense and install softflowd**

Run: `ssh admin@10.0.20.1 "pkg install -y softflowd"`

If `softflowd` is available via pfSense package manager instead:
Run: `ssh admin@10.0.20.1 "pfSsh.php playback installpkg softflowd"`

**Step 2: Determine LAN interface name**

Run: `ssh admin@10.0.20.1 "ifconfig -l"`
Expected: Identify the LAN interface (likely `vtnet1` or `igb1`)

**Step 3: Configure softflowd**

Pick any K8s node IP (e.g., 10.0.20.100) with NodePort 32055:

Run:
```bash
ssh admin@10.0.20.1 "softflowd -i <LAN_INTERFACE> -n 10.0.20.100:32055 -v 9 -t maxlife=300"
```

Flags:
- `-i <interface>`: Monitor this interface
- `-n 10.0.20.100:32055`: Send NetFlow v9 to GoFlow2 NodePort
- `-v 9`: NetFlow version 9
- `-t maxlife=300`: Max flow lifetime 5 minutes

**Step 4: Verify flows are arriving at GoFlow2**

Run: `kubectl --kubeconfig $(pwd)/config logs -n goflow2 -l app=goflow2 --tail=20`
Expected: JSON flow records appearing in stdout

**Step 5: Make softflowd persistent**

Ensure softflowd starts on boot. On pfSense/FreeBSD:
Run: `ssh admin@10.0.20.1 'echo "softflowd_enable=\"YES\"" >> /etc/rc.conf && echo "softflowd_flags=\"-i <LAN_INTERFACE> -n 10.0.20.100:32055 -v 9\"" >> /etc/rc.conf'`

---

### Task 6: Add GoFlow2 Grafana dashboard

**Files:**
- Create: `stacks/goflow2/dashboard.json`
- Modify: `stacks/goflow2/main.tf`

**Step 1: Create a GoFlow2 dashboard JSON**

Create `stacks/goflow2/dashboard.json` — a Grafana dashboard with panels for:
- Top talkers by bytes (bar chart, query: `topk(10, sum by (src_addr, dst_addr) (rate(flow_bytes[5m])))`)
- Protocol breakdown (pie chart, query: `sum by (proto) (rate(flow_bytes[5m]))`)
- Flows over time (time series, query: `sum(rate(flow_packets[5m]))`)

Note: Exact metric names will depend on GoFlow2's Prometheus output — verify after Task 5 by querying `{job="goflow2"}` in Prometheus. Adjust dashboard queries to match actual metric names.

**Step 2: Add ConfigMap to main.tf**

Append to `stacks/goflow2/main.tf`:

```hcl
resource "kubernetes_config_map" "goflow2_dashboard" {
  metadata {
    name      = "goflow2-grafana-dashboard"
    namespace = kubernetes_namespace.goflow2.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }
  data = {
    "goflow2-dashboard.json" = file("${path.module}/dashboard.json")
  }
}
```

**Step 3: Apply**

Run: `cd stacks/goflow2 && terragrunt apply --non-interactive`

**Step 4: Verify in Grafana**

Open `https://grafana.viktorbarzin.me` → Dashboards → search "GoFlow2"
Expected: Dashboard with network flow data from pfSense

**Step 5: Commit**

```bash
git add stacks/goflow2/
git commit -m "[ci skip] add goflow2 grafana dashboard for network flow visualization"
```

---

### Task 7: End-to-end verification

**Step 1: Verify Caretta topology**

Open Grafana → Caretta Dashboard → Service Map panel
Expected: Node graph showing pods connected by edges with byte counts

**Step 2: Verify GoFlow2 flows**

Open Grafana → GoFlow2 Dashboard
Expected: Network flow data showing traffic between pfSense segments

**Step 3: Generate test traffic and confirm it appears**

Run: `kubectl --kubeconfig $(pwd)/config exec -n default deploy/some-pod -- curl -s https://example.com > /dev/null`
Expected: New edge appears in Caretta for the pod, new flow in GoFlow2 for the external connection

**Step 4: Push all changes**

Run: `git push origin master`
