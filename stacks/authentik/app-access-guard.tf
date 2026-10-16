# Every Authentik application must have an access binding.
#
# Authentik admits any signed-in account to an application that has no policy
# binding. That gap was found on 2026-07-26 (Kubernetes, Kubernetes Dashboard,
# TripIt) and again on 2026-09-02 (kubernetes-agent), each time by a manual
# audit (app-access-bindings.tf). From f1-stream ADR-0042 on, open signup
# creates accounts that belong to no group, so an application added without a
# binding would be open to anyone with a Google account.
#
# This file reads every application and every policy binding from the live API
# and fails the plan or apply while any application, in any stack or created in
# the UI, is reachable by an account outside its groups. It also runs in the
# daily drift-detection plan, which is how an application created in the UI or
# in another stack shows up between authentik applies.
#
# What counts as gated:
#   - at least one enabled, non-negated binding to a group or a user, and
#   - under policy_engine_mode "any", no other enabled binding. A policy
#     binding or a negated group binding next to the group bindings passes on
#     its own for an account outside every group, so "any" needs every
#     binding to be a membership check. Under "all" extra bindings only
#     narrow access further.
#
# To fix a failure, bind the application to the groups that should reach it:
# here for UI-managed applications, or next to the application resource in
# the stack that owns it (f1-stream/members.tf is an example).
#
# The reads run after this stack's application and binding changes are
# applied (depends_on below), so an application and its binding can land in
# the same apply. When none of them change, the reads happen at plan time and
# a gap fails the plan before anything is applied.

locals {
  # Applications that may admit any signed-in account, and why. Adding one
  # here is a decision that every account, including one created by open
  # signup with no group, may use it.
  app_access_exempt = {
    # The `auth = "public"` ingress tier (guest.tf). Anonymous visitors are
    # signed in as `guest` by the public-auto-login flow; a signed-in account
    # reaches the same pages a stranger does, and nothing more. A group
    # binding here would turn signed-in household members away from public
    # pages.
    public = "public ingress tier, reachable by anonymous visitors"
  }

  authentik_api = "https://authentik.viktorbarzin.me/api/v3"
  authentik_api_headers = {
    Accept        = "application/json"
    Authorization = "Bearer ${data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]}"
  }
}

data "http" "authentik_applications" {
  # superuser_full_list: without it the API lists only the applications the
  # token's user (akadmin) may open, which would hide exactly the gated ones.
  url             = "${local.authentik_api}/core/applications/?superuser_full_list=true&page_size=1000"
  request_headers = local.authentik_api_headers

  depends_on = [
    authentik_application.catchall,
    authentik_application.forward_auth,
    authentik_application.postgres_ldap,
    authentik_application.rac,
    authentik_application.public,
  ]

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && try(jsondecode(self.response_body).pagination.next == 0, false)
      error_message = "Listing Authentik applications failed or returned more than one page (HTTP ${self.status_code}); the access-binding check cannot run."
    }
  }
}

data "http" "authentik_policy_bindings" {
  url             = "${local.authentik_api}/policies/bindings/?page_size=1000"
  request_headers = local.authentik_api_headers

  depends_on = [
    data.http.authentik_applications,
    authentik_policy_binding.k8s_app_access,
    authentik_policy_binding.tripit_home_users_access,
    authentik_policy_binding.tripit_admins_access,
    authentik_policy_binding.ui_app_access,
    authentik_policy_binding.catchall_admins,
    authentik_policy_binding.forward_auth,
    authentik_policy_binding.postgres_ldap_access,
    authentik_policy_binding.rac_access,
    authentik_policy_binding.vault_allow_login_users,
    authentik_policy_binding.immich_home_users,
    authentik_policy_binding.linkwarden_home_users,
  ]

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && try(jsondecode(self.response_body).pagination.next == 0, false)
      error_message = "Listing Authentik policy bindings failed or returned more than one page (HTTP ${self.status_code}); the access-binding check cannot run."
    }
  }
}

locals {
  live_apps     = jsondecode(data.http.authentik_applications.response_body).results
  live_bindings = jsondecode(data.http.authentik_policy_bindings.response_body).results

  # Per application: enabled bindings that admit only members of a group or one
  # named user, and enabled bindings of any other kind.
  live_app_access = {
    for app in local.live_apps : "${app.name} (${app.slug})" => {
      slug = app.slug
      mode = app.policy_engine_mode
      membership = length([
        for b in local.live_bindings : b
        if b.target == app.pbm_uuid && b.enabled && !b.negate && b.policy == null && (b.group != null || b.user != null)
      ])
      other = length([
        for b in local.live_bindings : b
        if b.target == app.pbm_uuid && b.enabled && (b.negate || b.policy != null || (b.group == null && b.user == null))
      ])
    }
  }

  app_access_gaps = {
    for name, a in local.live_app_access : name => (
      a.membership == 0
      ? "has no enabled group or user binding"
      : "uses policy_engine_mode \"any\" with a policy or negated binding, which can admit an account outside its groups"
    )
    if !contains(keys(local.app_access_exempt), a.slug) && (a.membership == 0 || (a.mode == "any" && a.other > 0))
  }
}

# Holds no data. Its precondition is evaluated on every plan, and again at
# apply time when the reads above were deferred. No input on purpose: an input
# derived from the live list would show as drift in the daily drift-detection
# plan every time an application is added in another stack.
resource "terraform_data" "app_access_guard" {
  lifecycle {
    precondition {
      condition     = length(local.app_access_gaps) == 0
      error_message = <<-EOT
        Authentik applications open to any signed-in account:
        ${join("\n", [for name, why in local.app_access_gaps : "  - ${name} ${why}"])}
        Bind each to the groups that should reach it (stacks/authentik/app-access-guard.tf explains how), or, if it is meant for everyone, list its slug in local.app_access_exempt with the reason.
      EOT
    }
  }
}
