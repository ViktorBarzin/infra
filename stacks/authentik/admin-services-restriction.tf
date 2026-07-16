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
        "ac.viktorbarzin.me",
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

    # chrome-service noVNC (chrome.viktorbarzin.me) exposes LIVE logged-in browser
    # sessions from the SHARED persistent profile. Originally Viktor-only.
    # 2026-06-28 (Viktor's explicit decision): emo SHARES Viktor's browser, so emo
    # (emil.barzin / emil.barzin@gmail.com) is allowed in for noVNC form-filling +
    # captcha solving. Trade-off accepted: emo can therefore reach Viktor's warmed
    # sessions (the CLI half is the emo-browser ServiceAccount in
    # stacks/chrome-service/rbac.tf). akadmin kept as break-glass. Match username OR
    # email so neither attribute alone can lock anyone out.
    CHROME_ALLOWED = {"akadmin", "akadmin@viktorbarzin.me", "vbarzin@gmail.com", "emil.barzin", "emil.barzin@gmail.com"}
    if host == "chrome.viktorbarzin.me":
        return request.user.username in CHROME_ALLOWED or request.user.email in CHROME_ALLOWED

    # t3 Workstation edge gate: only members of "T3 Users" may reach t3.
    # Placed BEFORE the ADMIN_ONLY_HOSTS early-return (t3 is intentionally not in
    # that set — it must not require Home-Server-Admins, just T3 Users membership).
    if host == "t3.viktorbarzin.me":
        return ak_is_group_member(request.user, name="T3 Users")

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
