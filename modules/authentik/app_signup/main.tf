# Per-app sign-up for one Authentik application (ADR-0001 in ~/code/docs/adr,
# "Sign-up"). The shared mechanism lives in stacks/authentik/app-signup.tf;
# this module is the per-app half an app stack instantiates.
#
# It creates the app's "<App> Users" group and registers it for sign-up by
# writing `attributes.signup` on that group. The shared social-signup flow
# reads the registration when a new person arrives through this app's
# authorize request, and then:
#
#   mode = "open"     skips the invite-code prompt, shows the Turnstile
#                     captcha and adds the person to the group.
#   mode = "request"  skips the invite-code prompt, shows the captcha,
#                     creates the account with no group, lets this app's
#                     approver see the account, and sends the person to
#                     var.pending_url. An admin approves in the app, which
#                     adds the person to the group with the approver token.
#
# The module does not create the application or its access binding. The app
# stack binds the application to `group_id` (and to its admin group), which
# app-access-guard.tf in the authentik stack requires anyway.
#
# Membership is NOT managed here: approvals add people at runtime, so
# `users` is ignored. Every update of an authentik_group is a full PUT that
# includes the member list, taken from the refresh that the same plan did, so
# an approval that lands between that refresh and the apply of a change to
# this group would be dropped. Changes to this group are expected to be rare.

terraform {
  required_providers {
    authentik = {
      source = "goauthentik/authentik"
    }
  }
}

locals {
  request_mode = var.mode == "request"

  # Read by the expression policies in stacks/authentik/app-signup.tf.
  # Keep the key names in step with them.
  signup = merge(
    {
      app  = var.app_slug
      mode = var.mode
    },
    local.request_mode ? {
      approver_role = authentik_rbac_role.approver[0].id
      pending_url   = var.pending_url
    } : {},
  )
}

resource "authentik_group" "users" {
  name = var.group_name

  attributes = jsonencode({
    managed_by = "infra/modules/authentik/app_signup"
    signup     = local.signup
  })

  lifecycle {
    ignore_changes = [users]

    precondition {
      condition     = !local.request_mode || try(startswith(var.pending_url, "https://"), false)
      error_message = "mode = \"request\" needs pending_url, an https:// page in the app that tells the person their request is waiting for approval."
    }
  }
}

# --- Request + approve: the approver -----------------------------------------
#
# A service account whose role holds one object permission: add a user to
# this app's group. The sign-up flow adds a second object permission per
# requester (view_user on that one account), so the token can list the people
# who asked for this app and nobody else. GET /api/v3/core/users/ answers 403
# while there are no requesters yet; the app treats that as an empty list.
# Approval is POST /api/v3/core/groups/<group_id>/add_user/ {"pk": <user pk>}.

resource "authentik_rbac_role" "approver" {
  count = local.request_mode ? 1 : 0
  name  = "${var.app_slug} signup approver"
}

resource "authentik_rbac_permission_role" "add_to_group" {
  count      = local.request_mode ? 1 : 0
  role       = authentik_rbac_role.approver[0].id
  permission = "authentik_core.add_user_to_group"
  model      = "authentik_core.group"
  object_id  = authentik_group.users.id
}

resource "authentik_group" "approvers" {
  count = local.request_mode ? 1 : 0
  name  = "${var.app_slug} signup approvers"
  roles = [authentik_rbac_role.approver[0].id]
  # Holds only the service account below, which the user resource adds.
  lifecycle {
    ignore_changes = [users]
  }
}

resource "authentik_user" "approver" {
  count    = local.request_mode ? 1 : 0
  username = "svc-${var.app_slug}-approver"
  name     = "${var.app_slug} (sign-up approver)"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  groups   = [authentik_group.approvers[0].id]

  attributes = jsonencode({
    managed_by = "infra/modules/authentik/app_signup"
    purpose    = "${var.app_slug} lists its access requests and adds approved people to ${var.group_name}"
  })
}

resource "authentik_token" "approver" {
  count        = local.request_mode ? 1 : 0
  identifier   = "svc-${var.app_slug}-approver"
  user         = authentik_user.approver[0].id
  intent       = "api"
  retrieve_key = true
  # Non-expiring, like f1-stream's membership token: a token that lapses on a
  # date nobody watches turns approvals into silent failures. Rotate by
  # tainting this resource.
  expiring    = false
  description = "${var.app_slug} sign-up approvals. Rotate by tainting this resource."
}
