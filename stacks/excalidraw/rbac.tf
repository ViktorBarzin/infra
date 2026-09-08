# emo's Claude → Excalidraw upload RBAC.
#
# emo's agent uploads drawings with `kubectl -n excalidraw port-forward svc/draw`
# + `PUT /api/drawings/<name>` carrying the X-Authentik-Username header (the
# documented recipe in emo's ~/.claude/CLAUDE.md — the app sits behind Authentik
# forward-auth, so direct curl gets redirected). His hands-off credential is the
# chrome-service/emo-browser ServiceAccount kubeconfig (stacks/chrome-service/rbac.tf);
# its cluster-wide grant (oidc-power-user-readonly) is read-only, so pods/portforward
# must be granted per namespace. This is the excalidraw-namespace grant
# (Viktor's call, 2026-07-02; same pattern as the chrome-service one).
#
# TRADE-OFF (accepted): port-forward into this namespace bypasses the Authentik
# ingress and the drawings API trusts the X-Authentik-Username header, so the SA
# can read/write ANY user's drawings, not only emo's. The namespace runs nothing
# but the drawings app, and the same class of trade-off was already accepted for
# the shared browser (CDP reach into Viktor's sessions).

resource "kubernetes_role" "portforward" {
  metadata {
    name      = "excalidraw-portforward"
    namespace = kubernetes_namespace.excalidraw.metadata[0].name
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
    namespace = kubernetes_namespace.excalidraw.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.portforward.metadata[0].name
  }
  subject {
    kind = "ServiceAccount"
    # Defined in stacks/chrome-service/rbac.tf — referenced by name across
    # stacks, same as that file references the oidc-power-user-readonly
    # ClusterRole. get/list on pods+services (needed to resolve svc/draw) comes
    # from the SA's cluster-read binding there.
    name      = "emo-browser"
    namespace = "chrome-service"
  }
}
