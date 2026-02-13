# Centralized Log Collection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy Loki + Alloy for centralized Kubernetes log collection with 24h in-memory chunks, 7-day disk retention, and log-based alerting via existing Alertmanager.

**Architecture:** Alloy DaemonSet tails pod logs on all 5 nodes, forwards to single-binary Loki which holds chunks in 6Gi RAM for 24h before flushing to NFS. Loki Ruler evaluates LogQL alert rules in real-time and fires to Alertmanager. Grafana gets a Loki datasource via sidecar auto-provisioning.

**Tech Stack:** Terraform, Helm (Loki chart, Alloy chart), Kubernetes DaemonSet, NFS, Grafana

**Design doc:** `docs/plans/2026-02-13-centralized-log-collection-design.md`

---

### Task 1: Add sysctl DaemonSet for inotify limits

Alloy uses fsnotify to tail log files. Default kernel limits cause "too many open files" errors. This DaemonSet sets the limits on every node persistently.

**Files:**
- Modify: `modules/kubernetes/monitoring/loki.tf` (replace the comment block at lines 67-71)

**Step 1: Write the sysctl DaemonSet resource**

Replace lines 67-71 (the comment block about sysctl) with this Terraform resource in `loki.tf`:

```hcl
resource "kubernetes_daemon_set_v1" "sysctl-inotify" {
  metadata {
    name      = "sysctl-inotify"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "sysctl-inotify"
    }
  }
  spec {
    selector {
      match_labels = {
        app = "sysctl-inotify"
      }
    }
    template {
      metadata {
        labels = {
          app = "sysctl-inotify"
        }
      }
      spec {
        init_container {
          name  = "sysctl"
          image = "busybox:1.37"
          command = [
            "sh", "-c",
            "sysctl -w fs.inotify.max_user_watches=1048576 && sysctl -w fs.inotify.max_user_instances=512 && sysctl -w fs.inotify.max_queued_events=1048576"
          ]
          security_context {
            privileged = true
          }
        }
        container {
          name  = "pause"
          image = "registry.k8s.io/pause:3.10"
          resources {
            requests = {
              cpu    = "1m"
              memory = "4Mi"
            }
            limits = {
              cpu    = "1m"
              memory = "4Mi"
            }
          }
        }
        host_pid = true
        toleration {
          operator = "Exists"
        }
      }
    }
  }
}
```

**Step 2: Run terraform fmt**

Run: `terraform fmt -recursive modules/kubernetes/monitoring/`

**Step 3: Run terraform plan to verify**

Run: `terraform plan -target=module.kubernetes_cluster.module.monitoring -var="kube_config_path=$(pwd)/config" 2>&1 | tail -30`
Expected: Plan shows 1 resource to add (kubernetes_daemon_set_v1.sysctl-inotify)

**Step 4: Commit**

```bash
git add modules/kubernetes/monitoring/loki.tf
git commit -m "[ci skip] Add sysctl DaemonSet for inotify limits"
```

---

### Task 2: Update Loki Helm values with disk-friendly tuning

Configure ingester for 24h in-memory chunks, WAL on tmpfs, 7-day retention, ruler for alerting, and resource limits.

**Files:**
- Modify: `modules/kubernetes/monitoring/loki.yaml` (full rewrite)

**Step 1: Write updated loki.yaml**

Replace entire contents of `loki.yaml` with:

```yaml
loki:
  commonConfig:
    replication_factor: 1
  schemaConfig:
    configs:
      - from: "2025-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  ingester:
    chunk_idle_period: 12h
    max_chunk_age: 24h
    chunk_retain_period: 1m
    chunk_target_size: 1572864
    wal:
      dir: /loki-wal
  pattern_ingester:
    enabled: true
  limits_config:
    allow_structured_metadata: true
    volume_enabled: true
    retention_period: 168h
  compactor:
    retention_enabled: true
    working_directory: /loki/compactor
    compaction_interval: 1h
    delete_request_store: filesystem
  ruler:
    enable_api: true
    storage:
      type: local
      local:
        directory: /loki/rules
    alertmanager_url: http://alertmanager.monitoring.svc.cluster.local:9093
    ring:
      kvstore:
        store: inmemory
    rule_path: /loki/scratch
  storage:
    type: "filesystem"
  auth_enabled: false

minio:
  enabled: false

deploymentMode: SingleBinary

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 15Gi
    storageClass: ""
  extraVolumes:
    - name: wal
      emptyDir:
        medium: Memory
        sizeLimit: 2Gi
    - name: rules
      configMap:
        name: loki-alert-rules
  extraVolumeMounts:
    - name: wal
      mountPath: /loki-wal
    - name: rules
      mountPath: /loki/rules/fake
  resources:
    requests:
      cpu: 250m
      memory: 4Gi
    limits:
      cpu: "1"
      memory: 6Gi

# Zero out replica counts of other deployment modes
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0
ingester:
  replicas: 0
querier:
  replicas: 0
queryFrontend:
  replicas: 0
queryScheduler:
  replicas: 0
distributor:
  replicas: 0
compactor:
  replicas: 0
indexGateway:
  replicas: 0
bloomCompactor:
  replicas: 0
bloomGateway:
  replicas: 0
```

