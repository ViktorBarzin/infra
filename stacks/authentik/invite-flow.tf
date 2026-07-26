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
  placeholder = "e.g. R7K-M4Q"
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
# setdefault so our writes to prompt_data persist to the write stage.
pd = request.context.setdefault("prompt_data", {})
# Normalize the typed code so matching is forgiving: upper-case, no dashes/spaces.
# Codes are minted/displayed as e.g. R7K-M4Q but stored canonical ("R7KM4Q").
code = (pd.get("invite_code") or "").strip().upper().replace("-", "").replace(" ", "")
if not code:
    return False
pd["invite_code"] = code
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
# Source enrollments carry no username; set one directly on prompt_data (a flow
# plan is NOT in this validation context — the original empty-username abort).
if not pd.get("username"):
    pd["username"] = pd.get("email") or ("guest-" + code.lower())
# Stamp the invite's group + code onto the NEW USER via attributes.* (the write
# stage persists attributes.*), so the login-stage assign policy reads them from
# the saved user — prompt_data does not reliably survive to the login stage.
pd["attributes.invite_group"] = tg
pd["attributes.invite_code"] = code
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
# Add the new user to the invite's target group. Resolve the group from EITHER
# source, so a single stash mechanism failing can't drop the assignment:
#   1. attributes.invite_group — stamped by validate-invite-code via the write stage
#   2. the invite code (attributes.invite_code, else prompt_data) re-looked-up
# Then upgrade the guest- placeholder username to the real email, consume a
# single-use invite, and drop the transient bookkeeping attributes.
u = request.context.get("pending_user")
if u is None or not getattr(u, "pk", None):
    return True
attrs = u.attributes or {}
pd = request.context.get("prompt_data", {}) or {}
code = attrs.get("invite_code") or (pd.get("invite_code") or "").strip().upper().replace("-", "").replace(" ", "")
tg = attrs.get("invite_group")
if not tg and code:
    inv0 = Invitation.objects.filter(fixed_data__code=code).first()
    if inv0 is not None:
        tg = (inv0.fixed_data or {}).get("target_group")
if tg:
    g = Group.objects.filter(name=tg).first()
    if g is not None:
        u.ak_groups.add(g)
# Google provides no username, so the write stage stored a guest- placeholder;
# make the account identifiable by its email.
try:
    if u.username.startswith("guest-") and u.email:
        u.username = u.email
except Exception:
    pass
if code:
    for inv in Invitation.objects.filter(fixed_data__code=code):
        if inv.single_use:
            try:
                inv.delete()
            except Exception:
                pass
        break
for k in ("invite_group", "invite_code"):
    attrs.pop(k, None)
u.attributes = attrs
try:
    u.save()
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
