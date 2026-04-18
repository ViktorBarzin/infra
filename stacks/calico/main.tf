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