**Step 2: Commit**

```bash
git add modules/kubernetes/monitoring/loki.yaml
git commit -m "[ci skip] Update Loki config with disk-friendly tuning and ruler"
```

---

### Task 3: Update Alloy Helm values with resource limits

The Alloy config content is already complete. Wrap it in proper Helm values with resource limits.

**Files:**
- Modify: `modules/kubernetes/monitoring/alloy.yaml` (add resource limits)

**Step 1: Add resource limits to alloy.yaml**

Append after the existing `alloy.configMap.content` block (after the last line):

```yaml

  # Resource limits for DaemonSet pods
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi
```

The final file should have the `alloy.configMap.content` block unchanged, with `alloy.resources` added as a sibling under `alloy:`.

**Step 2: Commit**

```bash
git add modules/kubernetes/monitoring/alloy.yaml
git commit -m "[ci skip] Add resource limits to Alloy config"
```

---

### Task 4: Uncomment Loki Helm release and PV in loki.tf

Enable the Loki Helm release and its NFS persistent volume. Remove minio PV (not needed with filesystem storage).

**Files:**
- Modify: `modules/kubernetes/monitoring/loki.tf` (uncomment Loki resources, remove minio PV)

**Step 1: Uncomment the Loki Helm release (lines 1-12)**

Uncomment and update the helm_release to:

```hcl
resource "helm_release" "loki" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "loki"

  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"

  values  = [templatefile("${path.module}/loki.yaml", {})]
  timeout = 300

  depends_on = [kubernetes_config_map.loki_alert_rules]
}
```

**Step 2: Uncomment the Loki NFS PV (lines 14-32)**

Uncomment the `kubernetes_persistent_volume.loki` resource as-is.

**Step 3: Remove the minio PV block (lines 34-52)**

Delete the entire `kubernetes_persistent_volume.loki-minio` commented block — minio is disabled.

**Step 4: Run terraform fmt**

Run: `terraform fmt -recursive modules/kubernetes/monitoring/`

**Step 5: Commit**

```bash
git add modules/kubernetes/monitoring/loki.tf
git commit -m "[ci skip] Enable Loki Helm release and NFS PV"
```

---

### Task 5: Uncomment Alloy Helm release in loki.tf

Enable the Alloy Helm release.

**Files:**
- Modify: `modules/kubernetes/monitoring/loki.tf` (uncomment Alloy helm release)

**Step 1: Uncomment and update the Alloy Helm release**

Replace the commented Alloy block with:

```hcl
resource "helm_release" "alloy" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "alloy"

  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"

  values = [file("${path.module}/alloy.yaml")]
  atomic = true

  depends_on = [helm_release.loki]
}
```

**Step 2: Run terraform fmt**

Run: `terraform fmt -recursive modules/kubernetes/monitoring/`

**Step 3: Commit**

```bash
git add modules/kubernetes/monitoring/loki.tf
git commit -m "[ci skip] Enable Alloy Helm release"
```

---

### Task 6: Add Grafana Loki datasource ConfigMap

Grafana's sidecar auto-discovers ConfigMaps with label `grafana_datasource: "1"`. Create one for Loki.

**Files:**
- Modify: `modules/kubernetes/monitoring/loki.tf` (add ConfigMap resource)

**Step 1: Add the datasource ConfigMap**

Add to `loki.tf`:

```hcl
resource "kubernetes_config_map" "grafana_loki_datasource" {
  metadata {
    name      = "grafana-loki-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "loki-datasource.yaml" = yamlencode({
      apiVersion  = 1
      datasources = [{
        name      = "Loki"
        type      = "loki"
        access    = "proxy"
        url       = "http://loki.monitoring.svc.cluster.local:3100"
        isDefault = false
      }]
    })
  }
}
```

**Step 2: Run terraform fmt**

Run: `terraform fmt -recursive modules/kubernetes/monitoring/`

**Step 3: Commit**

```bash
git add modules/kubernetes/monitoring/loki.tf
git commit -m "[ci skip] Add Grafana Loki datasource ConfigMap"
```

---

### Task 7: Add Loki alert rules ConfigMap

Create the ConfigMap that Loki's ruler reads for alert rules. Mounted into the Loki pod at `/loki/rules/fake/`.

