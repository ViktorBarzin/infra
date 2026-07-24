# Proxy access scoping + self-signup invite.
#
# ACCESS SCOPING: the admin-services-restriction policy restricts a non-admin
# to ONLY proxy.viktorbarzin.me when they are EITHER in the "Proxy Users" group
# (manual add — after a first login auto-provisions them) OR carry the
# `proxy_only` user attribute (set by the signup invitation, see below).
resource "authentik_group" "proxy_users" {
  name = "Proxy Users"
}

# SELF-SIGNUP INVITE (email OR social/Google):
# Rather than a bespoke flow, we REUSE Authentik's existing shared, invite-gated
# `invitation-enrollment` flow — it already renders the email/password prompt
# AND the Google/GitHub/Facebook buttons (its identification stage lists those
# sources). Scoping is done per-invitation, WITHOUT touching that shared flow:
#
#   The proxy invitation sets  fixed_data = { "attributes.proxy_only": true }.
#   The invitation stage merges fixed_data into prompt_data; UserWriteStage
#   writes `attributes.*` keys onto the new user (verified against the authentik
#   source, stages/user_write/stage.py). So every account created from THIS
#   invite — email or Google — gets user.attributes.proxy_only = true, which the
#   policy above restricts to proxy only. (Groups can't be set via fixed_data —
#   authentik docs — hence the attribute.)
#
# The invitation TOKEN itself is a RUNTIME object (no terraform resource in the
# goauthentik provider). Create/rotate it via the API against the
# invitation-enrollment flow:
#   Invitation.objects.create(name="proxy-signup", flow=<invitation-enrollment>,
#       single_use=False, fixed_data={"attributes.proxy_only": True}, created_by=akadmin)
# Invite URL:
#   https://authentik.viktorbarzin.me/if/flow/invitation-enrollment/?itoken=<invite_uuid>
