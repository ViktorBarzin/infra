# "TripIt External" group — containment anchor for publicly self-enrolled TripIt
# users (ADR-0020 in the tripit repo). Members are admitted to
# tripit.viktorbarzin.me ONLY and denied every other *.viktorbarzin.me
# forward-auth host by the prepended branch in admin-services-restriction.tf.
#
# Created EMPTY and PARENTLESS, on purpose:
#   * EMPTY — the no-lockout guarantee. Zero members at apply time => the
#     prepended policy branch matches zero existing principals => it cannot
#     change anyone's authorization (contrast authentik_group "T3 Users", which
#     is created WITH members atomically because THAT gate's safety property is
#     the opposite). Membership is assigned at RUNTIME by the tripit-enrollment
#     flow's user_write "Create users group" option (UI-managed per the ADR
#     management split). Terraform owns only the group's EXISTENCE.
#   * PARENTLESS — do NOT make this a child of "Allow Login Users". The sensitive
#     OIDC apps gate on "Home Server Admins" / "Headscale Users" / "Wrongmove
#     Users" (children of "Allow Login Users") or, for Vault, on "Allow Login
#     Users" itself (bound as part of ADR-0020). Keeping External out of that
#     tree is what stops these users reaching OIDC apps — mirrors guest.tf, which
#     keeps the guest group out of "Allow Login Users" for the same reason.
resource "authentik_group" "tripit_external" {
  name = "TripIt External"
}
