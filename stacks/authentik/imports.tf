# -----------------------------------------------------------------------------
# Adoption of resources that exist in the cluster but were created by something
# other than Terraform. Per AGENTS.md: commit the stanza, plan to zero, apply,
# then delete the stanza.
# -----------------------------------------------------------------------------

# The forward-auth Service. Created by authentik's outpost controller on
# 2026-08-19 and repointed at the inline outpost by hand during the 2026-09-19
# cutover; the controller stopped writing it the same day. Adopting it keeps its
# ClusterIP stable, which nginx depends on. See
# modules/authentik/outpost-service.tf for why that matters.
import {
  to = module.authentik.kubernetes_service_v1.outpost
  id = "authentik/ak-outpost-authentik-embedded-outpost"
}
