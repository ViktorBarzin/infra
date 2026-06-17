# Delivers the TripIt enrollment/recovery email-verification stages + their flow
# bindings (tripit-email-stages.yaml) as a server-applied Authentik blueprint.
#
# Why a blueprint and not authentik_stage_email resources: the globally-pinned
# provider (goauthentik 2024.x in terragrunt.hcl) models EmailStage.token_expiry
# as an integer, but the live server (2026.2.x) requires a duration string and
# 400s any number. The blueprint is parsed by the server, which accepts the
# string. Bumping the provider would mean a global terragrunt.hcl change that
# re-applies every platform stack — disproportionate. See tripit-flows.tf.
#
# depends_on the flows so they exist before Authentik resolves the blueprint's
# !Find [..., slug, tripit-enrollment|tripit-recovery] references.
resource "authentik_blueprint" "tripit_email_stages" {
  name    = "tripit-email-stages"
  content = file("${path.module}/tripit-email-stages.yaml")
  enabled = true

  depends_on = [
    authentik_flow.tripit_enrollment,
    authentik_flow.tripit_recovery,
  ]
}
