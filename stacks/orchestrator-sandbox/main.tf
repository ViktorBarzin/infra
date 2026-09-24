# orchestrator-sandbox: a confined namespace for Scion's agent pods during the
# orchestrator bake-off (plan: ~/code/docs/agents/2026-09-24-orchestrator-bake-off.md,
# section "Cluster sandbox"). Scion's hub runs on the devvm and drives this
# namespace through the scion-broker ServiceAccount, whose kubeconfig is built
# from the token Secret below. Its agent pods run here and read the Claude token
# from the claude-oauth Secret.
#
# TEMPORARY. The stack is removed after the sprint unless Scion wins. Teardown:
# `scripts/tg destroy` in this directory from the main checkout, delete the
# directory in a commit, then `vault kv metadata delete secret/orchestrator-sandbox`.

locals {
  namespace = "orchestrator-sandbox"
}

resource "kubernetes_namespace_v1" "sandbox" {
  metadata {
    name = local.namespace
    labels = {
      # Lowest scheduling priority (Kyverno injects the tier-4-aux PriorityClass).
      tier = local.tiers.aux
      # Pod Security Admission at baseline: pods cannot run privileged, join the
      # host namespaces or mount hostPath volumes.
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
      # The quota and LimitRange below replace the Kyverno-generated tier ones.
      "resource-governance/custom-quota"      = "true"
      "resource-governance/custom-limitrange" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# --- Budget ---

# The sprint's cluster budget: 24 GiB of memory on requests and limits, and 12
# CPU on requests. There is deliberately no limits.cpu entry: the Kyverno
# strip-cpu-limits policy removes every container's CPU limit at admission,
# cluster-wide and with no opt-out, so a limits.cpu quota rejects every pod
# ("must specify limits.cpu"). Scion gives each agent container 250m/512Mi
# requests and a 4Gi memory limit by default, so limits.memory caps the
# sandbox at six default agents.
resource "kubernetes_resource_quota_v1" "sandbox" {
  metadata {
    name      = "sandbox-quota"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "12"
      "requests.memory" = "24Gi"
      "limits.memory"   = "24Gi"
    }
  }
}

# Defaults for containers that declare no resources (Scion's optional
# workspace-provision init container, for one), so the quota above does not
# reject them. The values match Scion's own per-agent defaults, minus the CPU
# limit that Kyverno would strip anyway.
resource "kubernetes_limit_range_v1" "sandbox" {
  metadata {
    name      = "sandbox-defaults"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default = {
        memory = "4Gi"
      }
      default_request = {
        cpu    = "250m"
        memory = "512Mi"
      }
    }
  }
}

# --- Scion runtime broker identity ---

# Used from the devvm through a kubeconfig, never by a pod, so no pod gets its
# token mounted automatically.
resource "kubernetes_service_account_v1" "scion_broker" {
  metadata {
    name      = "scion-broker"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name
  }
  automount_service_account_token = false
}

# Long-lived token for the broker's kubeconfig (same pattern as
# stacks/chrome-service/rbac.tf).
resource "kubernetes_secret_v1" "scion_broker_token" {
  metadata {
    name      = "scion-broker-token"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.scion_broker.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# What Scion's Kubernetes runtime calls: pod lifecycle, exec/attach for file
# sync and terminals (it streams over SPDY POST, so `create`; `get` covers
# WebSocket clients such as a current kubectl), logs, and the per-agent secrets
# and workspace claims it creates. Namespace-scoped only.
resource "kubernetes_role_v1" "scion_broker" {
  metadata {
    name      = "scion-broker"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete", "deletecollection"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/exec", "pods/attach"]
    verbs      = ["get", "create"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["secrets", "configmaps", "persistentvolumeclaims"]
    verbs      = ["get", "list", "watch", "create", "update", "delete"]
  }
  # Read access to this namespace's own Namespace object and no other: the
  # apiserver evaluates GET /api/v1/namespaces/<name> inside <name>, so a Role
  # here cannot reach any other namespace. `scion doctor` fails its
  # namespace-access check without it.
  rule {
    api_groups     = [""]
    resources      = ["namespaces"]
    resource_names = [local.namespace]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "scion_broker" {
  metadata {
    name      = "scion-broker"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.scion_broker.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.scion_broker.metadata[0].name
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name
  }
}

# --- Claude token for agent pods ---

# Vault secret/orchestrator-sandbox:claude_code_oauth_token holds wizard's own
# Claude token, kept apart from the fixer's and claude-agent-service's so the
# sandbox can be revoked on its own. Seeded by hand before the first apply:
#   vault kv put secret/orchestrator-sandbox claude_code_oauth_token=-   (value on stdin)
resource "kubernetes_manifest" "claude_oauth" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "claude-oauth"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "claude-oauth"
      }
      data = [
        {
          secretKey = "CLAUDE_CODE_OAUTH_TOKEN"
          remoteRef = {
            key      = "orchestrator-sandbox"
            property = "claude_code_oauth_token"
          }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace_v1.sandbox]
}
