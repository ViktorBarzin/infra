# WebTorrent tracker — WebRTC signalling for peer-assisted HLS delivery.
#
# WHAT IT IS AND IS NOT. This pod exchanges SDP offers and answers so two
# browsers watching the same stream can find each other. No video byte ever
# passes through it: the segments travel browser-to-browser over WebRTC data
# channels, and the manifests and any segment a peer does not hold still come
# from f1-stream itself. So nothing about what we serve leaves the cluster
# through this, which is the whole reason it is self-hosted rather than pointed
# at one of the public trackers — p2p-media-loader's own FAQ says not to use
# those in production, because they cap peers and reject connections under
# load, and every announce would tell a third party which swarm we are on.
#
# NOT ON THE CRITICAL PATH, and that is by design. p2p-media-loader falls back
# to plain HTTP whenever no peer holds a segment — its FAQ puts it as "should
# not perform worse than a player configured without P2P at all". A tracker
# that is down therefore costs upload bandwidth, not playback: viewers keep
# watching, each pulling from the origin as they did before peer-assist
# existed. Nothing here needs a PDB, a second replica or a page.

# ---------------------------------------------------------------------------
# THE IMAGE TAG IS THIS VARIABLE'S DEFAULT. The image does not exist yet.
# ---------------------------------------------------------------------------
# There is no maintained upstream container for any WebTorrent tracker.
# Checked 2026-09-08: Novage/wt-tracker (the one the design doc names) has no
# Dockerfile, no releases and no tags, and its npm package is stuck at 0.0.1
# from 2022 while the git repo moves; greatest-ape/aquatic ships a docker/
# directory you build yourself; webtorrent/bittorrent-tracker publishes to npm
# only. Docker Hub carries seven unofficial `*/wt-tracker` mirrors, all under
# 1.5k pulls with the newest `latest` from January 2024 and no provenance —
# deliberately not used.
#
# So this runs OUR image, built per ADR-0002 from `tracker/Dockerfile` in the
# f1-stream repo over `bittorrent-tracker` from npm (webtorrent-org, MIT,
# 11.2.3 published 2026-05-25). That package is the same WebTorrent-style
# signalling protocol p2p-media-loader v4 announces to, and it has the
# provenance the Novage repo lacks.
#
# ORDER OF OPERATIONS: the image must be pushed BEFORE this stack applies, or
# the pod sits in ImagePullBackOff until it appears. Nothing else breaks while
# it does — see "NOT ON THE CRITICAL PATH" above.
variable "wt_tracker_image_tag" {
  type    = string
  default = "latest"
}

