variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "discord_f1_guild_id" { type = string }
variable "discord_f1_channel_ids" { type = string }

# Image tag for the Forgejo-registry image. The app lives in its own repo
# (viktor/f1-stream, extracted 2026-06-04). CI builds + pushes `latest` and
# `<short-sha>`, then drives the rollout via `kubectl set image`. Keel stays
# enrolled as a redundant net, so the running tag is managed outside Terraform
# (see KEEL_IGNORE_IMAGE below).
variable "image_tag" {
  type    = string
  default = "latest"
}

resource "kubernetes_namespace" "f1-stream" {
  metadata {
    name = "f1-stream"
    labels = {
      "istio-injection" : "disabled"
      tier                                    = local.tiers.aux
      "chrome-service.viktorbarzin.me/client" = "true"
      "keel.sh/enrolled"                      = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "f1-stream-secrets"
      namespace = "f1-stream"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "f1-stream-secrets"
      }
      dataFrom = [{
        extract = {
          key = "f1-stream"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.f1-stream]
}

# Pull the chrome-service bearer token into this namespace as a separate
# Secret so the verifier can reach the in-cluster Playwright pool.
resource "kubernetes_manifest" "chrome_service_client_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "chrome-service-client-secrets"
      namespace = "f1-stream"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "chrome-service-client-secrets"
      }
      dataFrom = [{
        extract = {
          key = "chrome-service"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.f1-stream]
}

module "nfs_data_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "f1-stream-data-host"
  namespace          = kubernetes_namespace.f1-stream.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/f1-stream"
  storage            = "1Gi"
  access_modes       = ["ReadWriteOnce"]
  storage_class_name = "nfs-pve"
}

# Replay torrent cache. Shares the servarr qBittorrent downloads export so the
# backend can serve a file while qBittorrent is still writing it — a PVC cannot
# cross namespaces, so this is a second claim onto the same NFS path rather than
# a second copy of the data. Subdirectory of the export, so F1 replays stay
# separate from everything else servarr downloads.
module "nfs_replay_cache" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "f1-stream-replay-cache"
  namespace          = kubernetes_namespace.f1-stream.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/servarr/downloads/f1-replays"
  storage            = "200Gi"
  access_modes       = ["ReadWriteMany"]
  storage_class_name = "nfs-pve"
}

resource "kubernetes_deployment" "f1-stream" {
  metadata {
    name      = "f1-stream"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      app  = "f1-stream"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "f1-stream"
      }
    }
    template {
      metadata {
        labels = {
          app = "f1-stream"
        }
      }
      spec {
        container {
          image = "ghcr.io/viktorbarzin/f1-stream:${var.image_tag}"
          name  = "f1-stream"
          # Right-sized 2026-06-05: was 1Gi (bundled-Chromium era). The image is
          # now CDP-only (verifier drives the remote chrome-service), so actual
          # usage is ~116Mi and the VPA upperBound (incl. live races) is ~185Mi.
          # 256Mi = upperBound x ~1.3 (bursty); requests=limits per convention.
          #
          # Raised 2026-08-10 (384Mi -> 512Mi). The pod is TWO processes, and the
          # 2026-06 sizing only accounted for uvicorn. Playwright's bundled Node
          # driver is a second long-lived process that reached ~316MB while
          # uvicorn sat at ~61MB, i.e. ~377MB against a 384Mi ceiling -- about
          # 7MB of headroom, so any growth OOMKilled the pod (9 restarts on
          # 2026-08-10, exit 137, hourly). The driver leak itself is fixed in
          # f1-stream (independent page/context close + driver recycled every
          # PLAYBACK_VERIFY_RECYCLE_AFTER verifies), which should hold steady
          # state near ~200Mi; this ceiling is deliberately above the historical
          # ~377MB peak so a regression still shows up as an OOM rather than
          # being absorbed silently.
          #
          # Raised 2026-08-23 for the server-side quality ladder. Our providers
          # publish a single rendition (1280x720 at 50 fps, ~4.5 Mbps), so a
          # client on a mobile connection has nothing smaller to ask for; the
          # pod now re-encodes a 540p/360p ladder on demand. Measured on the
          # real stream, 30s of video costs ~54s of CPU (~1.8 cores) and ~360MB
          # RSS per encoder, and TRANSCODE_MAX_SESSIONS caps it at two at once.
          # The CPU limit is that ceiling plus room for uvicorn and the
          # Playwright driver; memory covers two encoders alongside the ~520MB
          # those two processes already use.
          #
          # Nothing is spent unless a client asks for lower quality: the
          # untouched source stays the default and starts no encoder.
          resources {
            limits = {
              cpu = "4"
              # One GPU, for NVENC. The live ladder encodes continuously for as
              # long as anyone is watching a reduced quality, which measured at
              # ~1.8 cores for two rungs; on the card that is close to free.
              # Replay ladders stay on the CPU on purpose - they are built once
              # and streamed many times, so their ~13% smaller output is worth
              # the one-off encode time.
              #
              # This pins the pod to k8s-node1, the only node with a card, so
              # f1-stream now shares node1's fate. Accepted: every video path
              # on the hardware is worth more here than spreading the risk.
              "nvidia.com/gpu" = "1"
              # GPU VRAM budget (ADR-0016), declared 2026-08-31 at 500 and
              # RAISED to 1200 on 2026-09-10. This pod ran with NO gpumem
              # declaration until 2026-08-31, so the gpu-vram-watchdog could
              # never see or recycle it and its usage did not count against the
              # seating chart.
              #
              # WHY 500 WAS UNDER, measured rather than estimated. 500 was sized
              # from a replay ladder ALONE, at 418 MiB. It missed that this pod
              # runs live transcode sessions from the same container, and
              # TRANSCODE_MAX_SESSIONS is 2, each its own ffmpeg process at a
              # measured 291 MiB. The worst legitimate total is therefore
              # 2 x 291 + 418 = 1000 MiB, twice the declaration, and it needs no
              # unusual event to be reached: someone watching live while a
              # ladder builds does it.
              #
              # Under-declaring is NOT the safe direction. The watchdog acts on
              # a tenant that is over its CONTRACT, so a pod that quietly
              # exceeds a too-small number becomes the recycle target during a
              # contention event it did not cause. The floor is crossed often
              # today: 84 contention events in the six hours to 2026-09-10, free
              # VRAM measured at 487-1067 MiB at trigger time. Every one of the
              # 84 recycled llama-swap, which is seatless and holds 6.6 GB; an
              # over-contract f1-stream would have been chosen ahead of it,
              # killing the live stream.
              #
              # 1200 leaves margin over the 1000 worst case. Declared total
              # across the card goes 12,300 -> 13,000 MiB against the node's
              # advertised 14k, so roughly 1,000 MiB stays unallocated.
              #
              # Sizing rule this cost us: size a VRAM declaration from every
              # process the container can run AT ONCE under its own configured
              # limits, not from the one workload you were thinking about.
              #
              # Sablier scale-to-zero was considered and NOT applied: this
              # ingress has traffic in 162 of the last 168 hours — a ~12/h floor
              # of monitors and bots hitting the Anubis challenge, on top of
              # race-day peaks of 339-1369/h — and the Sablier middleware would
              # sit in FRONT of Anubis, so that floor alone would hold the group
              # awake permanently. Parking it needs the bot floor addressed
              # first.
              "viktorbarzin.me/gpumem" = "1200"
              memory                   = "2Gi"
            }
            requests = {
              cpu    = "100m"
              memory = "384Mi"
            }
          }
          port {
            container_port = 8000
          }
          # Signs the admin session cookie. Unset, the app issues and accepts
          # nothing rather than signing with a guessable key.
          env {
            name = "ADMIN_SESSION_KEY"
            value_from {
              secret_key_ref {
                name = "f1-stream-secrets"
                key  = "admin_session_key"
              }
            }
          }
          env {
            name = "DISCORD_TOKEN"
            value_from {
              secret_key_ref {
                name = "f1-stream-secrets"
                key  = "discord_user_token"
              }
            }
          }
          env {
            name  = "DISCORD_CHANNELS"
            value = var.discord_f1_channel_ids
          }
          # Replays feature (app repo ADR-0002). optional=true so the pod still
          # starts before the Reddit app credentials exist; the app treats missing
          # creds as "replays off" (logs "Replays pipeline disabled"). The
          # ExternalSecret above uses dataFrom.extract on the Vault "f1-stream"
          # key, so adding reddit_client_id / reddit_client_secret there auto-syncs
          # them into this Secret — no ExternalSecret change needed, just a pod
          # restart to pick them up.
          env {
            name = "REDDIT_CLIENT_ID"
            value_from {
              secret_key_ref {
                name     = "f1-stream-secrets"
                key      = "reddit_client_id"
                optional = true
              }
            }
          }
          env {
            name = "REDDIT_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name     = "f1-stream-secrets"
                key      = "reddit_client_secret"
                optional = true
              }
            }
          }
          # Verifier connects to in-cluster headed Chromium pool — see
          # stacks/chrome-service/. Falls back to in-process headless if unset.
          # 2026-06-04: migrated WS (:3000 / path-token) → CDP (:9222 /
          # NetworkPolicy-gated). Token is no longer needed for the
          # connection itself; the chrome-service-client-secrets ExternalSecret
          # below stays in place because the snapshot endpoint (dev-box only,
          # not used by f1-stream) reuses the same Vault key.
          #
          # Deliberately NOT repointed at chrome-fleet, which docs/playback-guard.md
          # proposes as build step 2. Two things measured 2026-09-05 say that swap
          # would be a regression rather than a fix:
          #   - chrome-fleet:8080 is the lease broker, not a CDP endpoint. Its
          #     /json/version returns the FleetView HTML page, so
          #     connect_over_cdp() against it fails. Leasing is a code change
          #     (backend/chrome_fleet.py), not an env value.
          #   - the address below now answers. From this pod,
          #     chrome-service:9222/json/version returned 200 Chrome/147.0.7727.55.
          #     The connection-refused the design recorded was the neko container
          #     in that pod being taskless after a restart; the pod has since
          #     restarted again and reads 3/3 Running.
          # The guard CronJob does not set this var at all — it leases a worker
          # per run and injects that worker's URL directly. See f1-source-guard.tf.
          env {
            name  = "CHROME_CDP_URL"
            value = "http://chrome-service.chrome-service.svc.cluster.local:9222"
          }
          # The streamed extractor resolves embed pages by loading them in a
          # browser, and leases a worker from the fleet broker to do it rather
          # than holding the single chrome-service instance above for a whole
          # extraction run. Without this the extractor logs that the var is
          # unset and returns no streams, which is how it shipped on
          # 2026-09-06: registered, deployed, and quietly yielding nothing.
          # Note this is the BROKER, not a CDP endpoint — :8080 serves
          # /acquire and /release, and the worker's own podIP:9222 is what
          # gets dialled. See backend/chrome_fleet.py.
          env {
            name  = "CHROME_FLEET_URL"
            value = "http://chrome-fleet.chrome-service.svc.cluster.local:8080"
          }
          # The embed proxy (this pod's /embed?url=…) must be reachable from
          # the remote chrome-service pod. Default 127.0.0.1 only works for
          # in-process Chromium — for the remote browser we point it at our
          # own ClusterIP service.
          env {
            name  = "PLAYBACK_VERIFY_PROXY_BASE"
            value = "http://f1.f1-stream.svc.cluster.local"
          }
          # Replay torrent streaming: qBittorrent does the fetching (auth is
          # bypassed for 10.0.0.0/8, so no credentials), we read the partial
          # file off the shared export.
          env {
            name  = "QBITTORRENT_URL"
            value = "http://qbittorrent.servarr.svc"
          }
          env {
            name  = "REPLAY_CACHE_DIR"
            value = "/replay-cache"
          }
          # qBittorrent's own view of the same directory, for savepath on add.
          env {
            name  = "REPLAY_CACHE_REMOTE_DIR"
            value = "/downloads/f1-replays"
          }
          env {
            name  = "REPLAY_CACHE_CAP_GB"
            value = "150"
          }
          # The converted library's own ceiling, and a DIFFERENT thing from the
          # torrent cache above it: this one bounds `/data/replays-mp4`, the
          # seekable mp4s plus their HLS ladders, which is what a viewer plays
          # days after the torrent is gone.
          #
          # SET EXPLICITLY ON 2026-09-11. It was unset, so the cap was the code
          # default in backend/replays/library.py:617 — `int(os.getenv(
          # "REPLAY_LIBRARY_CAP_GB", "120")) * 1024**3`, i.e. 120 GiB. Note the
          # units: GiB, not GB, and `int()` rather than the `float()` the cache
          # cap above uses, so this value must stay a whole number.
          #
          # WHY 180 AND NOT THE 120 IT WAS, measured in-pod on 2026-09-11.
          # `/data/replays-mp4` holds 56,914,498,254 B (53.0 GiB) in three
          # sessions, and each session is its mp4 plus its ladder:
          #     68fbb492  9,082,285,192 + 12,159,955,298 = 21.24 GB (19.78 GiB)
          #     67e70279  7,282,644,360 + 10,562,067,486 = 17.84 GB (16.62 GiB)
          #     ed641a9a  7,275,450,051 + 10,552,091,230 = 17.83 GB (16.60 GiB)
          # A race weekend is FIVE sessions. Against the old 120 GiB cap only
          # 67.0 GiB was left, so a weekend needed 88.4 GiB at the mean session
          # size and 98.9 GiB at the largest, and BOTH exceed what was free.
          # The refusal was therefore not a corner case, it was the expected
          # outcome partway through the weekend — and the cap REFUSES rather
          # than evicting, so the symptom is a session that never arrives.
          # 180 GiB covers the resident 53.0 plus a worst-case weekend at 98.9
          # plus one more largest-session of slack (19.8) = 171.7, with a little
          # rounding room.
          # Honest limit on that arithmetic: all three held sessions are RACES,
          # so sizing practice and qualifying at a race's bitrate is pessimistic.
          # Pessimism is the cheap direction here, because the cost of being
          # wrong low is a silently missing session on a race weekend.
          #
          # WHY NOT SIMPLY HUGE. The volume behind this is shared, so the cap is
          # the only thing keeping f1 off everyone else's disk. Measured the
          # same day: `192.168.1.127:/srv/nfs/f1-stream` reports 4,327,881,048,064
          # B total and 904,448,180,224 B (842.3 GiB) available at 79% used, and
          # that pool is the `/srv/nfs` filesystem shared by 41 namespaces (40
          # besides this one, counted over the `nfs-pve` PVs). 180 GiB lets f1
          # grow by at most 127 GiB from today, which is 15% of the remaining
          # slack and leaves ~715 GiB for everyone else. Unbounded, f1 alone
          # would take the volume past the 95% where PVFillingUp pages.
          env {
            name  = "REPLAY_LIBRARY_CAP_GB"
            value = "180"
          }
          # Peer-assisted delivery. The backend injects these into the served
          # HTML shell as `window.__F1_CONFIG__` (backend/runtime_config.py),
          # rather than the frontend baking them at build time, because the
          # frontend is built once into the image while the tracker URL is
          # deployment config that follows the ingress.
          #
          # UNSET MEANS OFF, deliberately: p2pSettings treats a missing tracker
          # list as "peer-assist disabled", so a viewer then pulls every segment
          # over HTTP exactly as before. That keeps a feature which opens WebRTC
          # connections between viewers' browsers behind a single env var.
          #
          # The tracker is the in-cluster wt-tracker (see wt-tracker.tf), served
          # on this same host under /tracker, so it follows f1 through the
          # Cloudflare cutover with no second decision.
          env {
            name  = "P2P_TRACKERS"
            value = "wss://f1.viktorbarzin.me/tracker"
          }
          # STUN only, no TURN. A STUN server learns a candidate address and
          # carries no media, so this leaks less than the segment request that
          # follows it; TURN would relay the video itself and defeat the point.
          # Google's public STUN is used because it costs nothing and we do not
          # run one — if that ever matters, coturn in-cluster is the swap.
          env {
            name  = "P2P_STUN"
            value = "stun:stun.l.google.com:19302"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          # Read-only: qBittorrent owns these files, we only stream them out.
          volume_mount {
            name       = "replay-cache"
            mount_path = "/replay-cache"
            read_only  = true
          }
          env {
            name  = "TRANSCODE_DIR"
            value = "/transcode"
          }
          # Two encoders at ~1.8 cores each is the most this pod may spend.
          env {
            name  = "TRANSCODE_MAX_SESSIONS"
            value = "2"
          }
          volume_mount {
            name       = "transcode"
            mount_path = "/transcode"
          }
        }
        # k8s-node1 carries nvidia.com/gpu=true:NoSchedule so only work that
        # wants the card lands there. This pod now does.
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data_host.claim_name
          }
        }
        volume {
          name = "replay-cache"
          persistent_volume_claim {
            claim_name = module.nfs_replay_cache.claim_name
          }
        }
        # Encoder scratch. Six segments per rung is only a few MB, and it is
        # rewritten constantly — memory-backed keeps that churn off the shared
        # HDD (see the recurring IO-storm work) and guarantees it is discarded
        # with the pod. The size counts against the pod's memory limit.
        volume {
          name = "transcode"
          empty_dir {
            medium     = "Memory"
            size_limit = "256Mi"
          }
        }
        # Pull the (private) Forgejo-registry image. Kyverno syncs
        # registry-credentials into every namespace.
        image_pull_secrets {
          name = "registry-credentials"
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
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}


