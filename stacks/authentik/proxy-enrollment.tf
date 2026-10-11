# Proxy access scoping + self-signup invite.
#
# ACCESS SCOPING: proxy.viktorbarzin.me has its own forward_single application
# (forward-auth-apps.json) bound to "Proxy Users" and Home Server Admins, so a
# member of this group reaches that host and no other (ADR-0031). Members are
# added by hand after a first login auto-provisions them.
resource "authentik_group" "proxy_users" {
  name = "Proxy Users"
}

# SELF-SIGNUP INVITE (email + GitHub/Facebook via this flow; GOOGLE via its own):
# Rather than a bespoke flow, we REUSE Authentik's existing shared, invite-gated
# `invitation-enrollment` flow — it already renders the email/password prompt
# AND the Google/GitHub/Facebook buttons (its identification stage lists those
# sources). NOTE (2026-07-25): the GOOGLE path no longer completes through this
# flow — an invitation can't survive the OAuth round-trip, so the Google source's
# enrollment_flow is now the dedicated `social-signup` flow with a
# session-cache invite bridge (see stacks/authentik/google-social-signup.tf).
# GitHub/Facebook still use this flow and share the broken-invite limitation.
# Scoping is done per-invitation, WITHOUT touching that shared flow:
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
