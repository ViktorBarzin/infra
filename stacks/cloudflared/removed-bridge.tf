# bridge.viktorbarzin.me (Cloudflare Pages) moved to stacks/valia-sites
# (ADR-0018), which has already imported the live record. Forget it from this
# stack's state WITHOUT destroying. removed{} must sit in the root module —
# a module-level attempt broke init (pipeline 461). Delete this file once the
# apply has run.
removed {
  from = module.cloudflared.cloudflare_record.bridge_pages

  lifecycle {
    destroy = false
  }
}
