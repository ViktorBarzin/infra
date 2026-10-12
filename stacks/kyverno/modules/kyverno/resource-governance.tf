
# =============================================================================
# Tier-Based Resource Governance
# =============================================================================
# default (limit) = defaultRequest (request) to give Guaranteed QoS and prevent
# memory overcommit. Changed 2026-03-14 after node2 OOM crash caused by 250%
# memory overcommit (61GB limits on 24GB node).
#
# Four layers of protection against noisy neighbor issues:
# 1. PriorityClasses - critical services survive resource pressure
# 2. LimitRange defaults (Kyverno generate) - auto-inject defaults for containers without resources
# 3. ResourceQuotas (Kyverno generate) - hard ceiling on namespace resource consumption
# 4. Priority injection (Kyverno mutate) - set priorityClassName based on namespace tier label

locals {
  governance_tiers    = ["0-core", "1-cluster", "2-gpu", "3-edge", "4-aux"]
  excluded_namespaces = ["kube-system", "metallb-system", "kyverno", "calico-system", "calico-apiserver"]

  # GPU-priority injection exclude list. Adds `tts` to the base set so the
  # `inject-gpu-workload-priority` policy does NOT stamp the immich-equal
  # gpu-workload (1,200,000) priority on Chatterbox-TTS pods. Chatterbox is a
  # best-effort off-peak batch tenant on the shared T4: it must keep its
  # tier-2-gpu (600,000) priority so it is ALWAYS the pod evicted under GPU-node
  # pressure, never immich-ml/frigate/llama-swap. See the tts stack
  # (stacks/tts/) + docs/plans/2026-06-08-chatterbox-tts-infra.md §3.
  gpu_priority_excluded_namespaces = concat(local.excluded_namespaces, ["tts"])

  # gpumem-declaration exclude list (Layer 6, below). Four namespaces on top of
  # the base set, each holding a GPU tenant that is seatless ON PURPOSE, so
  # Enforce must not reject its pods:
  #
  #   nvidia    — the GPU operator's own namespace. gpu-pod-exporter is a
  #               DaemonSet that requests a time-slice to read NVML and holds no
  #               VRAM (26 weeks of gpu_pod_memory_used_bytes carry no series for
  #               this namespace). A DaemonSet pod rejected at admission is the
  #               worst failure mode this policy has, and the operator owns and
  #               recreates 11 other DaemonSets here, so the whole namespace is
  #               out.
  #   llama-cpp — llama-swap is the opportunistic tenant by design (ADR-0016):
  #               it fills whatever slack the seated tenants leave, ~7 GiB when
  #               qwen3-8b is loaded, idle almost always. A seat would either
  #               strand that memory or make it Pending.
  #   stremio   — NVENC transcode server, measured zero VRAM.
  #   ytdlp     — yt-highlights, Sablier-parked at 0 replicas, measured zero VRAM.
  #   verify    — the GPU verify probe (stacks/nvidia/verify.sh): one pod runs
  #               nvidia-smi and the CUDA vectorAdd sample for a few seconds,
  #               then exits. A seat would make it Pending whenever the card is
  #               fully seated (52 MiB of 14200 unallocated on 2026-10-10), and
  #               the check exists to prove a slot still works after an
  #               upgrade. Added 2026-10-10 (software-currency verify Jobs).
  #
  # These are the three the bead names as deliberate, plus the exporter and the
  # verify probe. Adding a GPU workload to one of these namespaces escapes the
  # check, same caveat as the base excluded set.
  gpumem_excluded_namespaces = concat(local.excluded_namespaces, ["nvidia", "llama-cpp", "stremio", "ytdlp", "verify"])
}

# -----------------------------------------------------------------------------
# Layer 1: PriorityClasses
# -----------------------------------------------------------------------------
# Values stay well below system-cluster-critical (2,000,000,000)

resource "kubernetes_priority_class" "tier_0_core" {
  metadata {
    name = "tier-0-core"
  }
  value             = 1000000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "Critical infrastructure: ingress, DNS, VPN, auth, monitoring"
}

resource "kubernetes_priority_class" "tier_1_cluster" {
  metadata {
    name = "tier-1-cluster"
  }
  value             = 800000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "Cluster services: Redis, metrics, security"
}

resource "kubernetes_priority_class" "tier_2_gpu" {
  metadata {
    name = "tier-2-gpu"
  }
  value             = 600000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "GPU workloads: Immich, Ollama, Frigate"
}

