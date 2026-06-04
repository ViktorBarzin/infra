# Catch-all forward-auth restriction: gate the admin-only hostnames to the
# "Home Server Admins" group. Bound to the "Domain wide catch all" application
# (binding stays UI-managed; only the expression is adopted here).
#
# Adopted into Terraform 2026-06-04 to add a carve-out: the Kubernetes Dashboard
# (k8s.viktorbarzin.me) ALSO admits the kubernetes-* RBAC groups, so
# namespace-owners (e.g. gheorghe) can reach the dashboard login page. The
# dashboard itself enforces per-namespace access via the pasted ServiceAccount
# token (stacks/rbac/modules/rbac/dashboard-sa.tf) — this policy only controls
# who reaches the page. All other admin-only hosts remain Home-Server-Admins-only.
import {
  to = authentik_policy_expression.admin_services_restriction
  id = "07a11b85-8f37-4844-aebb-ac9c112ec87c"
}

resource "authentik_policy_expression" "admin_services_restriction" {
  name = "admin-services-restriction"
  expression = trimspace(<<-EOT
    ADMIN_ONLY_HOSTS = {
        "terminal.viktorbarzin.me",
        "frigate.viktorbarzin.me",
        "netbox.viktorbarzin.me",
        "trading.viktorbarzin.me",
        "speedtest.viktorbarzin.me",
        "meshcentral.viktorbarzin.me",
        "k8s.viktorbarzin.me",
        "dashy.viktorbarzin.me",
        "prowlarr.viktorbarzin.me",
        "qbittorrent.viktorbarzin.me",
        "listenarr.viktorbarzin.me",
        "shlink.viktorbarzin.me",
        "openclaw.viktorbarzin.me",
        "openlobster.viktorbarzin.me",
        "wealthfolio.viktorbarzin.me",
    }

    ADMIN_GROUP = "Home Server Admins"

    # The K8s Dashboard additionally admits the Kubernetes RBAC groups. Access
    # to the page is not the security boundary — the pasted ServiceAccount token
    # is (per-namespace admin + cluster read-only). See dashboard-sa.tf.
    K8S_DASHBOARD_HOST = "k8s.viktorbarzin.me"
    K8S_DASHBOARD_GROUPS = [
        "Home Server Admins",
        "kubernetes-admins",
        "kubernetes-power-users",
        "kubernetes-namespace-owners",
    ]

    host = request.context.get("host", "")

    # Not an admin-only host: allow any authenticated user.
    if host not in ADMIN_ONLY_HOSTS:
        return True

    # K8s Dashboard: allow admins OR any Kubernetes RBAC group.
    if host == K8S_DASHBOARD_HOST:
        return any(ak_is_group_member(request.user, name=g) for g in K8S_DASHBOARD_GROUPS)

    # Every other admin-only host: Home Server Admins only.
    return ak_is_group_member(request.user, name=ADMIN_GROUP)
  EOT
  )
}
