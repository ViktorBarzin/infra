# Cloudflare Cache Rule for f1.viktorbarzin.me — WRITTEN, NOT APPLIED.
#
# Everything below is commented out on purpose. It is the second half of the
# Cloudflare cutover and belongs to whoever performs the flip, because both
# halves want one before-and-after verification rather than two.
#
# THE FLIP ITSELF IS ONE LINE: `dns_type = "non-proxied"` in `module "ingress"`
# in main.tf (grep for `THE CLOUDFLARE CUTOVER IS THIS ONE LINE`). Changing it
# to `"proxied"` REMOVES the explicit A and AAAA records, after which the host
# falls through to the zone-wide `*` CNAME into the cloudflared tunnel
# (ADR-0021). No record is created; the value only drives which branch of
# ingress_factory runs and the external-monitor annotation.
#
# ---------------------------------------------------------------------------
# WHY BYPASS THE CACHE AT ALL, WHEN A CDN IS SUPPOSED TO HELP
# ---------------------------------------------------------------------------
# Cloudflare's service-specific terms for the CDN on Free, Pro and Business
# reserve the right to "disable or limit your access to or use of the CDN … if
# you use or are suspected of using the CDN without such Paid Services to
# serve video or a disproportionate percentage of pictures, audio files, or
# other large files." The scope of that sentence is the ZONE, so a limit earned
# by f1 would reach all 115 proxied hostnames. The design takes Cloudflare for
# IP hiding only and gets its bandwidth saving from peer-assisted delivery
# instead — see wt-tracker.tf.
#
# The mechanical facts that shape the rule, measured or read from Cloudflare's
# own docs on 2026-09-08 rather than assumed:
#   - `.mp4` is on Cloudflare's default-cached extension list. `.m3u8` and
#     `.ts` are not. So doing nothing does NOT mean nothing is cached: the
#     library mp4s, which are the largest objects we serve, would be.
#   - The maximum cacheable object is 512 MB on Free, Pro and Business. A 2.5h
#     race mp4 is far past that, so those requests would go to the origin
#     anyway — but the attempt is what the terms describe.
#   - Cloudflare returns a 206 only when the origin sets Content-Length. That
#     is an origin property and not a cache one, so it splits our two replay
#     paths whatever this rule says: a static file from /replay-cache or the
#     library keeps Range and seeking, while the chunked ffmpeg
#     fragmented-mp4 pipe comes back as a full-body 200 with seeking broken.
#   - The origin timeout is 125s (our own infra/docs/architecture/dns.md:462
#     records 100s and is stale — worth a separate one-line fix).
#
# WHOLE HOST, NOT A PATH LIST. The expression below matches every request to
# f1.viktorbarzin.me. A path-scoped variant is tempting and is the weaker
# choice: the video surface here is /proxy, /relay, /transcode/*, /embed-asset,
# /replays/cache/stream, /replays/library/hls/*, plus whatever the share and
# party work adds, and a rule that misses one silently caches it. What
# whole-host bypass costs is edge caching of the SvelteKit /_app/ chunks, which
# are a few hundred KB an hour. If a narrower rule is ever wanted, the
# expression is the only line that changes, e.g.
#   (http.host eq "f1.viktorbarzin.me" and
#    (starts_with(http.request.uri.path, "/proxy") or
#     starts_with(http.request.uri.path, "/relay") or
#     starts_with(http.request.uri.path, "/transcode/") or
#     starts_with(http.request.uri.path, "/replays/")))
#
# ---------------------------------------------------------------------------
# READ THIS BEFORE UNCOMMENTING — a cloudflare_ruleset OWNS ITS WHOLE PHASE
# ---------------------------------------------------------------------------
# A zone has exactly one ruleset per phase, and `cloudflare_ruleset` manages
# that ruleset's complete `rules` list. Applying this would therefore DELETE
# any other Cache Rule already living in `http_request_cache_settings` on this
# zone, including ones created by hand in the dashboard, and Terraform would
# report it as an ordinary in-place update. This repo already learned the
# sharper version of that lesson on the firewall phase: `cloudflare_ruleset`
# `.crowdsec` was the zone's `http_request_firewall_custom` phase entrypoint,
# so destroying it would have wiped every custom rule in the zone, and it was
# detached with a `removed { lifecycle { destroy = false } }` block instead
# (stacks/rybbit/crowdsec_edge.tf). The cache phase is a DIFFERENT phase and
# does not collide with that one, but it has the same ownership property.
#
# So, before uncommenting:
#   1. List what is already there —
#      GET /zones/<zone>/rulesets/phases/http_request_cache_settings/entrypoint
#      and confirm the response is empty or carries only rules reproduced below.
#   2. Apply, then verify against the LIVE host rather than the plan:
#      `curl -sI https://f1.viktorbarzin.me/ | grep -i cf-cache-status`
#      should read BYPASS or DYNAMIC on every path, video and page alike.
#   3. Verify Range still works through the tunnel, which is the thing most
#      likely to regress and the thing seeking depends on:
#      `curl -sI -H 'Range: bytes=0-1023' <a library mp4 URL>` -> 206 plus a
#      Content-Range header. A 200 with the whole body means seeking is broken
#      for that path.
#
# ---------------------------------------------------------------------------
# resource "cloudflare_ruleset" "f1_cache_bypass" {
#   # Source of truth for the id is config.tfvars (cloudflare_zone_id); it is
#   # also the default of ingress_factory's own var.cloudflare_zone_id.
#   zone_id     = "fd2c5dd4efe8fe38958944e74d0ced6d"
#   name        = "f1 video cache bypass"
#   description = "Cloudflare is used for IP hiding on f1, never as a video cache. See stacks/f1-stream/cloudflare-cache-bypass.tf."
#   kind        = "zone"
#   phase       = "http_request_cache_settings"
#
#   rules {
#     ref         = "f1_bypass_all"
#     description = "Bypass cache for every request to f1.viktorbarzin.me"
#     expression  = "(http.host eq \"f1.viktorbarzin.me\")"
#     action      = "set_cache_settings"
#     enabled     = true
#
#     action_parameters {
#       # `cache = false` is the Cache-Rules equivalent of the old
#       # "Cache Level: Bypass" page rule. Cloudflare still proxies the
#       # request, so the origin IP stays hidden, and Range headers and 206
#       # responses pass through untouched.
#       cache = false
#     }
#   }
# }