resource "kubernetes_deployment" "wt_tracker" {
  metadata {
    name      = "wt-tracker"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      app  = "wt-tracker"
      tier = local.tiers.aux
      # Terraform owns the image on this Deployment, so declare that ownership
      # rather than leaving two controllers to fight over it. The namespace
      # carries `keel.sh/enrolled=true`, so Kyverno's add-keel-annotations rule
      # would otherwise stamp `keel.sh/policy=patch` here and Keel would re-pin
      # the tag on every poll while the next apply reverted it — the
      # image-ownership loop that replaced the proxy VPN gateway's pod six
      # times in thirty minutes on 2026-08-16. This label is what the companion
      # `keel-never-when-another-owner` rule selects on to set
      # `keel.sh/policy=never` instead.
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
  spec {
    # One replica, and more would be wrong rather than merely wasteful.
    # bittorrent-tracker keeps its swarm table in process memory, so two
    # replicas behind one Service would each know half the peers and hand out
    # half the introductions.
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "wt-tracker"
      }
    }
    template {
      metadata {
        labels = {
          app = "wt-tracker"
        }
      }
      spec {
        container {
          name              = "wt-tracker"
          image             = "ghcr.io/viktorbarzin/wt-tracker:${var.wt_tracker_image_tag}"
          image_pull_policy = "Always"

          # `--ws` alone: no HTTP announce endpoint and no UDP socket, because
          # browsers only ever speak the WebSocket flavour. The CLI treats "no
          # transport flag at all" as "start all three", so this flag is load
          # bearing rather than decorative — dropping it would open a UDP
          # BitTorrent tracker on this pod. bittorrent-tracker still creates an
          # HTTP listener in ws-only mode (server.js:100-118) purely to accept
          # the Upgrade, which is what the probes below talk to.
          #
          # `--interval 120000` (ms) is the announce interval handed back to
          # clients — two minutes, matching wt-tracker's own announceInterval
          # default of 120s. Announces after the first ride the open WebSocket,
          # so this cadence costs no new HTTP requests and never touches the
          # Traefik rate limiter.
          #
          # `--trust-proxy` makes the tracker read X-Forwarded-For for a peer's
          # address instead of seeing every viewer as a Traefik pod. It affects
          # what /stats.json reports and nothing that gates anything: WebRTC
          # peers connect on the ICE candidates inside the SDP, not on the
          # address the tracker recorded. An in-cluster client could forge the
          # header and appear as any address in the stats; accepted, since the
          # alternative is stats that are uniformly wrong.
          args = [
            "--ws",
            "--port", "8000",
            "--interval", "120000",
            "--trust-proxy",
          ]

          port {
            container_port = 8000
            name           = "http"
          }

          # Sized DOWN from the upstream claim on purpose. The wt-tracker
          # README reports up to 30,000 WebSocket-Secure peers on one vCPU and
          # 2 GiB (the design doc's figure is 20,000 on the same hardware);
          # bittorrent-tracker is the Node.js implementation of the same
          # protocol, so it is slower per peer but in the same shape. Our peak
          # is a race with a handful of viewers, and a swarm's whole per-peer
          # state is a socket plus an info-hash entry. 64Mi covers Node's own
          # floor of roughly 40-50Mi, and the 192Mi ceiling leaves room for
          # some hundreds of peers — about 20x anything plausible here and
          # about a tenth of what upstream asks for its 30,000.
          #
          # No CPU limit, per the cluster-wide convention (CFS throttling);
          # request only. Request below limit keeps this Burstable, which is
          # what tier 4-aux wants.
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "192Mi"
            }
          }

          # /stats.json is the tracker's own JSON status route and answers 200
          # once the listener is up. It is reachable from the kubelet and NOT
          # from the internet: Traefik forwards the ingress path unstripped, so
          # a public request arrives as /tracker/stats.json, the stats handler
          # compares req.url against the literal "/stats.json" and declines,
          # and the fallback handler answers 404 (server.js:207, :109-117).
          # That is the behaviour we want — peer counts are not public — so do
          # not add a strip-prefix middleware without re-checking this.
          readiness_probe {
            http_get {
              path = "/stats.json"
              port = 8000
            }
            initial_delay_seconds = 3
            period_seconds        = 10
            failure_threshold     = 3
          }
          liveness_probe {
            http_get {
              path = "/stats.json"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            failure_threshold     = 3
          }
        }
        # Private ghcr image (ADR-0002 off-infra builds) — cloned into this
        # namespace by the kyverno sync-ghcr-credentials allowlist policy.
        image_pull_secrets {
          name = "ghcr-credentials"
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "wt_tracker" {
  metadata {
    name      = "wt-tracker"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      app = "wt-tracker"
    }
    annotations = {
      # The tracker publishes no Prometheus exposition, so it gets an
      # Uptime Kuma internal monitor instead of a scrape target — this is the
      # opt-in annotation internal-monitor-sync reads. Setting `-path` also
      # narrows the accepted statuses to 200-299, which /stats.json satisfies.
      # No EXTERNAL monitor: the ingress is a path carve-out with
      # dns_type = "none", and an external probe of /tracker would 404 by
      # design (see the readiness-probe comment above).
      "uptime.viktorbarzin.me/internal-monitor"      = "true"
      "uptime.viktorbarzin.me/internal-monitor-name" = "F1 WebTorrent Tracker"
      "uptime.viktorbarzin.me/internal-monitor-path" = "/stats.json"
    }
  }
  spec {
    selector = {
      app = "wt-tracker"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

# Path carve-out on f1.viktorbarzin.me rather than a hostname of its own, so
# the announce URL is `wss://f1.viktorbarzin.me/tracker` — same origin as the
# page that opens it, no second DNS decision, and it follows f1 automatically
# through the Cloudflare cutover instead of needing its own flip.
#
# WHY IT MUST NOT GO THROUGH ANUBIS. The public f1 ingress points at
# `anubis-f1`; this one points at the tracker Service directly, which is the
# documented carve-out pattern (the same shape as ingress_admin_login above and
# chrome-service's /api/snapshot). A WebSocket client cannot solve a
# proof-of-work challenge, so routing the announce socket through the gate
# would break peer discovery outright. A longer path prefix wins in Traefik, so
# `/tracker` reaches here while `/` still reaches Anubis.
#
# The upgrade itself needs nothing special from Traefik: WebSockets work on the
# default chain, and `writeTimeout = 0` on the websecure entrypoint means a
# long-lived socket is never cut at a wall-clock mark (that zero is deliberate
# and documented — a finite value once truncated large downloads at 60s).
# `idleTimeout = 600s` is survived because the tracker sends an announce
# response every two minutes.
module "ingress_tracker" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": WebRTC signalling for browsers that have not authenticated
  # to anything — the site itself is public. There is nothing to read here: a
  # stranger announcing an info-hash we are not serving is introduced to
  # nobody, and /stats.json is not reachable on this path. Authentik would 302
  # the upgrade to a login page and break peer discovery for every viewer.
  auth = "none"
  # The public f1 ingress owns the DNS record and the uptime monitor for this
  # host; this is a path carve-out on the same name.
  dns_type         = "none"
  namespace        = kubernetes_namespace.f1-stream.metadata[0].name
  name             = "f1-tracker"
  host             = "f1"
  service_name     = kubernetes_service.wt_tracker.metadata[0].name
  port             = 80
  ingress_path     = ["/tracker"]
  tls_secret_name  = var.tls_secret_name
  homepage_enabled = false
  # The ai-bot-block and anti-ai-headers middlewares exist to discourage
  # scrapers from reading page content. There is no content here, and this
  # client IS a non-browser automated one by nature.
  anti_ai_scraping = false
  # ORDER IS LOAD-BEARING, and getting it wrong fails silently.
  # `traefik-f1-rate-limit` keys its bucket on the X-Real-Ip header, and
  # `real-ip` is the middleware that stamps it. ingress_factory auto-prepends
  # real-ip only for `anubis-*` backends, and this ingress deliberately points
  # at the bare tracker Service, so it has to be listed here BY HAND and
  # BEFORE the limiter. Reached without it, the oxy header extractor returns ""
  # for every request with no error at all, and every viewer on earth shares
  # one bucket again.
  skip_default_rate_limit = true
  extra_middlewares = [
    "traefik-real-ip@kubernetescrd",
    "traefik-f1-rate-limit@kubernetescrd",
  ]
}
