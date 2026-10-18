# Every Authentik application must have an access binding.
#
# Until 2026-10-16 Authentik admitted any signed-in account to an application
# that had no policy binding (`core_default_app_access`, now off in
# system-settings.tf). That gap was found on 2026-07-26 (Kubernetes,
# Kubernetes Dashboard, TripIt) and again on 2026-09-02 (kubernetes-agent),
# each time by a manual audit (app-access-bindings.tf). With the flag off an
# unbound application admits nobody; this guard still requires a binding, so
# an application is never closed by accident and never open if the flag is
# switched back on outside Terraform. From f1-stream ADR-0042 on, open signup
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
#   - one exception to the above: a policy binding to the app's own
#     access-request policy, named "<slug>-access-request", which
#     modules/authentik/app_signup creates in request mode when the app sets
#     existing_account_state_prefix. It admits an account outside the app's
#     groups only for an authorize request carrying the app's request state,
#     records an access request on it, and the app sends that person to its
#     pending page without signing them in (f1-stream ADR-0042, 2026-10-18).
#     The match is by name, so it guards against an accidental binding, not
#     against an admin who names another policy that way.
#
# To fix a failure, bind the application to the groups that should reach it:
# here for UI-managed applications, or next to the application resource in
# the stack that owns it (f1-stream/members.tf is an example, including the
# access-request policy binding described above).
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
    # pages, so it is bound to an allow-all policy (public_allow_all) instead.
    public = "public ingress tier, reachable by anonymous visitors"
  }

  authentik_api = "https://authentik.viktorbarzin.me/api/v3"
  authentik_api_headers = {
    Accept        = "application/json"
    Authorization = "Bearer ${data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]}"
  }

  # Authentik returns at most 100 results per page whatever page_size asks
  # for, so each listing below reads a fixed run of pages, and a page past
  # the end answers 404. Five pages hold 500 applications and 500 bindings;
  # on 2026-10-16 there were 38 and 94. The bindings listing holds every
  # binding (applications, flows, stages), not only application ones. The
  # page count is fixed rather than derived from the first page's count,
  # because for_each cannot use a value that is unknown until apply, which is
  # what these reads are when their depends_on changes. When a listing
  # outgrows the pages read, the guard below fails and names this local.
  #
  # Each listing is ordered by a unique field, so rows cannot shift between
  # pages. The default ordering of bindings is not unique.
  authentik_list_pages     = toset(["1", "2", "3", "4", "5"])
  authentik_list_page_size = 100
}

data "http" "authentik_applications" {
  for_each = local.authentik_list_pages

  # superuser_full_list: without it the API lists only the applications the
  # token's user (akadmin) may open, which would hide exactly the gated ones.
  url             = "${local.authentik_api}/core/applications/?superuser_full_list=true&ordering=slug&page_size=${local.authentik_list_page_size}&page=${each.key}"
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
      condition     = self.status_code == 200 || (self.status_code == 404 && each.key != "1")
      error_message = "Listing Authentik applications failed on page ${each.key} (HTTP ${self.status_code}); the access-binding check cannot run."
    }
  }
}

data "http" "authentik_policy_bindings" {
  for_each = local.authentik_list_pages

  url             = "${local.authentik_api}/policies/bindings/?ordering=pk&page_size=${local.authentik_list_page_size}&page=${each.key}"
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
    authentik_policy_binding.public_allow_all,
  ]

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 || (self.status_code == 404 && each.key != "1")
      error_message = "Listing Authentik policy bindings failed on page ${each.key} (HTTP ${self.status_code}); the access-binding check cannot run."
    }
  }
}

locals {
  # The pages that exist, decoded. Pages past the end (404) drop out.
  live_app_pages = [
    for k in sort(local.authentik_list_pages) : jsondecode(data.http.authentik_applications[k].response_body)
    if data.http.authentik_applications[k].status_code == 200
  ]
  live_binding_pages = [
    for k in sort(local.authentik_list_pages) : jsondecode(data.http.authentik_policy_bindings[k].response_body)
    if data.http.authentik_policy_bindings[k].status_code == 200
  ]

  live_apps     = flatten([for p in local.live_app_pages : p.results])
  live_bindings = flatten([for p in local.live_binding_pages : p.results])

  # A listing is complete when one page read says there is no next page and
  # the rows read, without duplicates, add up to the count the API reports.
  # The second half also catches rows added or removed between page reads.
  live_listing_problems = compact([
    (
      anytrue([for p in local.live_app_pages : p.pagination.next == 0]) &&
      length(distinct([for a in local.live_apps : a.pk])) == local.live_app_pages[0].pagination.count
    ) ? "" : "applications: read ${length(local.live_apps)} of ${local.live_app_pages[0].pagination.count}",
    (
      anytrue([for p in local.live_binding_pages : p.pagination.next == 0]) &&
      length(distinct([for b in local.live_bindings : b.pk])) == local.live_binding_pages[0].pagination.count
    ) ? "" : "policy bindings: read ${length(local.live_bindings)} of ${local.live_binding_pages[0].pagination.count}",
  ])

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
        if b.target == app.pbm_uuid && b.enabled && (b.negate || b.policy != null || (b.group == null && b.user == null)) && !(!b.negate && b.policy != null && try(b.policy_obj.name, "") == "${app.slug}-access-request")
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
      condition     = length(local.live_listing_problems) == 0
      error_message = <<-EOT
        The access-binding check read an incomplete listing from the Authentik API:
        ${join("\n", [for p in local.live_listing_problems : "  - ${p}"])}
        If the count is above ${length(local.authentik_list_pages) * local.authentik_list_page_size}, add pages to local.authentik_list_pages in stacks/authentik/app-access-guard.tf. Otherwise the listing changed while it was read; plan again.
      EOT
    }
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
