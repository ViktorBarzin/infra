# emo's hands-off "homelab browser" credential.
#
# History: on 2026-06-28 Viktor chose to let emo SHARE his chrome-service browser.
# On 2026-11-08 he reversed that: each person now has their own hub browser with
# their own logins (emo's: stacks/chrome-emo), and emo must not reach Viktor's.
#
# This ServiceAccount stays here as emo's non-interactive kubectl identity: the
# devvm provisioner (scripts/t3-provision-users.sh install_browser_kubeconfig)
# looks it up in this namespace and installs its token as emo's DEFAULT kubeconfig
# context, keeping his personal OIDC login as `oidc@homelab`. What it may do:
# cluster read-only (below), and pods/portforward ONLY in chrome-emo
# (stacks/chrome-emo), where his hub and his pool workers run. It has NO
# port-forward in chrome-service any more, so it cannot reach Viktor's master,
# its CDP, or Viktor's pool workers. The broker is reached over the LAN-only
# chrome-fleet-api host with emo's hub token instead of a port-forward.
# See docs/architecture/chrome-service.md "One hub per person".

resource "kubernetes_service_account" "emo_browser" {
  metadata {
    name      = "emo-browser"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
}

# Long-lived (non-expiring) token for the SA — the devvm provisioner reads this and
# writes it into emo's kubeconfig. Same pattern as stacks/rbac/.../dashboard-sa.tf.
resource "kubernetes_secret" "emo_browser_token" {
  metadata {
    name      = "emo-browser-token"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.emo_browser.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# Cluster-wide read-only (NO secrets), mirroring emo's power-user OIDC access, bound
# to the SA. Needed because the SA becomes emo's DEFAULT kubectl context, so without
# this his everyday `kubectl get ...` would regress — AND port-forward itself needs
# get/list on services + pods + endpoints (all covered by oidc-power-user-readonly).
# That ClusterRole is defined in stacks/rbac (modules/rbac/main.tf); referenced by name.
resource "kubernetes_cluster_role_binding" "emo_browser_readonly" {
  metadata {
    name = "emo-browser-readonly"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "oidc-power-user-readonly"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.emo_browser.metadata[0].name
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
}

# --- Broker ServiceAccount ------------------------------------------------
# The chrome-broker (broker.tf) manages the worker POOL: it creates one bare Pod
# per session, claims/releases the warm-pool pod by patching its session label,
# and deletes bare pods on release/idle-reap. Namespace-scoped pods CRUD only —
# NO deployments, NO cluster scope. It holds the same pods Role in each other
# person's hub namespace (stacks/chrome-emo), where it runs their workers.
# Viktor's `homelab browser` port-forwards to his workers with his own admin
# credential; emo's port-forward grant exists only in chrome-emo.
resource "kubernetes_service_account" "broker" {
  metadata {
    name      = "chrome-broker"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
}

resource "kubernetes_role" "broker" {
  metadata {
    name      = "chrome-broker"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch", "create", "delete", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding" "broker" {
  metadata {
    name      = "chrome-broker"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.broker.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.broker.metadata[0].name
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
}
