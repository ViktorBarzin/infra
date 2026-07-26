# =============================================================================
# Invite-gated Google social signup for the proxy service (+ Slack #alerts).
#
# WHY THIS EXISTS
# ---------------
# The proxy self-signup was designed (memory #10194) to let an invited person
# create a `proxy_only` account by clicking "Login with Google" on the shared
# `invitation-enrollment` flow. That NEVER worked: an Authentik invitation lives
# in the flow *plan*, which is abandoned when the browser leaves for Google's
# OAuth screen. On the `/source/oauth/callback/google/` return, the source starts
# its enrollment flow as a FRESH plan with no `itoken` in the URL, so the
# InvitationStage denied with "Invalid invite/invite not found" (verified
# 2026-07-25). Making the source enrollment flow *open* would drop invite-gating,
# which Viktor explicitly does not want ("only invited users may sign up").
#
# HOW IT WORKS NOW
# ----------------
# The browser SESSION KEY is stable across the Google round-trip (same
# authentik.viktorbarzin.me cookie), even though the session DICT is rewritten by
# the OAuth dance. So we bridge the invite across the redirect via the
# Postgres-backed Django cache, keyed by session:
#
#   1. `capture-proxy-invite` (bound to the shared invitation-enrollment flow):
#      parses the itoken out of GET["query"], and IF it resolves to an Invitation
#      whose fixed_data carries attributes.proxy_only, sets
#      cache["proxy_invite_ok:<session_key>"] = True (TTL 900s). Never denies.
#   2. `google-proxy-enrollment` (this flow) is the Google source's enrollment
#      flow: default-source-enrollment {write, login} stages, NO password prompt.
#   3. `validate-proxy-invite` (bound to the write stage) DENIES enrollment unless
#      cache["proxy_invite_ok:<session_key>"] is set. When set it stamps
#      attributes.proxy_only=true + a username (from the Google email, since the
#      source provides no username and there is no prompt stage), and fires a
#      Slack #alerts message. The flag is left to expire (not deleted) because the
#      write binding re-evaluates policies (plan + execution) and a delete on the
#      first pass would make the second pass deny — the bug that cost the most
#      debugging time here.
#
# Result: a direct hit on /source/oauth/login/google/ (no invite) is denied; only
# a session that opened the proxy invite link enrolls, as a proxy_only user that
# the admin-services-restriction policy confines to proxy.viktorbarzin.me.
#
# RUNTIME LINKAGE (NOT in Terraform — the Google OAuth Source is a runtime object,
# not managed here, same as the invitation token in proxy-enrollment.tf):
#   The Google source's `enrollment_flow` is repointed to this flow via the API:
#     ak shell -> OAuthSource.objects.get(slug="google").enrollment_flow =
#                 Flow.objects.get(slug="google-proxy-enrollment"); .save()
#   (was `invitation-enrollment`). Re-apply that one line if the source is ever
#   reseeded. Everything else below is Terraform-managed.
#
# The async Authentik notification pipeline (NotificationRule + EventMatcher) does
# NOT process events in this instance, so the Slack post is done SYNCHRONOUSLY
# from validate-proxy-invite via NotificationTransport.send_webhook_slack(); the
# transport below only supplies the webhook URL + Slack formatting.
# =============================================================================

# #alerts Slack webhook (shared with Alertmanager).
data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

# Existing default source-enrollment stages, reused (no password prompt among them
# that we bind — we deliberately skip default-source-enrollment-prompt, which asks
# the social user to set a local password).
data "authentik_stage" "source_enrollment_write" {
  name = "default-source-enrollment-write"
}

data "authentik_stage" "source_enrollment_login" {
  name = "default-source-enrollment-login"
}

# Shared invite flow (runtime object) — target for the capture policy binding.
data "authentik_flow" "invitation_enrollment" {
  slug = "invitation-enrollment"
}

# -----------------------------------------------------------------------------
# The dedicated Google-source enrollment flow.
# -----------------------------------------------------------------------------
resource "authentik_flow" "google_proxy_enrollment" {
  name           = "Google Proxy Enrollment"
  slug           = "google-proxy-enrollment"
  title          = "Join via Google"
  designation    = "enrollment"
  authentication = "none"
}

resource "authentik_flow_stage_binding" "gpe_write" {
  target = authentik_flow.google_proxy_enrollment.uuid
  stage  = data.authentik_stage.source_enrollment_write.id
  order  = 1
  # validate-proxy-invite mutates prompt_data on both plan + execution passes;
  # keep re-evaluation on so the stamp lands and the deny works on a bare hit.
  evaluate_on_plan     = true
  re_evaluate_policies = true
}

resource "authentik_flow_stage_binding" "gpe_login" {
  target               = authentik_flow.google_proxy_enrollment.uuid
  stage                = data.authentik_stage.source_enrollment_login.id
  order                = 2
  evaluate_on_plan     = false
  re_evaluate_policies = true
}

