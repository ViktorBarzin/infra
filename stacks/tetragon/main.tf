# Tetragon, watch-only (network IDS plan phase 4b,
# docs/plans/2026-11-10-network-ids.md; runbook docs/runbooks/network-ids.md).
#
# One agent per node records, through eBPF, which program in which pod started
# and which program opened a TCP connection to the internet. Nothing is enforced:
# no policy here, or anywhere else, may carry a Sigkill, Signal, Override or
# NotifyEnforcer action (plan decision 11).
#
# Path of an event: tetragon writes JSON to its export file, the chart's
# export-stdout sidecar prints it, the node's Alloy keeps those lines out of
# Loki and sends them over OTLP to the netsec Vector, which writes
# netsec.tetragon (30 days) on the claude-sessions ClickHouse.

locals {
  namespace = "tetragon"

  # Rollout stage. Empty means every node. Phase 4b started on k8s-node1 only,
  # measured there, then widened (runbook, "Tetragon").
  nodes = ["k8s-node1"]

  # Process starts in these namespaces are not exported: platform components
  # that exec constantly and run no third-party application code. "" is the
  # host itself (kubelet, containerd, systemd). Their outbound connects ARE
  # exported (the tcp_connect policy has no namespace filter).
  exec_quiet_namespaces = [
    "",
    "kube-system",
    "kube-public",
    "kube-node-lease",
    "calico-system",
    "tigera-operator",
    "metallb-system",
    "monitoring",
    "kyverno",
    "cnpg-system",
    "external-secrets",
    "sealed-secrets",
    "reloader",
    "descheduler",
    "kured",
    "nfs-csi",
    "proxmox-csi",
    "local-path-storage",
    "metrics-server",
    "nvidia",
    "trivy-system",
    "pvc-autoresizer",
    "netsec",
    "tetragon",
  ]

  # tcp_connect destinations that are NOT exported: ours and non-routable.
  quiet_destinations = [
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "100.64.0.0/10",
    "169.254.0.0/16",
    "::1/128",
    "fe80::/10",
    "fc00::/7",
    "2001:470:5a7f::/48",
    "2001:470:6f:43d::/64",
    "2001:470:6e:43d::/64",
  ]

  values = {
    # Annotation-based scrape (Prometheus kubernetes-pods job), metrics on 2112.
    podAnnotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "2112"
    }
    affinity = length(local.nodes) == 0 ? {} : {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [{
            matchExpressions = [{
              key      = "kubernetes.io/hostname"
              operator = "In"
              values   = local.nodes
            }]
          }]
        }
      }
    }
    tetragon = {
      resources = {
        requests = { cpu = "50m", memory = "384Mi" }
        limits   = { memory = "768Mi" }
      }
      exportAllowList = jsonencode({ event_set = ["PROCESS_EXEC", "PROCESS_KPROBE"] })
      exportDenyList = join("\n", [
        jsonencode({ health_check = true }),
        jsonencode({ event_set = ["PROCESS_EXEC"], namespace = local.exec_quiet_namespaces }),
      ])
      # Labels and annotations differ per pod and would each become a JSON path.
      fieldFilters = jsonencode({
        fields = "process.pod.pod_labels,process.pod.pod_annotations,parent.pod.pod_labels,parent.pod.pod_annotations"
        action = "EXCLUDE"
      })
      # Keep obvious secrets out of the arguments column.
      redactionFilters = jsonencode({
        redact = ["(?i)(?:--?(?:password|passwd|pass|token|secret|api-key|apikey))(?:\\s+|=)(\\S+)"]
      })
      exportFileMaxSizeMB  = 20
      exportFileMaxBackups = 3
    }
    export = {
      mode = "stdout"
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "64Mi" }
      }
    }
    tetragonOperator = {
      resources = {
        requests = { cpu = "10m", memory = "64Mi" }
        limits   = { memory = "128Mi" }
      }
    }
  }
}

resource "kubernetes_namespace" "tetragon" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.cluster
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "helm_release" "tetragon" {
  namespace = kubernetes_namespace.tetragon.metadata[0].name
  name      = "tetragon"

  repository = "https://helm.cilium.io"
  chart      = "tetragon"
  version    = "1.8.0"

  # A failed upgrade rolls back instead of leaving a release with no deployed revision.
  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values = [yamlencode(local.values)]
}

# Outbound TCP connects to the internet: tcp_connect sees the socket in the pod's
# own network namespace, so the destination is the real one (Calico NATs the
# source later). Observe only: no matchActions.
resource "kubectl_manifest" "connect_policy" {
  depends_on = [helm_release.tetragon]

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "netsec-external-connect"
    }
    spec = {
      kprobes = [{
        call    = "tcp_connect"
        syscall = false
        args = [{
          index = 0
          type  = "sock"
        }]
        selectors = [{
          matchArgs = [{
            index    = 0
            operator = "NotDAddr"
            values   = local.quiet_destinations
          }]
        }]
      }]
    }
  })
}
