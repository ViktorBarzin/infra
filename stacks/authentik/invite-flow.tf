# Invite-code enrollment (spec ViktorBarzin/infra#82, Phase 3).
#
# The invite code is entered in a PROMPT *after* the Google auth returns, so it
# never crosses the OAuth round-trip — this deletes the reason the fragile
# capture/validate session-cache bridge existed. One validation policy gates the
# code; assign-invite-group drops the new user into the invite's target_group.
# Codes are native authentik Invitations with fixed_data {code, target_group}
# minted by `homelab invite`. No URL token, no InvitationStage.
#
# Flow (Google source enrollment_flow = google_proxy_enrollment):
#   order 0  invite-code-prompt  (validate-invite-code gates + stashes the group)
#   order 1  source-enrollment-write  (creates the user)  [gpe_write, google-social-signup.tf]
#   order 2  source-enrollment-login  (assign-invite-group adds the group + consumes)  [gpe_login]

resource "authentik_stage_prompt_field" "invite_code" {
  name        = "invite-code-field"
  field_key   = "invite_code"
  label       = "Invite code"
  type        = "text"
  required    = true
  placeholder = "Enter your invite code"
  order       = 100
}

# Validation policy on the prompt: match the typed code to an open Invitation
# (fixed_data.code), stash the target group on the flow plan, and set a username
# (source enrollments provide none). Returns False on a bad/expired code, which
# rejects the prompt so NO user is created without a valid invite.
resource "authentik_policy_expression" "validate_invite_code" {
  name = "validate-invite-code"
  expression = trimspace(<<-EOT
from authentik.stages.invitation.models import Invitation
from django.utils import timezone
pd = request.context.get("prompt_data", {}) or {}
code = (pd.get("invite_code") or "").strip()
if not code:
    return False
inv = None
for cand in Invitation.objects.filter(fixed_data__code=code):
    if cand.expires and cand.expires < timezone.now():
        continue
    inv = cand
    break
if inv is None:
    return False
tg = (inv.fixed_data or {}).get("target_group")
if not tg:
    return False
plan = request.context.get("flow_plan")
if plan is not None and hasattr(plan, "context"):
    plan.context["invite_target_group"] = tg
    plan.context["invite_pk"] = str(inv.pk)
    plan.context["invite_single_use"] = bool(inv.single_use)
    p2 = plan.context.setdefault("prompt_data", {})
    if not p2.get("username"):
        p2["username"] = p2.get("email") or ("guest-" + code.lower())
return True
EOT
  )
}

resource "authentik_stage_prompt" "invite_code_prompt" {
  name                = "invite-code-prompt"
  fields              = [authentik_stage_prompt_field.invite_code.id]
  validation_policies = [authentik_policy_expression.validate_invite_code.id]
}

# On the login stage (after write, so the user exists): add the new user to the
# invite's target_group and consume a single-use invite. Replaces the hardcoded
# assign-proxy-group.
resource "authentik_policy_expression" "assign_invite_group" {
  name = "assign-invite-group"
  expression = trimspace(<<-EOT
from authentik.core.models import Group
from authentik.stages.invitation.models import Invitation
u = request.context.get("pending_user")
plan = request.context.get("flow_plan")
tg = None
inv_pk = None
single = False
if plan is not None and hasattr(plan, "context"):
    tg = plan.context.get("invite_target_group")
    inv_pk = plan.context.get("invite_pk")
    single = plan.context.get("invite_single_use")
if u is not None and getattr(u, "pk", None) and tg:
    try:
        g = Group.objects.filter(name=tg).first()
        if g is not None:
            u.ak_groups.add(g)
    except Exception:
        pass
if inv_pk and single:
    try:
        inv = Invitation.objects.filter(pk=inv_pk).first()
        if inv is not None:
            inv.delete()
    except Exception:
        pass
return True
EOT
  )
}

# --- wire into the Google enrollment flow ---
# Prompt first (order 0), before the write stage (gpe_write, order 1).
resource "authentik_flow_stage_binding" "gpe_invite_prompt" {
  target               = authentik_flow.google_proxy_enrollment.uuid
  stage                = authentik_stage_prompt.invite_code_prompt.id
  order                = 0
  evaluate_on_plan     = true
  re_evaluate_policies = true
}

# assign-invite-group on the login stage (replaces assign-proxy-group binding).
resource "authentik_policy_binding" "assign_invite_group_on_login" {
  target = authentik_flow_stage_binding.gpe_login.id
  policy = authentik_policy_expression.assign_invite_group.id
  order  = 0
}