# -----------------------------------------------------------------------------
# capture-proxy-invite: on the invite landing, stash "this session showed a valid
# proxy invite" in the cache (keyed by the round-trip-stable session key).
# -----------------------------------------------------------------------------
resource "authentik_policy_expression" "capture_proxy_invite" {
  name = "capture-proxy-invite"
  expression = trimspace(<<-EOT
from urllib.parse import parse_qs
from authentik.stages.invitation.models import Invitation
from django.core.cache import cache
http = request.http_request
token = None
try:
    q = http.GET.get("query", "") or ""
    token = parse_qs(q).get("itoken", [None])[0]
except Exception:
    token = None
sk = getattr(http.session, "session_key", None)
# A FRESH/incognito visitor has no session_key yet: authentik's session engine
# mints it lazily on the first save, and this policy runs on the FIRST executor
# request BEFORE that save. So sk was None, the guard below skipped, and the
# invite flag was never written -> validate-proxy-invite then denied every
# clean-browser signup with "No Pending user to login" (root-caused 2026-07-26;
# it only ever worked for testers who already had an authentik session). Force
# the key now, ONLY when there is an itoken to bridge, so capture and the
# post-OAuth validate share one stable session_key.
if token and not sk:
    try:
        http.session.save()
        sk = http.session.session_key
    except Exception:
        sk = None
if token and sk:
    try:
        inv = Invitation.objects.get(pk=token)
        if inv.fixed_data.get("attributes.proxy_only"):
            cache.set("proxy_invite_ok:" + sk, True, 900)
    except Exception:
        pass
return True
EOT
  )
}

resource "authentik_policy_binding" "capture_on_invite" {
  target = data.authentik_flow.invitation_enrollment.id
  policy = authentik_policy_expression.capture_proxy_invite.id
  order  = 99
}

# -----------------------------------------------------------------------------
# validate-proxy-invite: gate the enrollment on the cached invite flag; stamp
# proxy_only + username; post to Slack #alerts (synchronously, deduped).
# -----------------------------------------------------------------------------
resource "authentik_policy_expression" "validate_proxy_invite" {
  name = "validate-proxy-invite"
  expression = trimspace(<<-EOT
from django.core.cache import cache
ctx = request.context
http = request.http_request
sk = getattr(http.session, "session_key", None) if http else None
if not (sk and cache.get("proxy_invite_ok:" + sk)):
    return False
pd = ctx.setdefault("prompt_data", {})
pd["attributes.proxy_only"] = True
if not pd.get("username"):
    pd["username"] = pd.get("email") or "google-user"
plan = ctx.get("flow_plan")
if plan is not None and hasattr(plan, "context"):
    p2 = plan.context.setdefault("prompt_data", {})
    p2["attributes.proxy_only"] = True
    if not p2.get("username"):
        p2["username"] = p2.get("email") or pd["username"]
if not cache.get("proxy_signup_notified:" + sk):
    cache.set("proxy_signup_notified:" + sk, True, 600)
    try:
        from authentik.events.models import NotificationTransport, Notification
        from authentik.core.models import User
        t = NotificationTransport.objects.filter(name="slack-proxy-signup").first()
        if t:
            aku = User.objects.filter(username="akadmin").first()
            email = pd.get("email", "?")
            t.send_webhook_slack(Notification(severity="notice", body="New proxy signup via Google: " + email, user=aku))
    except Exception:
        pass
return True
EOT
  )
}

# validate_on_write REMOVED (infra#82 Phase 3): the invite is now validated by the
# invite-code prompt (invite-flow.tf) BEFORE the write stage, so the write no
# longer needs the cache-bridge validate. The validate-proxy-invite policy is left
# orphaned here and deleted in the Phase-4 bridge cleanup.

# -----------------------------------------------------------------------------
# assign-proxy-group: add the just-enrolled user to the "Proxy Users" group, so
# proxy signups are VISIBLE + manageable as a group (Viktor's explicit ask,
# 2026-07-26 -- "a link that lets a user sign up and be added to the proxy users
# group"), not only via the invisible proxy_only attribute. Bound to the
# enrollment LOGIN stage, which runs AFTER the write stage has created + saved
# the user, so context["pending_user"] exists and can be added to the M2M (the
# write stage's policies run before the user exists, so the group can't be added
# there). admin-services-restriction already grants proxy access to "Proxy Users"
# members, so group membership is now the primary grant; the proxy_only attribute
# stays as belt-and-suspenders. Side-effect-in-policy mirrors
# validate-proxy-invite's established pattern in this flow. Always returns True so
# it never blocks login.
# -----------------------------------------------------------------------------
resource "authentik_policy_expression" "assign_proxy_group" {
  name = "assign-proxy-group"
  expression = trimspace(<<-EOT
from authentik.core.models import Group
u = request.context.get("pending_user")
if u is not None and getattr(u, "pk", None):
    try:
        g = Group.objects.filter(name="Proxy Users").first()
        if g is not None:
            u.ak_groups.add(g)
    except Exception:
        pass
return True
EOT
  )
}

# assign_proxy_group_on_login REMOVED (infra#82 Phase 3): replaced by
# assign_invite_group_on_login (invite-flow.tf), which adds the invite's
# target_group instead of hardcoding "Proxy Users".

# -----------------------------------------------------------------------------
# Slack transport used (synchronously) by validate-proxy-invite. Reuses the
# #alerts webhook. send_once is set but irrelevant on the direct-call path.
# -----------------------------------------------------------------------------
resource "authentik_event_transport" "slack_proxy_signup" {
  name        = "slack-proxy-signup"
  mode        = "webhook_slack"
  webhook_url = data.vault_kv_secret_v2.viktor.data["alertmanager_slack_api_url"]
  send_once   = true
}
