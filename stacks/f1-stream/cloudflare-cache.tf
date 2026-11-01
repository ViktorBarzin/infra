# Cloudflare Cache Rules and tiered cache for tv.viktorbarzin.me.
#
# Handed over to stacks/tv (f1-stream plan 2026-11-01-tv-rebrand). These are
# zone-wide objects: the ruleset owns the zone's whole
# http_request_cache_settings phase, and the two tiered-cache settings are
# zone settings. Destroying this stack must not delete them (plan review
# finding 17), so this stack stops tracking them and stacks/tv adopts them with
# import blocks after the cutover. Until then they stay live as they are.
#
# The definitions, with the measurements and the terms-of-service reasoning,
# are in stacks/tv/cloudflare-cache.tf and in this file's history
# (git log -- stacks/f1-stream/cloudflare-cache.tf).

removed {
  from = cloudflare_ruleset.f1_cache
  lifecycle {
    destroy = false
  }
}

removed {
  from = cloudflare_tiered_cache.zone_smart
  lifecycle {
    destroy = false
  }
}

removed {
  from = cloudflare_argo_tiered_caching.zone_smart
  lifecycle {
    destroy = false
  }
}
