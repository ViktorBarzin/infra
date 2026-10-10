# Trivy Operator: continuous vulnerability, secret, config and node scanning.
#
# Phase 2 of the software-currency design
# (docs/plans/2026-10-09-software-currency-design.md). Architecture, sizing
# and the alert/digest wiring: docs/architecture/trivy.md.
#
# What runs here:
#   - trivy-operator Deployment: watches workloads and writes report CRDs
#     (VulnerabilityReport, ExposedSecretReport, ConfigAuditReport,
#     RbacAssessmentReport, InfraAssessmentReport, ClusterComplianceReport).
#     It also serves trivy_* metrics on :8080, scraped by the
#     kubernetes-service-endpoints job (stacks/monitoring).
#   - trivy-server StatefulSet: holds the vulnerability DB and the per-layer
#     analysis cache, so scan jobs neither download the DB nor re-analyse
#     a layer the server has already seen.
#   - scan Jobs (at most 3 at a time) and one node-collector Job per node.
#
# Prerequisites in stacks/kyverno (security-policies.tf):
#   - mirror.gcr.io/aquasec/* on the require-trusted-registries list
#   - PolicyException trivy-node-collector-hostpid (hostPID for the
#     node-collector only)

resource "kubernetes_namespace" "trivy_system" {
  metadata {
    name = "trivy-system"
    labels = {
      # Aux tier: tier-4-aux priority (scan jobs are the first thing evicted
      # under memory pressure) and the aux ResourceQuota (2 CPU / 3Gi
      # requests, 20 pods), which fits the operator, server and 3 scan jobs.
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "helm_release" "trivy_operator" {
  namespace        = kubernetes_namespace.trivy_system.metadata[0].name
  create_namespace = false
  name             = "trivy-operator"
  repository       = "https://aquasecurity.github.io/helm-charts/"
  chart            = "trivy-operator"
  # Latest on 2026-10-10 (app v0.35.0, Trivy 0.75.0). Renovate owns this pin.
  # Helm installs the chart's CRDs on first install only, so a chart bump that
  # changes a report CRD needs the CRDs applied separately (see trivy.md).
  version = "0.37.0"

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values = [yamlencode({
    # Report on every namespace. Bare pods (Woodpecker step pods, static
    # control-plane pods) stay in scope so etcd and kube-apiserver images are
    # scanned too.
    excludeNamespaces = ""

    operator = {
      # Design: at most 3 scan jobs at once, so the first full pass over about
      # 240 images does not push node1 (62% memory) or node5 (65%) over.
      scanJobsConcurrentLimit = 3
      scanNodeCollectorLimit  = 1
      # The first scan of a large image downloads every layer; the 5m default
      # is too short for multi-GB images.
      scanJobTimeout = "10m"

      # All four scan types from the design: image vulnerabilities, secrets in
      # images, config audit including RBAC, and node/cluster components.
      vulnerabilityScannerEnabled   = true
      exposedSecretScannerEnabled   = true
      configAuditScannerEnabled     = true
      rbacAssessmentScannerEnabled  = true
      infraAssessmentScannerEnabled = true
      clusterComplianceEnabled      = true

      # SBOM reports are the largest report type and nothing here reads them.
      # Off to keep etcd lean (etcd was 264 MB on 2026-10-10 and has had
      # latency trouble from report volume before; see stacks/kyverno).
      sbomGenerationEnabled = false

      # Reports expire after 24h, which triggers a rescan against the latest
      # DB. Unchanged layers are cached on trivy-server, so a rescan only
      # fetches manifests.
      scannerReportTTL = "24h"

      # Scan jobs talk to the built-in trivy-server (ClientServer mode) instead
      # of each downloading the vulnerability DB into an emptyDir.
      builtInTrivyServer = true

      # Per-CVE series (trivy_vulnerability_id), needed to tell fixable from
      # unfixable. Prometheus keeps only the fixable Critical/High ones and
      # drops the long text labels (metric_relabel_configs in
      # prometheus_chart_values.tpl).
      metricsVulnIdEnabled = true
    }

    service = {
      annotations = {
        "prometheus.io/scrape" = "true"
      }
    }

    trivy = {
      # Critical and High only. The alerts act on these two, and the weekly
      # digest counts them. Medium/Low/Unknown roughly triple the size of each
      # VulnerabilityReport in etcd for findings nobody acts on. Widening this
      # is a one-line change followed by a rescan.
      severity      = "CRITICAL,HIGH"
      ignoreUnfixed = false
      timeout       = "10m0s"

      # trivy-server cache on emptyDir: the DB and layer cache rebuild on their
      # own after a restart, and a PVC would add a Proxmox LUN or pin the pod
      # to one node for data that needs no backup.
      storageClassEnabled = false
      server = {
        resources = {
          requests = { cpu = "100m", memory = "512Mi" }
          limits   = { memory = "2Gi" }
        }
      }

      # Scan job containers. Analysis of large images can exceed the 500M
      # chart default.
      resources = {
        requests = { cpu = "100m", memory = "128M" }
        limits   = { memory = "1Gi" }
      }

      # Pull image manifests and layers through the LAN pull-through caches
      # (registry VM 10.0.20.10, stacks/infra: 5000 Docker Hub, 5010 GHCR,
      # 5020 Quay, 5030 registry.k8s.io, 5040 reg.kyverno.io) instead of the
      # upstream registries, which rate-limit and would otherwise be hit once
      # per image per day. docker.n8n.io fronts Docker Hub's n8nio/n8n, so it
      # maps to the Docker Hub cache; the first scan hit Docker Hub's
      # anonymous pull limit there.
      # Trivy tries each mirror first and falls back to the original registry
      # on any error, and reports keep the original image name. The cache
      # speaks plain HTTP; go-containerregistry uses http for RFC 1918 hosts.
      # (The chart's trivy.registry.mirror option is not used: it rewrites the
      # image name outright, with no fallback, and breaks the mapping of
      # registry credentials for private ghcr.io images.)
      configFile = {
        registry = {
          mirrors = {
            "index.docker.io" = ["10.0.20.10:5000"]
            "ghcr.io"         = ["10.0.20.10:5010"]
            "quay.io"         = ["10.0.20.10:5020"]
            "registry.k8s.io" = ["10.0.20.10:5030"]
            "reg.kyverno.io"  = ["10.0.20.10:5040"]
            "docker.n8n.io"   = ["10.0.20.10:5000"]
          }
        }
      }
    }

    nodeCollector = {
      # One node-collector per node, including the control plane and the
      # GPU node, so every node gets an infra assessment.
      tolerations = [
        { key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule" },
        { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
      ]
    }

    # The operator caches every report and watched workload in memory.
    resources = {
      requests = { cpu = "50m", memory = "256Mi" }
      limits   = { memory = "1Gi" }
    }
  })]
}
