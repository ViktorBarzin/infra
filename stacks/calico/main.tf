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
# Starting with `recruiter-responder` as the W1.7 pilot per the locked plan
# (smallest egress footprint, local llama-cpp). Expand by adding namespaces
# to namespaceSelector.matchExpressions over time.
resource "kubectl_manifest" "wave1_egress_observe_recruiter_responder" {
  yaml_body = yamlencode({
    apiVersion = "projectcalico.org/v3"
    kind       = "GlobalNetworkPolicy"
    metadata = {
      name = "wave1-egress-observe-recruiter-responder"
      annotations = {
        "security.viktorbarzin.me/wave"    = "1"
        "security.viktorbarzin.me/purpose" = "observe-then-enforce egress; observation phase only"
      }
    }
    spec = {
      # Order high (numerically lower priority — Calico evaluates lowest order
      # first, but here we just want to run before any default-deny gets added).
      order = 2000
      selector = "all()"
      namespaceSelector = "kubernetes.io/metadata.name == 'recruiter-responder'"
      types = ["Egress"]
      egress = [
        # Rule 1: log every egress packet (does not terminate; falls through)
        { action = "Log" },
        # Rule 2: allow everything (so observation does NOT break the namespace)
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
