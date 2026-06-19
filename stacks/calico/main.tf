# Calico CNI
#
# Calico has underpinned this cluster's pod networking since 2024-07-30, installed
# as raw kubectl manifests (tigera-operator Deployment + CRDs + Installation CR).
# Bringing the full stack under Terraform is high-blast — the operator and its
# Deployment must never flap during node pressure or during any apply, because
# new pod scheduling breaks within ~seconds of a CNI outage.
#
# This stack (created 2026-04-18 Wave 5b) adopts the three namespaces only:
# calico-system, calico-apiserver, tigera-operator. The `tigera-operator`
# Deployment, the 20+ CRDs it manages, and the `Installation` CR itself are
# intentionally *not* adopted yet — they require a low-traffic window and a
# careful ignore_changes set to cover operator-generated defaults on the
# Installation CR. Follow-up tracked in beads code-3ad.
#
# The namespaces are safe to adopt (no networking impact — they're just label
# containers) and give TF an audit trail entry for the labels/tier Kyverno
# cares about.

resource "kubernetes_namespace" "calico_system" {
  metadata {
    name = "calico-system"
    labels = {
      name = "calico-system"
# calico-system namespace is managed by tigera-operator — auto-update is
      # incompatible (operator reverts DaemonSet image from its Installation CR).
      # "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode label on every namespace.
    # pod-security.kubernetes.io/* labels are applied by the tigera-operator
    # reconciler on calico-system + calico-apiserver for PSA 'privileged'.
    ignore_changes = [
      metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"],
      metadata[0].labels["pod-security.kubernetes.io/enforce"],
      metadata[0].labels["pod-security.kubernetes.io/enforce-version"],
    ]
  }
}

resource "kubernetes_namespace" "calico_apiserver" {
  metadata {
    name = "calico-apiserver"
    labels = {
      name = "calico-apiserver"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1 + PSA labels applied by tigera-operator (see calico_system).
    ignore_changes = [
      metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"],
      metadata[0].labels["pod-security.kubernetes.io/enforce"],
      metadata[0].labels["pod-security.kubernetes.io/enforce-version"],
    ]
  }
}

resource "kubernetes_namespace" "tigera_operator" {
  metadata {
    name = "tigera-operator"
    labels = {
      name = "tigera-operator"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Wave 1 W1.6 (beads code-8ywc): observation phase via Calico GlobalNetworkPolicy
# `action: Log`. This is the supported primitive on Calico OSS v3.26 — the
# Calico-Enterprise FelixConfiguration.flowLogsFileEnabled approach is NOT
# accepted by the OSS CRD (verified 2026-05-19: "strict decoding error").
#
# How it works:
#   - GNP selects pods by namespaceSelector
#   - egress rule action=Log writes an iptables NFLOG entry that lands in the
#     kernel log / journald with prefix "calico-packet:" on each node
#   - Alloy DaemonSet already ships node-journal to Loki (job=node-journal)
#   - LogQL query: {job="node-journal"} |= "calico-packet" surfaces egress flows
#   - After ~1 week of observation, build the empirical per-namespace egress
#     allowlist; then flip the same GNP to [Allow specific dests, Deny rest]
#
# Started with `recruiter-responder` as the pilot on 2026-05-19; expanded
# 2026-05-19 to all tier 3+4 namespaces (per locked plan — tier 3-edge has
# 17 ns, tier 4-aux has 65 ns, all use Calico's WorkloadEndpoint policy
# path). Tier 0/1/2 stay out of observation in wave 1 (cluster infra +
# GPU workloads, deferred per the plan).
#
# `apply_only = true` on the kubectl_manifest means renaming the TF resource
# does NOT destroy the old GNP via TF — we kubectl delete the legacy pilot
# GNP after this applies to clean it up. (Tracked manually.)
resource "kubectl_manifest" "wave1_egress_observe_tier34" {
  yaml_body = yamlencode({
    apiVersion = "projectcalico.org/v3"
    kind       = "GlobalNetworkPolicy"
    metadata = {
      name = "wave1-egress-observe-tier34"
      annotations = {
        "security.viktorbarzin.me/wave"    = "1"
        "security.viktorbarzin.me/purpose" = "observe-then-enforce egress for tier 3-edge + 4-aux"
      }
    }
    spec = {
      order             = 2000
      selector          = "all()"
      namespaceSelector = "tier in {\"3-edge\", \"4-aux\"}"
      types             = ["Egress"]
      egress = [
        # Rule 1: log every egress packet (LOG target writes to kernel/journal,
        # alloy ships to Loki with job=node-journal,transport=kernel).
        # LogQL: {job="node-journal"} |~ "calico-packet"
        { action = "Log" },
        # Rule 2: allow everything (observation must NOT break workloads).
        { action = "Allow" },
      ]
    }
  })
  apply_only = true
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# CI retrigger v4 2026-05-16T14:13:59Z

# CI retrigger v5 2026-05-16T23:10:38Z

# CI retrigger v6 2026-05-16T23:18:58Z

# ---------------------------------------------------------------------------
# tigera-operator under Terraform via the official Helm chart (chart vX.Y.Z ==
# Calico vX.Y.Z). Manages ONLY the operator: installation.enabled=false keeps
# the live Installation CR operator-managed, so Helm NEVER touches the data
# plane (calico-node). Adopted in place at the running 3.26.1 (existing operator
# Deployment/SA/ClusterRole/ClusterRoleBinding pre-stamped with Helm ownership
# metadata 2026-06-19 — a transient migration step), then upgraded by bumping
# `version` one step at a time: 3.26 -> 3.28 -> 3.30 (restores a SUPPORTED k8s
# 1.34 pairing) -> 3.32 (supports k8s 1.36). The ~22 Calico CRDs live in the
# chart's crds/ dir, which `helm upgrade` never modifies (pre-3.32). resources
# preserves the operator's existing 256Mi limit. Apply MANUALLY + supervised
# (watch calico-node roll, maxUnavailable:1); gate each hop on tigerastatus +
# calico-node 7/7 + cross-pod connectivity. See docs/runbooks/k8s-version-upgrade.md.
resource "helm_release" "tigera_operator" {
  name             = "calico"
  namespace        = kubernetes_namespace.tigera_operator.metadata[0].name
  create_namespace = false
  repository       = "https://docs.tigera.io/calico/charts"
  chart            = "tigera-operator"
  version          = "v3.28.5"

  values = [yamlencode({
    installation = { enabled = false }
    apiServer    = { enabled = false }
    resources    = { limits = { memory = "256Mi" } }
  })]
}
