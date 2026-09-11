# Cloudflare Cache Rules for f1.viktorbarzin.me.
#
# Viktor asked for edge caching on 2026-09-10, having been shown the terms risk
# below three times and having chosen it over two alternatives (an nginx cache
# on mx2, and paid R2). This file is the OPEN version: it caches video by
# naming the paths, rather than disguising segments with a font or image
# extension so Cloudflare's default rules pick them up. Both carry the SAME
# terms exposure, because the restriction is on the content and not the
# extension; the disguise only lowers the chance of being noticed while making
# it look deliberate if it is. So this does it in the open.
#
# ---------------------------------------------------------------------------
# WHAT THIS BUYS, AND WHAT IT RISKS
# ---------------------------------------------------------------------------
# Measured 2026-09-10: one live viewer costs 4.55 Mbit/s (2.05 GB per
# viewer-hour), and Traefik served 90.3 GB for f1 over the preceding 30 days.
# Against a measured 32.0 Mbit/s of origin egress that is about seven
# concurrent live viewers before the line is full. A replay on the source rung
# is 7.9 Mbit/s, so about four of those.
#
# WHERE 32.0 COMES FROM, because an earlier figure in this file said 15.06 and
# was wrong by half. 15.06 Mbit/s came from a single client pulling one object
# at a time, which measures one TCP stream and not the line. Re-measured the
# same day by purging five segments and fetching them CONCURRENTLY from outside
# (five cold origin pulls through the tunnel, each confirmed against the Traefik
# access log as a real origin fetch): 16,462,784 bytes in 4.116 s wall, so 32.0
# Mbit/s sustained. Treat 32 as a FLOOR rather than a ceiling — nothing in that
# run proves the line was saturated, only that it carries at least this much.
# Re-measure the same way (concurrent, not serial) before trusting any number
# here as a limit.
#
# The risk, in Cloudflare's own words (service-specific terms, CDN on Free, Pro
# and Business): they reserve the right to "disable or limit your access to or
# use of the CDN … if you use or are suspected of using the CDN without such
# Paid Services to serve video or a disproportionate percentage of pictures,
# audio files, or other large files." The scope of that sentence is the ZONE, so
# a limit earned here reaches every proxied hostname on viktorbarzin.me, not
# just f1. That is an accepted risk, not an oversight.
#
# ---------------------------------------------------------------------------
# WHY override_origin AND NOT respect_origin
# ---------------------------------------------------------------------------
# Measured against the live origin on 2026-09-10, not assumed:
#   /proxy  (the live manifest) sends `cache-control: no-cache, no-store,
#           must-revalidate`. `no-store` forbids storage outright, so
#           respect_origin would cache nothing at all.
#   /relay  (a live segment) sends NO cache-control header, and its path
#           carries no extension, so it misses Cloudflare's default-cached
#           extension list too.
# Overriding at the edge is therefore the only mode that caches anything. Note
# what this does NOT change: the origin's `no-store` still reaches the browser,
# so a viewer never holds a stale manifest of its own even though the edge
# holds one for a second or two. That split is the whole trick of caching live
# HLS.
#
# ---------------------------------------------------------------------------
# THE MANIFEST/SEGMENT SPLIT, WHICH IS THE ONE THING TO GET RIGHT
# ---------------------------------------------------------------------------
# A live HLS playlist is rewritten every segment duration (ours: 6s target, five
# segments in the window, so about 30s of DVR). A segment, once published, is
# immutable forever. The two halves therefore want opposite TTLs, and mixing
# them up is what breaks playback:
#   - Cache a segment for a long time. Its URL is unique to it and never
#     changes. Verified 2026-09-10: two fetches of the same playlist returned
#     5 of 5 identical segment URLs, same presigned object, same signature, so
#     the cache key is stable rather than rotating per request.
#   - Cache a manifest for SECONDS. Two seconds still collapses a burst of
#     viewers arriving together, which is where the saving comes from, and
#     stays well inside the one-target-duration staleness hls.js tolerates.
#     Cache it for a segment duration or more and viewers stall on a playlist
#     that no longer lists the segments they need.
#
# ---------------------------------------------------------------------------
# WHAT IS DELIBERATELY NOT CACHED
# ---------------------------------------------------------------------------
# The library mp4s and the torrent-cache stream, for two independent reasons.
# Cloudflare's maximum cacheable object is 512 MB on this plan and a 2.5h race
# is roughly 9 GB, so the attempt could never succeed. And these are the paths
# people seek in, where a cache between the player and a Range request is a
# liability. `.mp4` IS on Cloudflare's default cached-extension list, so doing
# nothing here would not mean doing nothing: the bypass rule is what keeps the
# largest objects we serve out of the edge.
#
# RESIDUAL RISK, unchanged by anything in this file: Cloudflare returns a 206
# only when the origin sets Content-Length. A library mp4 is a real file and has
# one, so seeking survives. The ffmpeg fragmented-mp4 pipe does not, so a replay
# served that way loses seeking behind the tunnel. Convert-on-arrival means new
# arrivals become library mp4s, and the torrent cache measured empty (4 KB) on
# 2026-09-10, so nothing is served that way today.
#
# ---------------------------------------------------------------------------
# BEFORE CHANGING THIS FILE: a cloudflare_ruleset OWNS ITS WHOLE PHASE
# ---------------------------------------------------------------------------
# A zone has exactly one ruleset per phase and this resource manages that
# ruleset's complete `rules` list, so editing one rule re-sends all of them and
# anything added by hand in the dashboard is deleted, which Terraform reports as
# an ordinary in-place update. The same property nearly wiped the zone's custom
# firewall rules once (stacks/rybbit/crowdsec_edge.tf, detached with a
# `removed { lifecycle { destroy = false } }` block).
#
# Checked before the first apply on 2026-09-10 via GET /zones/<zone>/rulesets:
# five rulesets exist (normalization, managed free, ddos_l7, firewall_custom,
# firewall_managed) and NONE is in http_request_cache_settings, plus zero legacy
# Page Rules. So this created the phase rather than replacing anything. Re-run
# that check before editing.
#
# Rule ORDER matters: cache rules apply first-match, so the bypass sits ahead of
# the segment rule. Otherwise `/relay?…&download=x` and the library mp4s would
# fall into the long-TTL rule.

