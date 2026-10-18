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
# `users` is ignored after the group is created. `initial_users` seeds the
# group on creation only, for people who used the app before it took sign-ups. Every update of an authentik_group is a full PUT that
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
  name  = var.group_name
  users = var.initial_users

  attributes = jsonencode({
    managed_by = "infra/modules/authentik/app_signup"
    signup     = local.signup
  })

  lifecycle {
    ignore_changes = [users]

    precondition {
      condition     = local.request_mode || var.existing_account_state_prefix == null
      error_message = "existing_account_state_prefix needs mode = \"request\"."
    }

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

# --- Request + approve: people who already have an account -------------------
#
# The sign-up flow above only runs for a new person. Someone who already has
# an Authentik account outside this app's groups never enrols: Authentik checks
# the application's bindings at the authorize step and shows its own
# access-denied page. With existing_account_state_prefix set, this policy,
# bound to the application by the app stack, admits such an account for an
# authorize request whose OAuth state starts with that prefix, and records the
# request first, the way app-signup-path and app-signup-finish
# (stacks/authentik/app-signup.tf) do for a new account:
#
#   attributes.signup_request.{app, requested_at, state}  on the account
#   view_user on that account                              for the approver role
#
# Authentik then finishes the authorize request, so the app receives an ID
# token for a person in none of its groups. The app must check the groups
# claim (every app here does, ADR-0001) and send that person to its pending
# page instead of signing them in; nothing is granted until an admin approves
# in the app. f1-stream does this in /auth/callback (ADR-0042).
#
# A browser signed in as the shared `guest` account (stacks/authentik/guest.tf,
# given to anyone who opens a public-tier page) arrives here with a prefixed
# state too. The policy signs that browser out of its guest session and
# returns True: the authorize view then finds no login event, so it sends the
# browser to the authentication flow, and after a real sign-in the policy runs
# again for that person. Nothing is written to `guest` and no code is issued
# to it. Signing out happens before the sign-in page, which matters: a Google
# login made while still signed in as guest would link that Google identity
# to `guest` (Authentik's source LINK action), and `prompt=login` does not
# help because Authentik checks bindings before it reads `prompt`.
#
# It returns False, and changes nothing, for: any other authorize request or
# API call that evaluates the application's bindings, a member of any group
# bound to the application (those bindings decide), a service account, other
# users under users/system, and an account whose signup_request names another
# app. An error inside it denies, through the binding's default failure_result.

locals {
  existing_account_request = local.request_mode && var.existing_account_state_prefix != null
}

resource "authentik_policy_expression" "existing_account_request" {
  count             = local.existing_account_request ? 1 : 0
  name              = "${var.app_slug}-access-request"
  execution_logging = true
  expression        = <<-EOT
    from django.contrib.auth import logout
    from django.utils import timezone

    from authentik.core.models import Application
    from authentik.policies.models import PolicyBinding
    from authentik.rbac.models import Role

    APP = "${var.app_slug}"
    STATE_PREFIX = "${coalesce(var.existing_account_state_prefix, "-")}"
    APPROVER_ROLE = "${authentik_rbac_role.approver[0].id}"
    STATE_CHARS = frozenset(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-~"
    )

    http = request.http_request
    if http is None or http.path != "/application/o/authorize/":
        return False
    states = http.GET.getlist("state")
    if len(states) != 1:
        return False
    state = states[0]
    if not state.startswith(STATE_PREFIX) or len(state) > 256 or not set(state) <= STATE_CHARS:
        return False

    user = request.user
    if user is None or not user.is_authenticated or not user.is_active:
        return False
    if user.type not in ("internal", "external"):
        return False
    # The shared anonymous account the public ingress tier signs strangers in
    # as (stacks/authentik/guest.tf). Sign the browser out so the authorize
    # view asks for a real sign-in; True only once it is signed out, so guest
    # itself is never let through.
    if user.username == "guest" and (user.path or "").startswith("users/system"):
        if not hasattr(http, "session"):
            return False
        logout(http)
        signed_out = not http.user.is_authenticated
        ak_logger.info("access-request: signed guest out", app=APP, signed_out=signed_out)
        return signed_out
    # Google sign-ups live under goauthentik.io/sources/..., so that prefix is
    # not excluded.
    if (user.path or "").startswith("users/system"):
        return False

    app = Application.objects.filter(slug=APP).first()
    if app is None:
        return False
    bound = list(
        PolicyBinding.objects.filter(
            target=app, enabled=True, negate=False, group__isnull=False
        ).values_list("group_id", flat=True)
    )
    if user.all_groups().filter(pk__in=bound).exists():
        return False

    attributes = dict(user.attributes or {})
    current = attributes.get("signup_request")
    current = dict(current) if isinstance(current, dict) else {}
    if current.get("app") not in (None, APP):
        ak_logger.info("access-request: account asked for another app", app=APP, user=user.username)
        return False
    current["app"] = APP
    current.setdefault("requested_at", timezone.now().isoformat())
    current["state"] = state
    attributes["signup_request"] = current
    user.attributes = attributes
    user.save(update_fields=["attributes"])

    role = Role.objects.filter(pk=APPROVER_ROLE).first()
    if role is not None:
        role.assign_perms("authentik_core.view_user", obj=user)
    else:
        ak_logger.warning("access-request: approver role missing", app=APP)
    ak_logger.info("access-request: recorded", app=APP, user=user.username)
    return True
  EOT
}