resource "kubernetes_service" "f1-stream" {
  metadata {
    name      = "f1"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      "app" = "f1-stream"
    }
  }

  spec {
    selector = {
      app = "f1-stream"
    }
    port {
      port        = "80"
      target_port = "8000"
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.f1-stream.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


# f1-stream serves its SvelteKit SPA via the FastAPI `/{path}` catch-all
# and exposes JSON/proxy routes at root (/schedule, /streams, /replays/events,
# /embed, /embed-asset, /relay, /proxy, /extract, /extractors, /health). A flat
# Anubis catch-all CHALLENGE breaks the SPA's XHRs with "Unexpected token
# '<', '<!doctype '" because the schedule fetch lands on the challenge HTML.
# Custom policy: ALLOW the known JSON routes + SvelteKit `_app/` assets
# (which load before any user has a chance to solve PoW), CHALLENGE
# everything else — the HTML pages.
module "anubis" {
  source           = "../../modules/kubernetes/anubis_instance"
  name             = "f1"
  namespace        = kubernetes_namespace.f1-stream.metadata[0].name
  target_url       = "http://${kubernetes_service.f1-stream.metadata[0].name}.${kubernetes_namespace.f1-stream.metadata[0].name}.svc.cluster.local"
  shared_store_url = "redis://redis-master.redis.svc.cluster.local:6379/6"
  # Rules only — the module owns the `bots:` key so it can always render the
  # trusted-local-networks ALLOW rule first (see modules/.../anubis_instance).
  policy_rules_yaml = <<-EOT
      - import: (data)/bots/_deny-pathological.yaml
      - import: (data)/bots/aggressive-brazilian-scrapers.yaml
      - import: (data)/meta/ai-block-aggressive.yaml
      - import: (data)/crawlers/_allow-good.yaml
      - import: (data)/clients/x-firefox-ai.yaml
      - import: (data)/common/keep-internet-working.yaml
      # SvelteKit immutable assets (CSS/JS chunks) and OpenAPI/health routes —
      # served pre-cookie, must pass without challenge.
      - name: f1-svelte-assets-and-meta
        path_regex: ^/(_app/|openapi\.json|docs|api/)
        action: ALLOW
      # Application JSON routes — XHR'd by the SPA after the user has solved
      # the PoW for `/`. We allow them unconditionally because the alternative
      # (carve-out per route via separate Ingress objects) is brittle and
      # because the data they expose (stream URLs, schedule metadata) is not
      # the AI-scraping target — the HTML/SPA is.
      # NB: `replays/events` (the Replays page's data XHR) MUST be listed too,
      # and `replays/library` alongside it — that one reports which sessions have
      # a converted, seekable copy, and is often the ONLY record that a session
      # is on disk, since the original release is released once its copy is
      # verified. Missing from this list, a cookie flap makes it answer with the
      # PoW page and every converted session looks absent.
      # `replays/refresh` joined them on 2026-09-06, when the Replays page's
      # Refresh button stopped merely re-reading the cache and started asking the
      # server to go and look. It is a POST rather than a GET, which changes
      # nothing here: Anubis matches on path, so without the entry the SPA's
      # fetch gets the challenge page back as 200 text/html and .json() throws
      # the same 'Unexpected token <' it throws for a missing GET route.
      # It was added after this rule; while missing, any request whose Anubis
      # cookie didn't validate (the IP-sensitive cookie flap) fell through to
      # catchall-challenge and got the PoW HTML back — so the SPA's res.json()
      # threw "Unexpected token '<', '<!doctype '" and the Replays refresh
      # "crashed". Only the `/replays` HTML *page* stays challenged (like /watch).
      # `admin/whoami` is the SPA's own XHR asking whether this browser holds
      # a session, and `admin/logout` ends one. Both must answer JSON: behind
      # the PoW challenge the probe would come back as HTML, res.json() would
      # throw, and a signed-in admin would render as an anonymous visitor.
      # `admin/login` is deliberately NOT here -- it is a top-level navigation
      # gated by Authentik on its own Ingress, and never reaches Anubis.
      - name: f1-data-routes
        path_regex: ^/(admin/whoami|admin/logout|embed|embed-asset|extract|extractors|health|proxy|relay|replays/cache|replays/events|replays/library|replays/refresh|schedule|streams)(/|\?|$)
        action: ALLOW
      # NOTE: /metrics is deliberately NOT allow-listed here. The Prometheus
      # scrape reaches the app Service directly at
      # f1.f1-stream.svc.cluster.local:80 and never passes through Anubis,
      # which fronts only the Ingress. An ALLOW rule would therefore buy the
      # scrape nothing and would publish per-source stream counts and
      # timestamps on the public hostname for no reason. If the exposition ever
      # needs to be reachable from outside the cluster, that is a deliberate
      # decision to take on its own rather than a side effect of adding a
      # scrape target.
      # Link previews for shared moments and party invites (design doc
      # 2026-09-08, "Crawler access"). Scoped to the three share shapes and
      # nothing else, so a spoofed preview user-agent earns one Open Graph page
      # and no more of the site:
      #   /s/<id>            share page — OG tags plus a visible fallback link
      #   /s/<id>/thumb.jpg  the ffmpeg frame grab at T (replays only)
      #   /p/<id>            party join page, same shape so a pasted party link
      #                      also previews
      # These are backend routes on purpose: `ssr = false` in
      # frontend/src/routes/+layout.js means the SvelteKit app cannot emit
      # og:title or og:image at all, so without an ALLOW here a preview bot
      # reaches the PoW interstitial and the paste renders as nothing.
      #
      # ONE `expression` RATHER THAN path_regex + user_agent_regex. That pairing
      # is the obvious shape and Anubis rejects it: v1.25.0 (the tag running
      # here) returns ErrBotMustHaveUserAgentOrPathNotBoth from
      # lib/config/config.go when a rule sets both, and one invalid rule fails
      # the WHOLE policy document — that takes f1 down rather than just losing
      # previews. A CEL `all:` block ANDs the same two conditions and validates.
      #
      # The CEL matcher is also the narrower one. Anubis's PathChecker tests the
      # client-supplied X-Original-URI header BEFORE r.URL.Path
      # (lib/policy/checker.go), so any `path_regex` ALLOW can be widened by a
      # client that sends `X-Original-URI: /s/aaaaaa` while requesting something
      # else entirely. The CEL `path` variable is r.URL.Path only
      # (lib/policy/celchecker.go, ResolveName), so this rule can only match the
      # path actually being served.
      #
      # `[.]` and not `\.` for the literal dot. The regex travels through a
      # Terraform heredoc, then YAML, then a CEL string literal, and `\.` is not
      # a valid CEL escape sequence. A character class means the pattern carries
      # zero backslashes and there is no escaping left to get wrong — please
      # leave it as a class.
      #
      # The anchors, the {6,64} bound and the charset are what keep this from
      # widening: without them the rule would ALLOW any two-segment path. Ids
      # are opaque base64url minted with `secrets`, which is the charset here.
      # Both trailing-slash forms match because the frontend sets
      # trailingSlash = 'always'.
      #
      # POSITION MATTERS — do not move this above the imports. Anubis takes the
      # first matching rule (lib/policy/policy.go), so with this rule here
      # `_deny-pathological` and `ai-block-aggressive` still DENY ClaudeBot,
      # GPTBot, Bytespider, PerplexityBot, meta-externalagent and the rest on
      # the share path as well. That ordering is the only reason the generic
      # `bot` substring is safe. What it does still admit is an undeclared SEO
      # crawler that already holds the link; it cannot find one by guessing, and
      # one OG page is all it gets.
      #
      # On the named agents: `whatsapp` covers Signal too, because Signal
      # fetches previews with `User-Agent: WhatsApp/2` (signalapp/Signal-Android
      # issue 13522 — deliberate, long-standing), so there is no separate Signal
      # token to match. `facebookexternalhit` is the Messenger / WhatsApp
      # desktop / Instagram preview fetcher and is listed; `meta-externalagent`
      # is Meta's AI crawler and is deliberately NOT, since ai-catchall above
      # denies it and should keep doing so. iMessage has no entry at all: its
      # fetcher sends a plain Safari user-agent and cannot be distinguished from
      # a person, so an iMessage paste falls through to the challenge. Nothing
      # here can fix that.
      - name: f1-share-link-previews
        action: ALLOW
        expression:
          all:
            # The charset includes ':' because a REPLAY share id is not an
            # opaque minted token: it is `<reddit_post_id>:<session_type>`
            # (e.g. `1abc2de:sprint_quali`), which is already durable, so those
            # links need no registry round trip. The frontend deliberately
            # decodes the colon back into the path (`shareLink.js` does
            # `encodeURIComponent(id).replace(/%3A/g, ':')`), so a charset
            # without ':' would miss EVERY replay preview while still matching
            # live ones — a silent half-failure. ':' is legal in a path segment
            # (RFC 3986 pchar). Kept minimal on purpose: no '.', which would
            # widen this toward dot-segments for no gain, and '-' stays last in
            # the class so it is a literal rather than a range.
            - 'path.matches("^/(s|p)/[A-Za-z0-9_:-]{6,64}(/thumb[.]jpg)?/?$")'
            - 'userAgent.matches("(?i)(bot|crawler|spider|preview|whatsapp|facebookexternalhit|facebookcatalog|telegram|discord|slack|twitter|skypeuripreview|linkedin|embedly|iframely|mastodon|vkshare)")'
      # Allow non-GET methods unconditionally — AI scrapers GET the body,
      # they don't POST. Mutating XHRs and CORS preflight need to bypass.
      - name: allow-non-get-methods
        action: ALLOW
        expression: method != "GET"
      - name: catchall-challenge
        path_regex: .*
        action: CHALLENGE
  EOT
}

# The single Authentik-gated path. Everything else on f1.viktorbarzin.me is
# public and Anubis-fronted; this one route exists so a browser can prove who it
# is once, by top-level navigation, which is the case forward-auth handles. The
# app reads X-authentik-groups here and nowhere else, and exchanges it for a
# cookie it signed itself.
#
# Same host as the public ingress, so a longer path prefix wins in Traefik and
# the session cookie lands on the origin the SPA is already using. Points at the
# app directly rather than through Anubis: a proof-of-work challenge in front of
# a login redirect would only get in the way, and Authentik is the stronger gate.
module "ingress_admin_login" {
  source       = "../../modules/kubernetes/ingress_factory"
  auth         = "required"
  host         = "f1"
  name         = "f1-admin-login"
  ingress_path = ["/admin/login"]
  namespace    = kubernetes_namespace.f1-stream.metadata[0].name
  service_name = kubernetes_service.f1-stream.metadata[0].name
  port         = 80
  # The public ingress owns the DNS record and the uptime monitor for this
  # host; this is a path carve-out on the same name.
  dns_type         = "none"
  homepage_enabled = false
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false
  # Members reach the login path. Home Server Admins and authentik Admins pass
  # regardless under ADR-0023's break-glass rule, which is who we want anyway;
  # the app checks the group again before issuing a session.
  allowed_groups = ["Home Server Admins"]
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  auth   = "none" # Anubis-fronted; PoW challenge gates bots, no Authentik
  # CUT OVER 2026-09-10. "proxied" removes the explicit A and AAAA records, so
  # the host falls through to the zone-wide `*` CNAME into the cloudflared
  # tunnel (ADR-0021) and no per-name record is created. Reverting is the same
  # one line back to "non-proxied".
  #
  # Done for EDGE CACHING, not only to hide the origin: the house has 15.06
  # Mbit/s of upload and one live viewer costs 4.55, so three concurrent
  # viewers fill the line. Cache Rules and the accepted terms risk are in
  # cloudflare-cache.tf. Rate limiting was already made tunnel-safe when the
  # share-link work landed: the shared `rate-limit` middleware has no
  # sourceCriterion and would key every viewer on the cloudflared pod, so f1
  # carries its own limiter keyed on X-Real-Ip (see below).
  dns_type     = "proxied"
  namespace    = kubernetes_namespace.f1-stream.metadata[0].name
  name         = "f1"
  service_name = module.anubis.service_name
  port         = module.anubis.service_port
  # real-ip (sets X-Real-Ip for Anubis's cookie) is auto-attached by
  # ingress_factory for anubis-* backends. f1 is non-proxied (pfSense
  # PROXY-protocol) so the peer is already the real client.
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false
  # Video rate limiting, not page-load rate limiting. The shared `rate-limit`
  # (10/s, burst 50) is detached and `traefik-f1-rate-limit` (200/s, burst
  # 2000, keyed on X-Real-Ip) attached in its place — the shared one has no
  # sourceCriterion, so behind the cloudflared tunnel every viewer on the site
  # shares ONE 10 req/s bucket keyed on the cloudflared pod, and HLS asks for a
  # segment every 4-6s per viewer. Full arithmetic and the ordering constraint
  # are in stacks/traefik/modules/traefik/middleware.tf next to the resource.
  # extra_middlewares are appended LAST by the factory, which is what puts this
  # after the auto-attached real-ip and guarantees X-Real-Ip is already
  # stamped when the limiter reads it.
  skip_default_rate_limit = true
  extra_middlewares = [
    "traefik-x402@kubernetescrd",
    "traefik-f1-rate-limit@kubernetescrd",
  ]
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "F1 Stream"
    "gethomepage.dev/description"  = "Formula 1 live streams"
    "gethomepage.dev/icon"         = "si-f1"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# CI retrigger v4 2026-05-16T14:13:59Z

# CI retrigger v5 2026-05-16T23:10:38Z

# CI retrigger v6 2026-05-16T23:18:58Z

# rightsizing reconcile 2026-06-29: re-trigger CI apply (memory limit committed in batch 2/3 but #427 was killed mid-apply; local apply blocked on stale backend-init).