resource "kubernetes_priority_class" "gpu_workload" {
  metadata {
    name = "gpu-workload"
  }
  value             = 1200000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "GPU-pinned workloads. Higher than all user tiers. Auto-injected by Kyverno on pods requesting nvidia.com/gpu."
}

resource "kubernetes_priority_class" "tier_3_edge" {
  metadata {
    name = "tier-3-edge"
  }
  value             = 400000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "User-facing services: mail, file sync, dashboards"
}

resource "kubernetes_priority_class" "tier_4_aux" {
  metadata {
    name = "tier-4-aux"
  }
  value             = 200000
  global_default    = false
  preemption_policy = "Never"
  description       = "Optional services: blogs, tools, experiments. Will not preempt other aux services."
}

# -----------------------------------------------------------------------------
# Layer 2: LimitRange Defaults (Kyverno Generate)
# -----------------------------------------------------------------------------
# Creates a LimitRange in each namespace based on its tier label.
# Only affects containers WITHOUT explicit resource requests/limits.

locals {
  # One GeneratingPolicy per entry. The fallback covers namespaces without a
  # tier label, except the governance-excluded set; as with the ClusterPolicy
  # rule, it does not look at resource-governance/custom-limitrange.
  # 3-edge and 4-aux are Burstable (request < limit) to reduce scheduler
  # pressure; the rest keep request = limit (2026-03-14 node2 OOM incident).
  limitrange_policies = {
    "0-core"    = { default_memory = "256Mi", request_cpu = "100m", request_memory = "256Mi", max_memory = "8Gi" }
    "1-cluster" = { default_memory = "256Mi", request_cpu = "100m", request_memory = "256Mi", max_memory = "8Gi" }
    "2-gpu"     = { default_memory = "1Gi", request_cpu = "200m", request_memory = "1Gi", max_memory = "16Gi" }
    "3-edge"    = { default_memory = "256Mi", request_cpu = "50m", request_memory = "128Mi", max_memory = "8Gi" }
    "4-aux"     = { default_memory = "256Mi", request_cpu = "50m", request_memory = "64Mi", max_memory = "4Gi" }
    "no-tier"   = { default_memory = "192Mi", request_cpu = "50m", request_memory = "128Mi", max_memory = "4Gi" }
  }
}

# Replaces the generate-limitrange-by-tier ClusterPolicy (one rule per tier).
resource "kubectl_manifest" "generate_limitrange" {
  for_each = local.limitrange_policies
  yaml_body = templatefile("${path.module}/policies/generate-from-data.yaml", {
    name        = "generate-limitrange-${each.key}"
    title       = "Generate LimitRange for ${each.key == "no-tier" ? "namespaces without a tier" : "tier ${each.key}"}"
    kind        = "LimitRange"
    object_name = "tier-defaults"
    selector = each.key == "no-tier" ? jsonencode([
      { key = "tier", operator = "DoesNotExist" },
      ]) : jsonencode([
      { key = "tier", operator = "In", values = [each.key] },
      { key = "resource-governance/custom-limitrange", operator = "NotIn", values = ["true"] },
    ])
    condition = each.key == "no-tier" ? "!(object.metadata.name in ${jsonencode(local.excluded_namespaces)})" : "true"
    spec = jsonencode({
      limits = [{
        type           = "Container"
        default        = { memory = each.value.default_memory }
        defaultRequest = { cpu = each.value.request_cpu, memory = each.value.request_memory }
        max            = { memory = each.value.max_memory }
      }]
    })
  })
  depends_on = [helm_release.kyverno]
}

# The kyverno.io ClusterPolicy is deleted by this removal. Its rules carry
# orphanDownstreamOnPolicyDelete, so the LimitRanges stay and the
# GeneratingPolicies above adopt them.
removed {
  from = kubectl_manifest.generate_limitrange_by_tier
  lifecycle {
    destroy = true
  }
}

# -----------------------------------------------------------------------------
# Layer 3: ResourceQuotas (Kyverno Generate)
# -----------------------------------------------------------------------------
# Creates a ResourceQuota in each namespace based on its tier label.
# Sets hard ceiling on total namespace resource consumption.
# Namespaces with label resource-governance/custom-quota=true are excluded.
#
# IMPORTANT: LimitRange (Layer 2) must exist before ResourceQuota takes effect,
# because ResourceQuota requires all pods to have resource requests set.

