# Default-deny closure for the previously-ungated OIDC apps (spec ViktorBarzin/infra#82).
#
# Audit 2026-07-26: Kubernetes, Kubernetes Dashboard, and TripIt applications had
# NO authorization binding, so authentik's default "allow any authenticated user"
# let a proxy-only guest OIDC-log-into them (incl. obtaining a Kubernetes cluster
# token — k8s RBAC still gates actions, but the token should not be issued at all).
# Bind each to the groups that may enter; the apps stay default-deny for everyone
# else. (The "Public" app keeps its intentional anonymous binding — guest.tf.)
#
# Apps stay UI-managed (like the other OIDC apps + Vault). We add ONLY the bindings,
# pinning pbm_uuid / group_uuid LITERALS: this provider version has no
# `data "authentik_application"` (CI pipeline 198 failed on it). Re-fetch after a
# recreate via `ak shell` in goauthentik-server:
#   Application.objects.get(name="Kubernetes").pbm_uuid
#   Group.objects.get(name="kubernetes-admins").group_uuid
# All three apps are policy_engine_mode="any", so membership in ANY bound group grants.

# --- TripIt Users: dedicated group for the TripIt app (Viktor + travel-sharers) ---
resource "authentik_group" "tripit_users" {
  name = "TripIt Users"
}

locals {
  # Kubernetes + Kubernetes Dashboard: cluster operators + admins only.
  k8s_apps = {
    "kubernetes"           = "06733378-c2dc-46a8-a3f7-4f3670922ab4" # app "Kubernetes"
    "kubernetes-dashboard" = "9593b57a-83e5-45f2-ad92-16b3ddf9223a" # app "Kubernetes Dashboard"
  }
  k8s_operator_groups = [
    "e4b39bac-540f-49b1-a53d-697baf8c92c5", # kubernetes-admins
    "e5a6a70b-280e-40f0-a388-c0d5665e928d", # kubernetes-power-users
    "38552084-ee3e-412a-997e-d75bd83db352", # kubernetes-namespace-owners
    "54559f22-54be-4701-9c91-ac8a16cc7d30", # Home Server Admins
  ]
  # cross-product -> one binding per (app, group), with distinct order per app
  k8s_bindings = merge([
    for appk, pbm in local.k8s_apps : {
      for i, guuid in local.k8s_operator_groups :
      "${appk}-${i}" => { target = pbm, group = guuid, order = i }
    }
  ]...)
}

resource "authentik_policy_binding" "k8s_app_access" {
  for_each = local.k8s_bindings
  target   = each.value.target
  group    = each.value.group
  order    = each.value.order
}

# --- TripIt: the TripIt Users group + admins ---
resource "authentik_policy_binding" "tripit_users_access" {
  target = "bce7ba06-4af1-474a-a622-d629cd727a1c" # app "TripIt App"
  group  = authentik_group.tripit_users.id
  order  = 0
}

resource "authentik_policy_binding" "tripit_admins_access" {
  target = "bce7ba06-4af1-474a-a622-d629cd727a1c" # app "TripIt App"
  group  = "54559f22-54be-4701-9c91-ac8a16cc7d30" # Home Server Admins
  order  = 1
}