**Files:**
- Modify: `modules/kubernetes/monitoring/loki.tf` (add alert rules ConfigMap)

**Step 1: Add the alert rules ConfigMap**

Add to `loki.tf`:

```hcl
resource "kubernetes_config_map" "loki_alert_rules" {
  metadata {
    name      = "loki-alert-rules"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "rules.yaml" = yamlencode({
      groups = [{
        name = "log-alerts"
        rules = [
          {
            alert = "HighErrorRate"
            expr  = "sum(rate({namespace=~\".+\"} |= \"error\" [5m])) by (namespace) > 10"
            for   = "5m"
            labels = {
              severity = "warning"
            }
            annotations = {
              summary = "High error rate in {{ $labels.namespace }}"
            }
          },
          {
            alert = "PodCrashLoopBackOff"
            expr  = "count_over_time({namespace=~\".+\"} |= \"CrashLoopBackOff\" [5m]) > 0"
            for   = "1m"
            labels = {
              severity = "critical"
            }
            annotations = {
              summary = "CrashLoopBackOff detected in {{ $labels.namespace }}"
            }
          },
          {
            alert = "OOMKilled"
            expr  = "count_over_time({namespace=~\".+\"} |= \"OOMKilled\" [5m]) > 0"
            for   = "1m"
            labels = {
              severity = "critical"
            }
            annotations = {
              summary = "OOMKilled detected in {{ $labels.namespace }}"
            }
          }
        ]
      }]
    })
  }
}
```

**Step 2: Run terraform fmt**

Run: `terraform fmt -recursive modules/kubernetes/monitoring/`

**Step 3: Commit**

```bash
git add modules/kubernetes/monitoring/loki.tf
git commit -m "[ci skip] Add Loki alert rules ConfigMap"
```

---

### Task 8: Deploy and verify

Apply all changes via Terraform and verify the stack is working.

**Files:** None (deployment only)

**Step 1: Run terraform apply for monitoring module**

Run: `terraform apply -target=module.kubernetes_cluster.module.monitoring -var="kube_config_path=$(pwd)/config" -auto-approve`
Expected: Multiple resources created (sysctl DaemonSet, Loki Helm release, Alloy Helm release, PV, ConfigMaps)

**Step 2: Verify sysctl DaemonSet is running on all nodes**

Run: `kubectl --kubeconfig $(pwd)/config get ds -n monitoring sysctl-inotify`
Expected: DESIRED=5, CURRENT=5, READY=5

**Step 3: Verify Loki pod is running**

Run: `kubectl --kubeconfig $(pwd)/config get pods -n monitoring -l app.kubernetes.io/name=loki`
Expected: 1/1 Running

**Step 4: Verify Alloy DaemonSet is running**

Run: `kubectl --kubeconfig $(pwd)/config get ds -n monitoring -l app.kubernetes.io/name=alloy`
Expected: DESIRED=5, CURRENT=5, READY=5

**Step 5: Verify Loki is receiving logs**

Run: `kubectl --kubeconfig $(pwd)/config exec -n monitoring deploy/loki -- wget -qO- 'http://localhost:3100/loki/api/v1/labels'`
Expected: JSON response with labels like `namespace`, `pod`, `container`

**Step 6: Verify Grafana has Loki datasource**

Open `https://grafana.viktorbarzin.me/explore`, select "Loki" datasource, run query: `{namespace="monitoring"}`
Expected: Log lines from monitoring namespace pods

**Step 7: Commit final state**

```bash
git add -A
git commit -m "[ci skip] Deploy centralized log collection (Loki + Alloy)"
```

---

### Troubleshooting

**If Alloy pods crash with inotify errors:**
- Check sysctl DaemonSet init logs: `kubectl --kubeconfig $(pwd)/config logs -n monitoring ds/sysctl-inotify -c sysctl`
- Verify sysctl values on node: `kubectl --kubeconfig $(pwd)/config debug node/k8s-node2 -it --image=busybox -- sysctl fs.inotify.max_user_watches`

**If Loki OOMs:**
- Check memory usage: `kubectl --kubeconfig $(pwd)/config top pod -n monitoring -l app.kubernetes.io/name=loki`
- Reduce `max_chunk_age` from 24h to 12h in `loki.yaml` to flush more frequently

**If Grafana doesn't show Loki datasource:**
- Verify ConfigMap has correct label: `kubectl --kubeconfig $(pwd)/config get cm -n monitoring grafana-loki-datasource -o yaml`
- Restart Grafana sidecar: `kubectl --kubeconfig $(pwd)/config rollout restart deploy -n monitoring grafana`

**If Loki PV won't bind:**
- Check NFS export exists: `ssh root@10.0.10.15 'showmount -e localhost | grep loki'`
- Run NFS export script: `cd secrets && bash nfs_exports.sh`