locals {
  resourcequota_policies = {
    "0-core"    = { limits_memory = "64Gi", pods = "100", requests_cpu = "8", requests_memory = "8Gi" }
    "1-cluster" = { limits_memory = "32Gi", pods = "30", requests_cpu = "4", requests_memory = "4Gi" }
    "2-gpu"     = { limits_memory = "32Gi", pods = "40", requests_cpu = "8", requests_memory = "12Gi" }
    "3-edge"    = { limits_memory = "32Gi", pods = "30", requests_cpu = "4", requests_memory = "4Gi" }
    "4-aux"     = { limits_memory = "16Gi", pods = "20", requests_cpu = "2", requests_memory = "3Gi" }
  }
}

# Replaces the generate-resourcequota-by-tier ClusterPolicy.
resource "kubectl_manifest" "generate_resourcequota" {
  for_each = local.resourcequota_policies
  yaml_body = templatefile("${path.module}/policies/generate-from-data.yaml", {
    name        = "generate-resourcequota-${each.key}"
    title       = "Generate ResourceQuota for tier ${each.key}"
    kind        = "ResourceQuota"
    object_name = "tier-quota"
    selector = jsonencode([
      { key = "tier", operator = "In", values = [each.key] },
      { key = "resource-governance/custom-quota", operator = "NotIn", values = ["true"] },
    ])
    condition = "true"
    spec = jsonencode({
      hard = {
        "limits.memory"   = each.value.limits_memory
        pods              = each.value.pods
        "requests.cpu"    = each.value.requests_cpu
        "requests.memory" = each.value.requests_memory
      }
    })
  })
  depends_on = [kubectl_manifest.generate_limitrange]
}

removed {
  from = kubectl_manifest.generate_resourcequota_by_tier
  lifecycle {
    destroy = true
  }
}

# -----------------------------------------------------------------------------
# Layer 4: PriorityClassName Injection (Kyverno Mutate)
# -----------------------------------------------------------------------------
# Automatically sets priorityClassName on Pods based on their namespace's tier label.
# Skips pods that already have a priorityClassName set.
# Uses namespaceSelector instead of API calls — no round-trip to the API server.

resource "kubectl_manifest" "mutate_priority_from_tier" {
  yaml_body = templatefile("${path.module}/policies/inject-priority-class-from-tier.yaml", { tiers = jsonencode(local.governance_tiers), exclude = jsonencode(local.excluded_namespaces), gpu_exclude = jsonencode(local.gpu_priority_excluded_namespaces) })

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }
}


