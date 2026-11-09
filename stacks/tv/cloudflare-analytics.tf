# Read access to Cloudflare's analytics for the tv zone, for the cache
# profile in the tv app (tv repo, tv/cf_cache.py).
#
# Viktor asked on 2026-11-09 to profile the Cloudflare caches, so we can see
# how far the household route scales to more viewers and how much of the
# caching can be reused. The app reads the GraphQL Analytics API every
# 5 minutes from one Edge and exports tv_cf_* metrics, which the "TV
# streaming" Grafana dashboard reads.
#
# The token is scoped to Analytics Read on this one zone, rather than handing
# the app the Global API key that Terraform uses (cloudflare_provider.tf).
# Creating user API tokens works on the free plan; checked 2026-11-09 by
# listing /user/tokens/permission_groups with the Global key, which returned
# "Analytics Read" (id below) with scope com.cloudflare.api.account.zone.
#
# It goes straight into a Secret in the tv namespace, the way members.tf
# handles the tokens it mints, so there is nothing for Vault or an
# ExternalSecret to add. Rotate by tainting cloudflare_api_token.tv_analytics.

locals {
  # Source of truth for the zone id is config.tfvars (cloudflare_zone_id), as
  # in cloudflare-cache.tf.
  tv_analytics_zone_id = "fd2c5dd4efe8fe38958944e74d0ced6d"
  # "Analytics Read", zone scope.
  cloudflare_analytics_read = "9c88f9c5bce24ce7af9a958ba9c504db"
}

resource "cloudflare_api_token" "tv_analytics" {
  name = "tv cache analytics (read only, managed by infra/stacks/tv)"

  policies = [{
    effect            = "allow"
    permission_groups = [{ id = local.cloudflare_analytics_read }]
    resources = jsonencode({
      "com.cloudflare.api.account.zone.${local.tv_analytics_zone_id}" = "*"
    })
  }]
}

resource "kubernetes_secret_v1" "tv_cloudflare_analytics" {
  metadata {
    name      = "tv-cloudflare-analytics"
    namespace = kubernetes_namespace.tv.metadata[0].name
  }
  data = {
    token = cloudflare_api_token.tv_analytics.value
  }
}
