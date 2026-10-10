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
#   - scan Jobs (at most 2 at a time) and one node-collector Job per node.
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
    # Report on every namespace except two whose pods live for minutes:
    # `verify` (verify-runner Jobs and probe pods) and `local-path-storage`
    # (a busybox helper pod per volume create/delete; the provisioner image
    # there goes unscanned with it). On 2026-10-10 these, with Woodpecker step
    # pods, made up most of the ~350 scan Jobs per hour; each scan of a pod
    # that is gone a minute later is wasted registry and etcd traffic. Other
    # bare pods (static control-plane pods) stay in scope.
    excludeNamespaces = "verify,local-path-storage"

    operator = {
      # At most 2 scan jobs at once (3 until 2026-10-10). Fewer concurrent
      # first-time pulls through the registry cache, less node memory, and a
      # lower peak of report writes into etcd, which shares an HDD.
      scanJobsConcurrentLimit = 2
      scanNodeCollectorLimit  = 1
      # The first scan of a large image downloads every layer; the 5m default
      # is too short for multi-GB images.
      scanJobTimeout = "10m"
      # A failed scan is retried after this delay (chart default 30s). One
      # image whose layer read kept failing was rescanned 59 times in 6 hours,
      # each attempt pulling the same multi-GB layer again.
      scanJobsRetryDelay = "15m"

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

      # Vulnerability and exposed-secret reports expire after 72h (24h until
      # 2026-10-10), which triggers a rescan against the latest DB. Unchanged
      # layers are cached on trivy-server, so a rescan only fetches the
      # manifest and config; the longer TTL cuts the job and report churn to a
      # third. A new CVE in an unchanged image shows up within 3 days.
      scannerReportTTL = "72h"

      # Scan jobs talk to the built-in trivy-server (ClientServer mode) instead
      # of each downloading the vulnerability DB into an emptyDir.
      #
      # Image mode stays (trivy.command = "image"). Node filesystem mode
      # (trivy.command = "rootfs": the scan pod runs the workload's own image
      # as root on the workload's node, imagePullPolicy Never) was evaluated on
      # 2026-10-10 against operator v0.35.0 and not adopted:
      #   - CronJobs return ErrUnSupportedKind (pkg/kube/object.go GetNodeName),
      #     so the ~130 CronJob images would lose vulnerability and secret
      #     coverage; Sablier-parked workloads would go unscanned while parked.
      #   - a rootfs scan re-reads every file of the image on each rescan
      #     (the secret scanner reads all of them), from node disks that live
      #     on the same HDD as etcd. Image mode with the server's layer cache
      #     reads nothing again for an unchanged image.
      #   - scan pods are pinned with nodeName onto nodes whose memory
      #     requests sit at 82-99%.
      # The trivy-server cache is what stops repeat pulls: keep the server pod
      # running. A trivy-server restart empties it, and the following rescans
      # pull every layer once more through the registry cache.
      builtInTrivyServer = true

      # Per-CVE series (trivy_vulnerability_id), needed to tell fixable from
      # unfixable. Prometheus keeps only the fixable Critical/High ones and
      # drops the long text labels (metric_relabel_configs in
      # prometheus_chart_values.tpl).
      metricsVulnIdEnabled = true
    }

    trivyOperator = {
      # Woodpecker step pods (label woodpecker-ci.org/step) and their
      # Services (woodpecker-ci.org/task-uuid) live for one pipeline step.
      # Skipping them by label keeps the woodpecker server and agent
      # StatefulSets scanned. 199 step pods got scan Jobs in 12h on 2026-10-10.
      skipResourceByLabels = "woodpecker-ci.org/step,woodpecker-ci.org/task-uuid"
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

      # Chart default minus ResourceQuota. A ResourceQuota report is keyed on
      # a hash of the whole object, status included, so every pod start or
      # stop in a namespace re-evaluated and rewrote its report: about 920 of
      # the ~1300 ConfigAuditReport writes per hour on 2026-10-10, 400 of them
      # for trivy-system's own quota, which each scan Job changes.
      supportedConfigAuditKinds = "Workload,Service,Role,ClusterRole,NetworkPolicy,Ingress,LimitRange,PersistentVolume,PersistentVolumeClaim"

      # trivy-server cache on emptyDir: the DB and layer cache rebuild on their
      # own after a restart, and a PVC would add a Proxmox LUN or pin the pod
      # to one node for data that needs no backup.
      storageClassEnabled = false
      # The server's layer cache is what keeps rescans from pulling layers
      # again, and it lives in an emptyDir. At the namespace's tier-4-aux
      # priority the scheduler preempted trivy-server-0 at 14:11 on
      # 2026-10-10, emptying the cache. tier-3-edge keeps it from being
      # displaced by ordinary workloads; scan jobs stay at tier-4-aux.
      priorityClassName = "tier-3-edge"
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
      # (registry VM 10.0.20.10, stacks/infra: 5000 Docker Hub, 5020 Quay,
      # 5030 registry.k8s.io, 5040 reg.kyverno.io) instead of the upstream
      # registries. Docker Hub rate-limits anonymous pulls, and the cache
      # pulls with an account. docker.n8n.io fronts Docker Hub's n8nio/n8n, so
      # it maps to the Docker Hub cache; the first scan hit Docker Hub's
      # anonymous pull limit there.
      # GHCR is not mirrored (removed 2026-10-10): GHCR images were about 20
      # GB of the 42 GB the first scan wrote into the cache VM's 61 GB disk,
      # which filled it. GHCR has no Docker Hub-style anonymous limit, so
      # scans read it directly and the cache holds only what nodes pull.
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
