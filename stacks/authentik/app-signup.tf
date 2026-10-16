# Per-app sign-up paths (ADR-0001 in ~/code/docs/adr, "Sign-up"), generalised
# from f1-stream ADR-0042.
#
# Everyone who signs up with Google, GitHub or Facebook runs one shared flow,
# social-signup (google-social-signup.tf): invite-code prompt, user write,
# login, passkey. This file adds a second way through that flow for people who
# arrive from an app that has opted in to sign-up, and leaves the invite path
# as it is for everyone else.
#
# HOW THE FLOW KNOWS WHICH APP. An app sends a new person to Authentik with its
# own OAuth authorize request. Authentik's login page keeps that request as
# `next`, the "Sign up" link and the source buttons carry it along, and when
# the person comes back from Google the source flow manager puts it in the
# enrollment plan as context["redirect"] (core/sources/flow_manager.py,
# _prepare_flow, read from the 2026.8.4 source). So the plan names the app's
# client_id. app_signup_lookup below parses it and finds the app's member
# group, which says whether the app takes sign-ups and in which mode.
#
# An app opts in through modules/authentik/app_signup, which creates its
# "<App> Users" group with `attributes.signup = {app, mode, ...}`. Nothing in
# this file changes per app. Anyone can start an authorize request for any
# client_id, so the request is not proof of anything beyond "this person asked
# to use that app"; what it unlocks is limited to that app's own group (open)
# or to no group at all (request).
#
#   order -10  signup-turnstile     only on an app path      (new)
#   order   0  invite-code-prompt   only off an app path     (new negated policy)
#   order   1  user write
#   order   2  login                app-signup-finish added  (new, order 10)
#   order   3  passkey
#
# FAILURE DIRECTION. If the lookup raises, app-signup-path returns False: the
# negated binding then keeps the invite prompt and the captcha is skipped, so
# an error sends the person down the invite path, never past it. An exception
# the policy does not catch gets the same result through failure_result on
# the invite-prompt binding below.
#
# The old Simplified Flow Executor (iOS 16.3 and older, see
# docs/architecture/authentication.md) cannot render a captcha, so those
# browsers can use the invite path but not an app path.

locals {
  # Shared by both expression policies. Returns the app's member group when the
  # enrollment came from a registered app's authorize request, else None.
  # Kept free of "$${" and "%%{" sequences, which HCL would interpolate.
  app_signup_lookup = <<-EOT
    from urllib.parse import parse_qs, urlsplit

    from authentik.core.models import Application, Group
    from authentik.providers.oauth2.models import OAuth2Provider

    APP_SIGNUP_MODES = ("open", "request")


    def app_signup_group_for_slug(slug):
        # Exactly one group may register an app. A group that grants anything
        # beyond its own bindings (superuser, RBAC roles, a parent group whose
        # bindings its members inherit) is never a sign-up target.
        groups = list(Group.objects.filter(attributes__signup__app=slug)[:2])
        if len(groups) != 1:
            return None
        group = groups[0]
        signup = (group.attributes or {}).get("signup") or {}
        if signup.get("mode") not in APP_SIGNUP_MODES:
            return None
        if group.is_superuser or group.roles.exists() or group.parents.exists():
            return None
        return group


    def app_signup_group(ctx):
        # Only a social-source enrollment counts. Entering social-signup
        # directly has no source and no provider-vouched email.
        if ctx.get("source") is None:
            return None
        target = ctx.get("redirect")
        if not isinstance(target, str) or not target:
            return None
        parts = urlsplit(target)
        if parts.scheme not in ("", "https"):
            return None
        if parts.netloc not in ("", "authentik.viktorbarzin.me"):
            return None
        if parts.path != "/application/o/authorize/":
            return None
        client_ids = parse_qs(parts.query).get("client_id") or []
        if len(client_ids) != 1:
            return None
        provider = OAuth2Provider.objects.filter(client_id=client_ids[0]).first()
        if provider is None:
            return None
        app = Application.objects.filter(provider=provider).first()
        if app is None:
            return None
        return app_signup_group_for_slug(app.slug)


    STATE_CHARS = frozenset(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-~"
    )


    def app_signup_state(ctx):
        # The authorize request's OAuth `state`, which the app chose. Recorded
        # on a request-mode account so the app can tell which of its own
        # requests the account came from (f1-stream ties it to the TV that
        # showed the QR). URL-safe and at most 256 characters, else None.
        target = ctx.get("redirect")
        if not isinstance(target, str):
            return None
        states = parse_qs(urlsplit(target).query).get("state") or []
        if len(states) != 1:
            return None
        state = states[0]
        if not state or len(state) > 256 or not set(state) <= STATE_CHARS:
            return None
        return state
  EOT
}