# --- ndots:2 injection ---
# Kubernetes defaults to ndots:5, which causes 4 wasted NxDomain queries per
# external DNS lookup (search domain expansion). This policy injects ndots:2
# on all pods to reduce NxDomain flood while still allowing short-name service
# resolution (e.g. "redis.redis" has 1 dot, so it still expands).
resource "kubectl_manifest" "mutate_ndots" {
  yaml_body = templatefile("${path.module}/policies/inject-ndots.yaml", { exclude = jsonencode(local.excluded_namespaces) })

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Layer 5: GPU Workload Priority Override (Kyverno Mutate)
# -----------------------------------------------------------------------------
# Overrides the tier-based priorityClassName with gpu-workload for pods that
# actually request nvidia.com/gpu resources. This ensures GPU pods can preempt
# non-GPU pods on the GPU node, regardless of namespace tier.
# Runs after Layer 4 (tier injection), so it overrides the tier-based priority.

resource "kubectl_manifest" "mutate_gpu_priority" {
  yaml_body = templatefile("${path.module}/policies/inject-gpu-workload-priority.yaml", { gpu_exclude = jsonencode(local.gpu_priority_excluded_namespaces) })

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Layer 5: Automatic Cleanup of Failed/Evicted Pods
# -----------------------------------------------------------------------------
# Deletes pods in Failed phase every hour, cluster-wide.
# Prevents stale evicted pods and failed CronJob pods from accumulating.

# Grant Kyverno cleanup controller permission to delete Pods
resource "kubernetes_cluster_role_v1" "kyverno_cleanup_pods" {
  metadata {
    name = "kyverno:cleanup-controller:pods"
    labels = {
      "app.kubernetes.io/part-of"  = "kyverno"
      "app.kubernetes.io/instance" = "kyverno"
    }
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list", "watch", "delete"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "kyverno_cleanup_pods" {
  metadata {
    name = "kyverno:cleanup-controller:pods"
    labels = {
      "app.kubernetes.io/part-of"  = "kyverno"
      "app.kubernetes.io/instance" = "kyverno"
    }
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.kyverno_cleanup_pods.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "kyverno-cleanup-controller"
    namespace = "kyverno"
  }
}

resource "kubectl_manifest" "cleanup_failed_pods" {
  yaml_body = file("${path.module}/policies/cleanup-failed-pods.yaml")

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Strip CPU Limits (Kyverno Mutate)
# -----------------------------------------------------------------------------
# Removes resources.limits.cpu from every container and initContainer at pod
# admission. Memory limits are preserved. Cluster policy: CFS throttling causes
# more harm than good for bursty single-threaded workloads (Node.js, Python
# apps). Upstream Helm charts (CrowdSec, descheduler, kubernetes-dashboard,
# nvidia gpu-operator) still ship CPU limits — this strips them declaratively
# so we don't have to fork values.yaml per chart.
#
# Scope: admission-time only. Existing pods keep their limits until restarted
# naturally (Helm upgrade, node drain, rollout). No mutateExistingOnPolicyUpdate.
#
# JSON6902 remove op fails on missing paths — per-element precondition gates
# the mutation so pods without CPU limits pass through untouched.

resource "kubectl_manifest" "mutate_strip_cpu_limits" {
  yaml_body = file("${path.module}/policies/strip-cpu-limits.yaml")

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }
}

# Apply re-trigger 2026-06-11: 87702bdc landed with [ci skip], so this stack was
# never CI-applied; tripit#26 (tour-guide redo) needs the tts GPU-priority
# exclusion live before the tts stack applies. No functional change in this commit.

# (See stacks/tts/main.tf — same apply-trigger note, tripit#26.)

# -----------------------------------------------------------------------------
# Layer 6: GPU VRAM budget declaration (Kyverno Validate, ENFORCE)
# -----------------------------------------------------------------------------
# Closes ADR-0016's deferred gap. The gpumem extended resource makes the
# scheduler VRAM-aware, but only for pods that DECLARE a budget — a pod that
# requests nvidia.com/gpu and nothing else is admitted free, is not counted
# against the seating chart, and is invisible to the gpu-vram-watchdog, which
# only ever considers declaring tenants. On 2026-08-31 four pods were in that
# state (yt-highlights, android-emulator, f1-stream, gpu-pod-exporter).
#
# Audit -> Enforce, 2026-09-04. Audit was the right first step but bought
# nothing here: cluster-wide policy reporting has been off since 2026-06-28
# (the etcd incident), there is no reports controller in the kyverno namespace,
# and `kubectl get clusterpolicyreport` returns "No resources found". So the
# audit verdicts were computed and discarded. The pre-flip review therefore read
# the live pod and workload specs instead, which found three gaps the original
# survey missed:
#
#   1. nvidia/gpu-pod-exporter, a DaemonSet with no declaration -> namespace
#      excluded (see local.gpumem_excluded_namespaces).
#   2. tts/chatterbox-tts -> seated at 5200 MiB in stacks/tts.
#   3. the three ebook2audiobook deployments -> seated at 400 MiB each in
#      stacks/ebook2audiobook.
#
# Both measurements came from gpu_pod_memory_used_bytes over the exporter's full
# 26-week record; the numbers and the method are written up next to each seat.
#
# What Enforce now means: a pod that requests nvidia.com/gpu in a non-excluded
# namespace and declares no gpumem is rejected at admission. Workloads created
# outside this repo are covered too — the proxy-browser pods carry their own
# 384 MiB declaration from the broker (stacks/proxy/files/broker/broker.py:116),
# so they pass. See
# docs/plans/2026-08-31-gpu-vram-admission-and-oom-observability.md.
#
# The deliberately seatless tenants (llama-swap, stremio, yt-highlights) are
# excluded by namespace rather than given seats, which is the disposition the
# bead asked for. Their reasons are on local.gpumem_excluded_namespaces.
resource "kubectl_manifest" "validate_gpumem_declared" {
  yaml_body = templatefile("${path.module}/policies/require-gpumem-declaration.yaml", { exclude = jsonencode(local.gpumem_excluded_namespaces) })

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }
}
