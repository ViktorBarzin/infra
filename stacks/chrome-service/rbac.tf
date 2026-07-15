# emo's hands-off "homelab browser" credential + chrome-service port-forward RBAC.
#
# Access decision (2026-06-28, Viktor's explicit call): emo SHARES Viktor's single
# chrome-service browser rather than getting an isolated instance. The noVNC half of
# that grant is the Authentik allowlist in
# stacks/authentik/admin-services-restriction.tf (CHROME_ALLOWED); THIS file is the
# CLI half — it lets emo's `homelab browser` reach the headed Chrome over CDP.
#
# `homelab browser` shells out to `kubectl port-forward -n chrome-service svc/chrome-service`
# (cli/browser.go). emo's normal kubeconfig is interactive-OIDC-only (kubelogin) and
# can't authenticate a headless agent session, and his power-user tier has no
# pods/portforward. So we mint a dedicated ServiceAccount with a long-lived token
# (the dashboard-sa.tf pattern) that the devvm provisioner installs as emo's DEFAULT
# kubeconfig context (scripts/t3-provision-users.sh install_browser_kubeconfig); his
# personal OIDC login stays available as the `oidc@homelab` named context.
#
# TRADE-OFF (accepted): CDP access == full control of the shared browser, including
# the persistent profile (browser.contexts[0]) where Viktor's warmed logins live.
# CDP has no per-context auth, so this SA can reach Viktor's sessions. That is inherent
# to sharing one browser (the isolated per-user instance was declined).
# See docs/architecture/chrome-service.md "Multi-user access".

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

# The ONLY verb emo's SA lacks for `kubectl port-forward svc/chrome-service`: the
# port-forward subresource. (get/list of pods + services + endpoints comes from the
# cluster-read binding below.) Namespace-scoped to chrome-service.
resource "kubernetes_role" "browser_portforward" {
  metadata {
    name      = "chrome-service-portforward"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods/portforward"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "emo_browser_portforward" {
  metadata {
    name      = "emo-browser-portforward"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.browser_portforward.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.emo_browser.metadata[0].name
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
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
# NO deployments, NO cluster scope. (Note: the wizard/emo `homelab browser`
# callers keep their existing `pods/portforward create` grant above, which is
# namespace-wide and already covers port-forwarding to a NAMED worker pod — no
# new port-forward RBAC needed for the pool.)
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