# Decides "is this an app path" and, when it is, prepares the plan for the
# write stage: a username (social sources supply none; the invite prompt's
# policy sets it on the invite path) and the mode's marker.
#   open     attributes.invite_group, which assign-invite-group
#            (invite-flow.tf) turns into membership on the login stage.
#   request  attributes.signup_request.{app,requested_at,state}, which
#            app-signup-finish reads after the user exists. `state` is the
#            authorize request's OAuth state, when it is URL-safe; the app
#            uses it to find which of its requests the account belongs to,
#            and it is appended to pending_url as ?state=.
# Bound twice: to the captcha binding as is, and to the invite-prompt binding
# negated. Both bindings evaluate on plan and again at run time; the writes are
# idempotent.
resource "authentik_policy_expression" "app_signup_path" {
  name              = "app-signup-path"
  execution_logging = true
  expression        = <<-EOT
    ${local.app_signup_lookup}

    from django.utils import timezone

    try:
        group = app_signup_group(request.context)
    except Exception as exc:  # fail toward the invite path
        ak_logger.warning("app-signup-path: lookup failed", error=str(exc))
        return False
    if group is None:
        return False
    pd = request.context.get("prompt_data")
    if not isinstance(pd, dict) or not pd.get("email"):
        return False
    signup = group.attributes["signup"]
    if not pd.get("username"):
        pd["username"] = pd["email"]
    if signup["mode"] == "open":
        pd["attributes.invite_group"] = group.name
    else:
        pd["attributes.signup_request.app"] = signup["app"]
        pd["attributes.signup_request.requested_at"] = timezone.now().isoformat()
        state = app_signup_state(request.context)
        if state:
            pd["attributes.signup_request.state"] = state
    return True
  EOT
}

# Runs on the login stage, after the user row exists. For a request-mode
# sign-up it lets that app's approver role see this one account (view_user on
# the object, which is what both the users listing and add_user check), and
# sends the person to the app's pending page instead of back into an authorize
# request their account cannot pass yet. Always returns True: the login
# binding must never be skipped because of this policy.
resource "authentik_policy_expression" "app_signup_finish" {
  name              = "app-signup-finish"
  execution_logging = true
  expression        = <<-EOT
    ${local.app_signup_lookup}

    from urllib.parse import urlencode

    from authentik.rbac.models import Role

    try:
        user = request.context.get("pending_user")
        if user is None or not getattr(user, "pk", None):
            return True
        wanted = ((user.attributes or {}).get("signup_request") or {}).get("app")
        if not wanted:
            return True
        group = app_signup_group_for_slug(wanted)
        if group is None:
            return True
        signup = group.attributes["signup"]
        if signup.get("mode") != "request":
            return True
        role = Role.objects.filter(pk=signup.get("approver_role")).first()
        if role is not None:
            role.assign_perms("authentik_core.view_user", obj=user)
        else:
            ak_logger.warning("app-signup-finish: approver role missing", app=wanted)
        plan = request.context.get("flow_plan")
        pending_url = signup.get("pending_url")
        if plan is not None and pending_url:
            # The app's own state rides along, so its pending page knows
            # which request this was.
            state = ((user.attributes or {}).get("signup_request") or {}).get("state")
            if isinstance(state, str) and state:
                joiner = "&" if "?" in pending_url else "?"
                pending_url = pending_url + joiner + urlencode({"state": state})
            plan.context["redirect"] = pending_url
    except Exception as exc:
        ak_logger.warning("app-signup-finish: failed", error=str(exc))
    return True
  EOT
}