resource "cloudflare_ruleset" "f1_cache" {
  # Source of truth for the id is config.tfvars (cloudflare_zone_id); it is also
  # the default of ingress_factory's own var.cloudflare_zone_id.
  zone_id     = "fd2c5dd4efe8fe38958944e74d0ced6d"
  name        = "f1 video caching"
  description = "Edge-cache f1 HLS segments, second-level TTL on manifests, bypass the big mp4s. See stacks/f1-stream/cloudflare-cache.tf."
  kind        = "zone"
  phase       = "http_request_cache_settings"

  # 1. BYPASS what cannot or must not be cached. First, so it wins.
  rules {
    ref         = "f1_bypass_large_files"
    description = "Never cache the library mp4s or the torrent-cache stream"
    expression  = "(http.host eq \"f1.viktorbarzin.me\" and (starts_with(http.request.uri.path, \"/replays/cache/\") or ends_with(http.request.uri.path, \".mp4\")))"
    action      = "set_cache_settings"
    enabled     = true

    action_parameters {
      cache = false
    }
  }

  # 2. VOD ladder playlists: immutable, so cache them properly. This sits AHEAD
  #    of the second-level manifest rule because cache rules are first-match and
  #    a ladder playlist ends in .m3u8 like every other one, so without this it
  #    would fall into the 2-second rule meant for the LIVE manifest.
  #
  #    A replay ladder is written once by ffmpeg and never rewritten: the master
  #    and the four variant playlists are as immutable as the segments they list.
  #    Measured 2026-09-10 on 68fbb49285d3: a variant playlist is 42,281 bytes
  #    and lists 1,506 segments, so a 2-second TTL made every viewer re-pull all
  #    42 KB from the origin rather than revalidate it. Small against 1.4 GB of
  #    segments, but it is pure waste and the fix is one rule.
  #
  #    TTL RAISED FROM 86400 TO 31536000 (365 DAYS) ON 2026-09-11, and the same
  #    reasoning added the ladder-segment rule below it. 86400 meant a ladder was
  #    not paid for once, it was paid for again every viewing day, because a
  #    24-hour TTL expiring is a full re-pull rather than a revalidation.
  #
  #    Both halves of that were measured on 2026-09-11 rather than assumed:
  #      - The expiry is real, not theoretical. A ladder master fetched through
  #        the edge at 14:12 returned `cf-cache-status: EXPIRED` — a previously
  #        cached copy whose day was up, re-fetched from the origin.
  #      - The origin cannot revalidate. Against 10.0.20.203 directly, a ladder
  #        playlist ships `etag: "07d7c335684b7d901472083b148eccce"` and
  #        `last-modified: Thu, 10 Sep 2026 22:31:53 GMT`; re-requesting it with
  #        `If-None-Match` set to exactly that etag returns 200 with all 42,925
  #        bytes, and `If-Modified-Since` with exactly that timestamp does the
  #        same. A ladder segment behaves identically: 200 and all 420,180 bytes
  #        both ways. So an expiry costs the full object every time.
  #
  #    DEPENDENCY, deliberately recorded here: a separate change is teaching the
  #    origin to answer 304. This rule does not need that to help — a longer TTL
  #    means fewer expiries whatever the origin does — but the two together are
  #    what turn a daily cost into a one-off. If the 304 work lands and this
  #    value is later lowered, the daily re-pull returns at revalidation cost
  #    rather than full cost, which is a different trade, not the same one.
  #
  #    WHY 31536000 IS A VALUE THIS FREE ZONE ACCEPTS, checked rather than
  #    inferred from the legacy Page Rules ceiling (Free capped Edge Cache TTL
  #    at a month there, and that number does not govern Cache Rules).
  #    Cloudflare's own machine-readable API schema
  #    (github.com/cloudflare/api-schemas, openapi.json, fetched 2026-09-11)
  #    declares `rulesets_SetCacheSettingsEdgeTTL.default` as an integer with
  #    `minimum: 0` and NO maximum, and carries no per-plan bound anywhere. The
  #    one per-plan table Cloudflare publishes for Edge Cache TTL is a table of
  #    MINIMUMS (Free 2h, Pro 1h, Business/Enterprise 1s), and this zone already
  #    runs below its own listed minimum: the manifest rule below sets 2 seconds
  #    on Free and was measured working on 2026-09-10. So that table does not
  #    bind Cache Rules in either direction.
  #    THE APPLY ITSELF CANNOT FAIL ON THIS VALUE, checked with the provider
  #    rather than hoped for. `cloudflare_ruleset` on v4.52.9 declares
  #    `edge_ttl.default` as a plain optional `number` with no range validator
  #    (read out of `terraform providers schema -json`), and `terraform
  #    validate` on a rule of exactly this shape carrying 31536000 returns
  #    Success. That is the provider's own ValidateResourceConfig, so it runs
  #    without an API call or a plan.
  #    WHAT IS STILL UNVERIFIED: whether the EDGE silently clamps a value this
  #    large at serve time. Proving that needs a PUT, which is an apply, so it
  #    was not done. A clamp would be harmless, since it means a shorter TTL
  #    than asked for rather than an error. Two read-only probes against the
  #    live API confirmed the request shape is otherwise accepted and left the
  #    ruleset untouched (still version 2, same `last_updated`), but Cloudflare
  #    reports one error at a time so neither probe could isolate the TTL field.
  #
  #    EXCEPT master.m3u8, WHICH IS NO LONGER WRITTEN ONCE. Added 2026-09-11
  #    while landing this branch, because the change it lands beside made the
  #    premise above stop being true for one file. The origin now RENDERS
  #    master.m3u8 per request rather than sending ffmpeg's copy, so it can
  #    probe the stream-copied v0 rung and emit the `CODECS` attribute ffmpeg
  #    omits — which is what lets hls.js pick 1080p at all. Its bytes are
  #    therefore a function of our code, not of a file on disk.
  #
  #    That was measured going wrong within the hour. After the CODECS fix
  #    deployed, 104.21.3.16 served the 398-byte pre-fix master while the
  #    origin served the 429-byte one carrying `CODECS="avc1.4d402a,
  #    mp4a.40.2"`, under a `cf-cache-status: REVALIDATED`. A one-year TTL on
  #    that path does something worse than a stale revalidation: it stops
  #    asking the origin at all, so the next rendering fix would wait a year.
  #
  #    So master.m3u8 falls through to `f1_cache_manifests_briefly` below and
  #    takes its 2 seconds, which is the TTL that rule exists to give a
  #    playlist whose bytes can change. It costs nothing to hand it over: the
  #    file is 429 bytes, hls.js reads it once per session, and the origin now
  #    answers a conditional request for it with a 304 and no body. The 1,506
  #    variant playlists and their chunks are still written once by ffmpeg and
  #    still take the year.
  rules {
    ref         = "f1_cache_vod_ladder_playlists"
    description = "Replay ladder variant playlists: 1 year edge TTL, ffmpeg writes them once"
    expression  = "(http.host eq \"f1.viktorbarzin.me\" and starts_with(http.request.uri.path, \"/replays/library/hls/\") and ends_with(http.request.uri.path, \".m3u8\") and not (ends_with(http.request.uri.path, \"/master.m3u8\")))"
    action      = "set_cache_settings"
    enabled     = true

    action_parameters {
      cache = true

      edge_ttl {
        mode    = "override_origin"
        default = 31536000

        # Same reasoning as the segment rule below: never pin a failure for a
        # year, and on this path the failure is expected rather than unlucky —
        # a viewer who opens a replay mid-build asks for playlists that do not
        # exist yet.
        status_code_ttl {
          status_code_range {
            from = 400
            to   = 599
          }
          value = 10
        }
      }

      browser_ttl {
        mode = "respect_origin"
      }
    }
  }

  # 3. LADDER SEGMENTS: the same one-year TTL as the ladder playlists above, and
  #    for the same reason. This rule exists only because of ORDER: a ladder
  #    segment ends in `.ts`, so without it the request falls through to
  #    `f1_cache_segments` at the bottom of this ruleset and takes that rule's
  #    86400, which is the TTL a LIVE segment wants. For a live segment 24 hours
  #    is already generous, because the upstream window has moved on long
  #    before. A ladder rung is a file we wrote and still own, and it is far
  #    larger: 1,506 chunks per rung.
  #
  #    These objects cannot change. `ffmpeg` writes a rung once and the URL
  #    carries the torrent info-hash, so a different video is a different path.
  #    Verified on disk 2026-09-11: the layout is
  #    `<info-hash>.hls/v<rung>/s<NNNNN>.ts`, served as
  #    `/replays/library/hls/<info-hash>/v<rung>/s<NNNNN>.ts`, and nothing in
  #    the codebase rewrites a chunk once the build completes.
  #
  #    WHAT THIS SAVES, measured: a rung is 0.55-9.33 GB (v3 240p through v0
  #    1080p stream copy), 1,506 chunks each, and the origin answers conditional
  #    requests with 200 and the whole body (the exact measurement is in the
  #    playlist rule above). At 86400 that is the whole rung off the 32.0 Mbit/s
  #    home uplink again on every viewing day. At 31536000 it is once.
  #
  #    Sitting ahead of the manifest rule costs nothing: this rule requires
  #    `.ts` and that one matches `/proxy` or `.m3u8`, so the two are disjoint.
  #    It stays BEHIND `f1_bypass_large_files` deliberately — a ladder chunk is
  #    neither `/replays/cache/` nor `.mp4`, so the order is irrelevant there,
  #    and the bypass keeps the top slot this file asks it to keep.
  rules {
    ref         = "f1_cache_ladder_segments"
    description = "Replay ladder segments: 1 year edge TTL, written once by ffmpeg"
    expression  = "(http.host eq \"f1.viktorbarzin.me\" and starts_with(http.request.uri.path, \"/replays/library/hls/\") and ends_with(http.request.uri.path, \".ts\"))"
    action      = "set_cache_settings"
    enabled     = true

    action_parameters {
      cache = true

      edge_ttl {
        mode    = "override_origin"
        default = 31536000

        # The 400-599 guard matters MORE here than on any other rule, for the
        # reason `f1_cache_segments` records at length: a ladder takes about 17
        # minutes to build, and a viewer who opens a replay during that window
        # asks for chunks that do not exist yet. Without this their colo would
        # answer 404 for a YEAR rather than a day. Ten seconds recovers within
        # one playlist reload.
        status_code_ttl {
          status_code_range {
            from = 400
            to   = 599
          }
          value = 10
        }
      }

      browser_ttl {
        mode = "respect_origin"
      }
    }
  }

  # 4. Manifests: cached for SECONDS. Long enough to collapse a burst of viewers
  #    arriving together, short enough that nobody plays a stale playlist.
  #    Matches the live manifest by path (/proxy carries its target in the query
  #    string and has no extension) and every VOD playlist by extension.
  rules {
    ref         = "f1_cache_manifests_briefly"
    description = "HLS playlists: 2s edge TTL"
    expression  = "(http.host eq \"f1.viktorbarzin.me\" and (http.request.uri.path eq \"/proxy\" or ends_with(http.request.uri.path, \".m3u8\")))"
    action      = "set_cache_settings"
    enabled     = true

    action_parameters {
      cache = true

      edge_ttl {
        mode    = "override_origin"
        default = 2
      }

      # Leave the browser alone: the origin's no-store reaches it untouched, so
      # a viewer never holds a manifest of its own.
      browser_ttl {
        mode = "respect_origin"
      }
    }
  }

  # 5. Segments: immutable, so cache them properly. This is the rule that
  #    actually saves the upload — one origin fetch per segment however many
  #    people are watching.
  rules {
    ref         = "f1_cache_segments"
    description = "HLS segments: 1 day edge TTL, they are immutable"
    expression  = "(http.host eq \"f1.viktorbarzin.me\" and (http.request.uri.path eq \"/relay\" or ends_with(http.request.uri.path, \".ts\") or ends_with(http.request.uri.path, \".m4s\")))"
    action      = "set_cache_settings"
    enabled     = true

    action_parameters {
      cache = true

      edge_ttl {
        mode    = "override_origin"
        default = 86400

        # NEVER PIN A FAILURE FOR A DAY. `default` applies to every status this
        # rule caches, not just the good ones, so before this block a 404 on a
        # segment path was cached and re-served for 24 hours. Measured live on
        # 2026-09-10: a request for a segment that does not exist returned 404
        # MISS then 404 HIT from the edge.
        #
        # That is not hypothetical here. A ladder is built by a 40-minute ffmpeg
        # run, so a viewer who opens a replay mid-build asks for segments that do
        # not exist yet; without this, their colo would keep answering 404 for a
        # day after the segments appeared. The same applies to a transient 5xx
        # from the origin.
        #
        # Ten seconds still collapses a burst of bad requests, which is what the
        # per-app rate limiter is for anyway (200/s burst 2000 on X-Real-Ip), and
        # recovers within one playlist reload.
        status_code_ttl {
          status_code_range {
            from = 400
            to   = 599
          }
          value = 10
        }
      }

      browser_ttl {
        mode = "respect_origin"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# SMART TIERED CACHE. This setting is ZONE-WIDE, not f1-only.
# ---------------------------------------------------------------------------
# It lives in this file because the reasoning and the measurements that justify
# it are here, and f1 is the only workload that needed it. But it changes cache
# topology for every proxied hostname on viktorbarzin.me (115 of them as of
# 2026-09-10), so treat it as a zone setting that happens to be filed under the
# stack that asked for it. Grep `cloudflare_tiered_cache` before assuming a
# cache question is f1-scoped.
#
# WHY, measured on 2026-09-10 with seven independent viewers:
#   Six viewers pinned to Cloudflare anycast near home all landed in colo SOF
#   and took 28 HIT / 2 MISS across 30 segment fetches — the edge served them
#   and our origin was not touched.
#   One viewer routed through the cluster's UK VPN egress (194.35.235.160)
#   landed in colo LHR and took 5 MISS out of 5, pulling the full 16,742,528
#   bytes from our origin, even though SOF was already warm.
# Cloudflare's cache is per colo, so an audience spread across countries pays
# for one copy per colo. At 4.55 Mbit/s per live viewer against the measured
# 32.0 Mbit/s of origin egress, that turns a viewer count into a COLO count:
# roughly seven colos fills the line however few people are watching.
#
# Tiered Cache puts an upper tier between the edge and us. Cloudflare's docs:
# "only the upper-tier can ask the origin for content", which "concentrates
# connections to origin servers so they come from a small number of data
# centers rather than the full set of network locations". So a cold LHR fetches
# from the upper tier instead of from this house.
#
# FREE ON THIS PLAN. Cloudflare's availability table lists Tiered Cache and
# Smart Topology as available on Free, Pro, Business and Enterprise; only the
# Generic Global, Regional and Custom topologies are Enterprise-only. This is a
# supported feature used as designed, unlike the caching question above it.
#
# WHAT THIS DELIBERATELY DOES NOT TOUCH: `cloudflare_argo`. That resource
# bundles Argo Smart Routing, which is a PAID add-on, and declaring it risks
# enabling spend as a side effect of a free change. Verified 2026-09-10 that
# `GET /zones/<zone>/argo/smart_routing` answers "The request is not authorized
# to access this setting", i.e. it is structurally unavailable on Free, so this
# is belt-and-braces rather than the only guard.
#
# The trade: a distant viewer's FIRST request can be slightly slower, because a
# cold upper tier is an extra hop. That buys a large amount of upload back, and
# upload is the scarce resource here.
#
# VERIFIED AFTER APPLY, 2026-09-10, by re-running the London leg that had
# failed before it. Both zone settings read on afterwards
# (`argo/tiered_caching`, `cache/tiered_cache_smart_topology_enable`), and
# `argo/smart_routing` still answers "not authorized", so no spend was enabled.
#
# The run: purge five live segments, warm colo SOF from home, then fetch the
# same five through the UK VPN egress (194.35.235.160, colo LHR).
#
#   before  LHR 5 MISS / 5, and 16,742,528 bytes pulled from our origin
#   after   LHR 5 HIT  / 5, and ZERO bytes pulled from our origin
#
# Origin pulls were counted in the Traefik access log, keyed on a per-segment
# base64 slice AND on `ClientHost`, which carries `Cf-Connecting-Ip` and so
# attributes each pull to the viewer that caused it. Exactly 5 pulls, all
# 176.12.22.76 (the SOF warm), none from the UK address.
#
# TWO NEGATIVE CONTROLS, because "zero" is also what a broken query returns.
# Purge one segment and fetch it from LHR alone -> 1 pull, attributed to
# 194.35.235.160. Purge all five and fetch them concurrently from LHR -> 5
# pulls, all 194.35.235.160. So the counter does see UK-attributed pulls when
# they exist, and the zero above is real.
#
# Note for whoever re-runs this: `cf-cache-status` is reported by the LOWER
# tier, so a tiered-cache hit can legitimately read either HIT or MISS. The
# header is not the measurement. The origin pull count is.
#
# Note also that `homelab logs query` reaches Loki through the .lan ingress,
# which puts your own search string into the traefik stream you are searching.
# Port-forward Loki (`kubectl -n monitoring port-forward svc/loki 3100`) and
# query it directly, or you will count your own queries as origin pulls.
#
# PROVIDER NOTE: the attribute is `cache_type` on provider v4, which this repo
# pins (`~> 4`). It was renamed to `value` in v5, so a provider bump needs this
# line changed too.
resource "cloudflare_tiered_cache" "zone_smart" {
  zone_id    = "fd2c5dd4efe8fe38958944e74d0ced6d"
  cache_type = "smart"
}
