# Existing default source-enrollment stages, reused (no password prompt among them
# that we bind — we deliberately skip default-source-enrollment-prompt, which asks
# the social user to set a local password).
data "authentik_stage" "source_enrollment_write" {
  name = "default-source-enrollment-write"
}

data "authentik_stage" "source_enrollment_login" {
  name = "default-source-enrollment-login"
}
# -----------------------------------------------------------------------------
# The shared social-source enrollment flow.
#
# Serves all three OAuth sources (google, github, facebook) as of 2026-09-02.
# Google was the only source pointing here; github and facebook pointed at the
# legacy invitation-enrollment flow, whose invitation stage dead-ended every new
# social signup (infra#51). The sources themselves are UI-managed — their
# consumer secrets are not readable back from the API, so they cannot be
# imported — and were repointed here by API PATCH.
#
# The Terraform address stays `google_proxy_enrollment` deliberately: renaming it
# would need a state move for no functional gain. The live name/slug below are
# what a person sees.
# -----------------------------------------------------------------------------
resource "authentik_flow" "google_proxy_enrollment" {
  name           = "social-signup"
  slug           = "social-signup"
  title          = "Create your account"
  designation    = "enrollment"
  authentication = "none"
}

resource "authentik_flow_stage_binding" "gpe_write" {
  target = authentik_flow.google_proxy_enrollment.uuid
  stage  = data.authentik_stage.source_enrollment_write.id
  order  = 1
  # validate-invite-code (invite-flow.tf) mutates prompt_data on both the plan and
  # execution passes; keep re-evaluation on so the stamp lands and the deny works
  # on a bare hit.
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