# --- Turnstile captcha ---------------------------------------------------------
#
# Reuses the Cloudflare Turnstile widget stacks/turnstile-gate creates
# ("site-gate", managed mode, domain viktorbarzin.me, which covers
# authentik.viktorbarzin.me). Its keys live only in that stack's state and in
# Cloudflare, not in Vault, and CI's Vault role cannot write KV, so this stack
# reads them from the Cloudflare API with the same credentials its cloudflare
# provider uses. Turnstile is free; nothing here creates a widget or enables a
# paid feature. If turnstile-gate ever recreates the widget, the next authentik
# apply picks up the new keys.

data "cloudflare_accounts" "main" {}

locals {
  turnstile_widgets_api = "https://api.cloudflare.com/client/v4/accounts/${data.cloudflare_accounts.main.result[0].id}/challenges/widgets"
  turnstile_api_headers = {
    Accept       = "application/json"
    X-Auth-Email = "vbarzin@gmail.com"
    X-Auth-Key   = data.vault_kv_secret_v2.cf_platform.data["cloudflare_api_key"]
  }
  turnstile_widget_name = "site-gate"
}

data "http" "turnstile_widgets" {
  url             = "${local.turnstile_widgets_api}?per_page=50"
  request_headers = local.turnstile_api_headers

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Listing Turnstile widgets failed (HTTP ${self.status_code})."
    }
    postcondition {
      condition     = length([for w in jsondecode(self.response_body).result : w if w.name == local.turnstile_widget_name]) == 1
      error_message = "Expected exactly one Turnstile widget named ${local.turnstile_widget_name} (created by stacks/turnstile-gate)."
    }
  }
}

locals {
  turnstile_sitekey = one([
    for w in jsondecode(data.http.turnstile_widgets.response_body).result : w.sitekey
    if w.name == local.turnstile_widget_name
  ])
}

data "http" "turnstile_widget" {
  url             = "${local.turnstile_widgets_api}/${local.turnstile_sitekey}"
  request_headers = local.turnstile_api_headers

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Reading the ${local.turnstile_widget_name} Turnstile widget failed (HTTP ${self.status_code})."
    }
  }
}

resource "authentik_stage_captcha" "signup_turnstile" {
  name        = "signup-turnstile"
  public_key  = local.turnstile_sitekey
  private_key = sensitive(jsondecode(data.http.turnstile_widget.response_body).result.secret)
  js_url      = "https://challenges.cloudflare.com/turnstile/v0/api.js"
  api_url     = "https://challenges.cloudflare.com/turnstile/v0/siteverify"
  # Turnstile renders a widget the person may have to click.
  interactive = true
  # Turnstile's siteverify answer carries no score, so these never apply;
  # set to the full range so a score field appearing later cannot reject.
  score_min_threshold    = 0
  score_max_threshold    = 1
  error_on_invalid_score = true
}

# --- Wiring into social-signup ---------------------------------------------------

# Until its policy binding below exists (seconds, within one apply) this
# binding has no policy and would show the captcha on the invite path too.
# That is harmless, and it cannot be ordered the other way: a policy binding
# needs its target to exist first.
resource "authentik_flow_stage_binding" "gpe_turnstile" {
  target               = authentik_flow.google_proxy_enrollment.uuid
  stage                = authentik_stage_captcha.signup_turnstile.id
  order                = -10
  evaluate_on_plan     = true
  re_evaluate_policies = true
  depends_on           = [authentik_policy_expression.app_signup_path]
}

resource "authentik_policy_binding" "app_signup_turnstile" {
  target = authentik_flow_stage_binding.gpe_turnstile.id
  policy = authentik_policy_expression.app_signup_path.id
  order  = 0
}

# The invite prompt runs unless this is an app path.
#
# failure_result = true matters here: when a policy raises, Authentik uses the
# binding's failure_result and does NOT apply negate (policies/process.py), so
# an error keeps the invite prompt.
resource "authentik_policy_binding" "app_signup_skip_invite" {
  target         = authentik_flow_stage_binding.gpe_invite_prompt.id
  policy         = authentik_policy_expression.app_signup_path.id
  negate         = true
  failure_result = true
  order          = 0
}

# After assign-invite-group (order 0), which adds open-mode members.
# failure_result = true so an error can never take the login stage out of
# the plan.
resource "authentik_policy_binding" "app_signup_finish_on_login" {
  target         = authentik_flow_stage_binding.gpe_login.id
  policy         = authentik_policy_expression.app_signup_finish.id
  failure_result = true
  order          = 10
}
