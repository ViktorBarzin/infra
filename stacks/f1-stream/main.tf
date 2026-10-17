variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }
variable "discord_f1_guild_id" { type = string }
variable "discord_f1_channel_ids" { type = string }

# Image tag for the Forgejo-registry image. The app lives in its own repo
# (viktor/f1-stream, extracted 2026-06-04). CI builds + pushes `latest` and
# `<short-sha>`, then drives the rollout via `kubectl set image`, so the
# running tag is managed outside Terraform (see CI_SETS_IMAGE below).
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
      # Opt out of the Kyverno-generated tier-4-aux quota (requests.memory
      # 3Gi); the namespace quota below replaces it. See that resource.
      "resource-governance/custom-quota" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Namespace quota, replacing the generated tier-4-aux one (opted out by the
# resource-governance/custom-quota label above). ADR-0029 in the f1-stream repo
# runs the app as three Roles: two Edges and a Transcoder that roll with a surge
# pod, and a Worker that is recreated. Memory requests at the peak of a rollout
# come to about 3.7Gi (three Edges at 384Mi, two Transcoders at 512Mi, the
# Worker at 1Gi, Anubis and wt-tracker at 320Mi, the source-guard Job at
# 256Mi; since 2026-10-16 also the Watcher at 256Mi, watcher.tf), over the
# generated quota's 3Gi. A surge pod over quota is refused by
# the ReplicaSet controller and the rollout stalls, which is the stall ADR-0029
# exists to remove. Only requests.memory moves; the other three values are the
# tier-4-aux defaults the generated quota set (live 2026-10-11: requests.cpu 2,
# limits.memory 16Gi, pods 20). Limits at the same peak come to about 13.7Gi.
resource "kubernetes_resource_quota_v1" "f1_stream" {
  metadata {
    name      = "f1-stream-quota"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "2"
      "requests.memory" = "6Gi"
      "limits.memory"   = "16Gi"
      pods              = "20"
    }
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

# The visitor and viewing record's database password (f1-stream ADR-0014), from
# the Vault database engine's static role `pg-f1-stream`.
#
# MOUNTED AS A FILE, NOT AN ENV VAR, and marked for Reloader to ignore. The
# Deployments below carry reloader.stakater.com/auto, so any Secret they
# reference by env would restart them on every rotation, at whatever time
# the rotation lands, and a restart during a session takes the stream away from
# everyone watching. Instead the app hands asyncpg a password callable that
# re-reads this file for each new connection, so a rotation reaches it through
# the kubelet's refresh of the mounted file and nothing restarts. The rotation
# itself is pinned to Tuesday in stacks/vault for the gap that remains before
# ESO's next refresh.
resource "kubernetes_manifest" "viewing_db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "f1-stream-viewing-db"
      namespace = "f1-stream"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "f1-stream-viewing-db"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/ignore" = "true"
            }
          }
          data = {
            password = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-f1-stream"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.f1-stream]
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

# The app's data volume from the ADR-0029 cutover on (f1-stream repo): replay
# library, Early copies, the TV app and the small JSON state files. ReadWriteMany
# because the Edges mount it read-only beside the Worker, which is the only Role
# that writes it.
#
# The directory the single pre-cutover Deployment used through a ReadWriteOnce
# claim (f1-stream-data-host, removed 2026-10-12 with its data left in place).
# An access mode cannot change on an existing claim, so this is a second static
# PV and claim onto /srv/nfs/f1-stream. The cutover first used a dynamic claim filled
# by a copy Job; the directory turned out to hold 46.7 GiB (46.5 GiB of it the
# replay library) and copied at about 5 MB/s, so on 2026-10-12 Viktor chose to
# point at the existing directory instead. The NFS CSIDriver has
# attachRequired: false, so the access mode is not enforced across nodes
# either way.
module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "f1-stream-data-shared"
  namespace  = kubernetes_namespace.f1-stream.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs/f1-stream"
  # Nominal on NFS, which enforces no size. REPLAY_LIBRARY_CAP_GB (180)
  # below is what bounds the library.
  storage            = "200Gi"
  access_modes       = ["ReadWriteMany"]
  storage_class_name = "nfs-pve"
}

# ---------------------------------------------------------------------------
# The app runs as three Roles from one image (ADR-0029 in the f1-stream repo,
# "Rollouts never stall a playing stream"). The ROLE env picks what a pod does:
#
#   f1-stream-edge        2 replicas, no GPU. The site, the API, /proxy,
#                         /relay and replays; the `f1` Service selects these.
#   f1-stream-transcoder  1 replica on the GPU. Live quality ladders; Edges
#                         start sessions through the f1-transcoder Service.
#   f1-stream-worker      1 replica on the GPU. Scheduler, extraction,
#                         scrapes, replay ladders and Early copies, and the
#                         only Role that writes /data.
#
# Before ADR-0029 this was one Deployment rolled with no surge. Two pods of
# that shape needed more gpumem than k8s-node1 had free, and its stream cache,
# token refresh and report-dead maps were per-process, so a second pod would
# have disagreed with the first. Every deploy took the site down for a cold
# start, which is why the deploy pipeline held off during sessions.
#
# The split removes both reasons. Edges hold no GPU seat and keep shared state
# in Redis, so they roll one at a time with a surge pod: the new Edge is Ready
# before an old one leaves, the old one drains (preStop sends SIGUSR1, which
# makes readiness 503 and closes keep-alives, then uvicorn's graceful shutdown
# lets in-flight responses finish), and the PDB keeps one serving through a
# node drain. The Transcoder also rolls with a surge pod (see the GPU seat note
# below) and hands its live sessions to the new pod in its preStop before it
# exits, so a ladder viewer keeps its picture. The Worker is Recreate: viewers
# keep playing from the Edges while it restarts, and only new extraction and
# replay work waits for it.
#
# ROLE unset means `all`, the monolith, so the same image still runs under a
# single Deployment; rolling this file back to that shape relies on it.
#
# GPU seats on k8s-node1 (advertises 15000 gpumem): 12148 declared on
# 2026-10-11, of which this namespace held 2848. Steady state with the split is
# Worker 2000 + Transcoder 1850 = 3850. On 2026-10-16 the node had 13950
# declared, the shared Android emulator's 800 among them, leaving 1050, so a
# Transcoder surge pod needing a second 1850 waited Pending for 27 minutes.
# Recreate was tried for a day (2026-10-16, de510086d) and cost transcoded
# viewers 25 to 60 s without a picture on every deploy.
#
# Since 2026-10-17 the emulator yields to deploys (Viktor's decision): the
# deploy pipeline (.woodpecker/deploy.yml in the f1-stream repo) scales the
# android-emulator Deployment to 0 and waits for its pod to leave before it
# rolls the Transcoder, and does not wake it again; the emulator's gate wakes
# it on the next visit. With the emulator asleep the node is at 13150, and the
# surge pod brings it to 15000, the whole budget, for the length of a
# handover. Any other new GPU tenant leaves the surge pod Pending; the old
# Transcoder keeps serving and the pipeline rolls the remaining Roles and
# fails the run.
#
# Two other things roll the Transcoder without that pipeline: Reloader, when
# f1-stream-secrets changes (its ExternalSecret refreshes hourly), and a
# Terraform apply that changes the pod template (this resource waits for the
# rollout, 10 minutes by default). For those the emulator's gate watches: the
# Transcoder pod carries the label android-emulator-yields-to=gpu-seat, and
# when such a pod waits Pending on Insufficient viktorbarzin.me/gpumem the
# gate scales the emulator to 0 within about 10 s and holds off waking it
# until the pod has scheduled (infra stacks/android-emulator/gate.py). The Worker is Recreate, so its seat never doubles. Shrinking
# the Transcoder seat so two fit without the emulator's 800 is not an option:
# the card peaked at 14494 MiB used in the week to 2026-10-16, and one
# monolith pod used up to 1809 MiB.
# ---------------------------------------------------------------------------

locals {
  f1_image = "ghcr.io/viktorbarzin/f1-stream:${var.image_tag}"

  # Plain env shared by the Edge and the Worker, which both run backend
  # features. Kept as an ORDERED LIST, never a map: Kubernetes expands $(VAR)
  # only against entries earlier in the list, and a map would sort by key. The
  # Transcoder reads none of these and has its own short list.
  f1_env_values = [
    # Early copies of HDR replays (app ADR-0024). Off in the app by default;
    # on here now that the Worker's gpumem declaration fits one.
    { name = "REPLAY_EARLY_HDR", value = "1" },
    # Member sign-in and the membership check (f1-stream ADR-0025, ADR-0021;
    # members.tf). The issuer and client id are public; the client secret and
    # the Authentik API token come from the Secret members.tf writes. Unset,
    # /login answers 503 and nothing else changes, so the image and this stack
    # can land in either order.
    { name = "OIDC_ISSUER", value = "https://authentik.viktorbarzin.me/application/o/${authentik_application.f1_stream.slug}/" },
    { name = "OIDC_CLIENT_ID", value = authentik_provider_oauth2.f1_stream.client_id },
    # MEMBER_GROUP is what images before ADR-0042 read; later ones read
    # MEMBER_GROUPS and approve Access requests into F1 Users by its pk.
    { name = "MEMBER_GROUP", value = data.authentik_group.home_users.name },
    { name = "MEMBER_GROUPS", value = "${data.authentik_group.home_users.name},${module.f1_users.group_name}" },
    { name = "F1_USERS_GROUP_ID", value = module.f1_users.group_id },
    { name = "DISCORD_CHANNELS", value = var.discord_f1_channel_ids },
    # Verifier connects to in-cluster headed Chromium pool — see
    # stacks/chrome-service/. Falls back to in-process headless if unset.
    # 2026-06-04: migrated WS (:3000 / path-token) → CDP (:9222 /
    # NetworkPolicy-gated). Token is no longer needed for the
    # connection itself; the chrome-service-client-secrets ExternalSecret
    # above stays in place because the snapshot endpoint (dev-box only,
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
    { name = "CHROME_CDP_URL", value = "http://chrome-service.chrome-service.svc.cluster.local:9222" },
    # The streamed extractor resolves embed pages by loading them in a
    # browser, and leases a worker from the fleet broker to do it rather
    # than holding the single chrome-service instance above for a whole
    # extraction run. Without this the extractor logs that the var is
    # unset and returns no streams, which is how it shipped on
    # 2026-09-06: registered, deployed, and quietly yielding nothing.
    # Note this is the BROKER, not a CDP endpoint — :8080 serves
    # /acquire and /release, and the worker's own podIP:9222 is what
    # gets dialled. See backend/chrome_fleet.py.
    { name = "CHROME_FLEET_URL", value = "http://chrome-fleet.chrome-service.svc.cluster.local:8080" },
    # Replay torrent streaming: qBittorrent does the fetching (auth is
    # bypassed for 10.0.0.0/8, so no credentials), we read the partial
    # file off the shared export.
    { name = "QBITTORRENT_URL", value = "http://qbittorrent.servarr.svc" },
    { name = "REPLAY_CACHE_DIR", value = "/replay-cache" },
    # qBittorrent's own view of the same directory, for savepath on add.
    { name = "REPLAY_CACHE_REMOTE_DIR", value = "/downloads/f1-replays" },
    { name = "REPLAY_CACHE_CAP_GB", value = "150" },
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
    { name = "REPLAY_LIBRARY_CAP_GB", value = "180" },
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
    { name = "P2P_TRACKERS", value = "wss://f1.viktorbarzin.me/tracker" },
    # STUN only, no TURN. A STUN server learns a candidate address and
    # carries no media, so this leaks less than the segment request that
    # follows it; TURN would relay the video itself and defeat the point.
    # Google's public STUN is used because it costs nothing and we do not
    # run one — if that ever matters, coturn in-cluster is the swap.
    { name = "P2P_STUN", value = "stun:stun.l.google.com:19302" },
    # Peer assist is OFF for live, on for replays, since 2026-09-18.
    #
    # It was never carrying live traffic worth the machinery. Measured
    # at the live edge over 16 samples, peers moved 0.1 KB against
    # 85.9 MB total, because a live viewer's neighbours are all inside
    # the same few seconds of the same playlist and have nothing the
    # CDN has not already sent. Replays are the opposite shape and keep
    # it, so the code stays and only the live path is gated.
    #
    # Set to 1 to put it back without a code change.
    { name = "P2P_LIVE", value = "0" },
    # The visitor and viewing record (app repo ADR-0014). The URL carries
    # no password: the app reads it from the mounted file below on every
    # new connection, which is what lets a rotation land without a
    # restart (see the ExternalSecret above). Unset or unreachable, the
    # app records nothing and serves exactly as before.
    { name = "VIEWING_DATABASE_URL", value = "postgresql://f1_stream@${var.postgresql_host}:5432/f1_stream" },
    { name = "VIEWING_DATABASE_PASSWORD_FILE", value = "/secrets/viewing-db/password" },
    # Where the daily job asks which other homelab hosts and Authentik
    # usernames a viewer's address used that week. One batched query a
    # day, never during a session.
    { name = "LOKI_URL", value = "http://loki.monitoring.svc.cluster.local:3100" },
    # User reports (app repo ADR-0038 to ADR-0040, build contract
    # docs/design/2026-10-16-user-reports-build-contract.md). The intake
    # job gathers Loki and Prometheus evidence, asks the f1-report-intake
    # agent in claude-agent-service for a verdict, and files the issue on
    # viktor/f1-stream as tv-feedback-bot. Mail goes From f1@, which the
    # mailserver's aliases.txt authorises for the spam@ login.
    { name = "PROMETHEUS_URL", value = "http://prometheus-server.monitoring.svc.cluster.local" },
    { name = "PUBLIC_BASE_URL", value = "https://f1.viktorbarzin.me" },
    { name = "REPORTS_FORGEJO_API", value = "https://forgejo.viktorbarzin.me/api/v1" },
    { name = "REPORTS_REPO", value = "viktor/f1-stream" },
    { name = "REPORTS_INTAKE_URL", value = "http://claude-agent-service.claude-agent.svc.cluster.local:8080" },
    { name = "REPORTS_NTFY_URL", value = "https://ntfy.viktorbarzin.me" },
    { name = "REPORTS_NTFY_TOPIC", value = "fixer" },
    { name = "REPORTS_SMTP_HOST", value = "mailserver.mailserver.svc.cluster.local" },
    { name = "REPORTS_SMTP_PORT", value = "587" },
    { name = "REPORTS_SMTP_USER", value = "spam@viktorbarzin.me" },
    { name = "REPORTS_SMTP_FROM", value = "f1@viktorbarzin.me" },
  ]

  # Secret-backed env shared by the Edge and the Worker.
  f1_env_secrets = [
    # Signs the admin session cookie, and the URLs and internal header the
    # Roles pass each other. Unset, the app issues and accepts nothing rather
    # than signing with a guessable key. The Transcoder sets it on its own.
    { name = "ADMIN_SESSION_KEY", secret = "f1-stream-secrets", key = "admin_session_key", optional = false },
    { name = "OIDC_CLIENT_SECRET", secret = kubernetes_secret.f1_members.metadata[0].name, key = "oidc_client_secret", optional = false },
    { name = "AUTHENTIK_API_TOKEN", secret = kubernetes_secret.f1_members.metadata[0].name, key = "authentik_api_token", optional = false },
    # Can add users to F1 Users and nothing else (members.tf, ADR-0042).
    { name = "AUTHENTIK_APPROVER_TOKEN", secret = kubernetes_secret.f1_members.metadata[0].name, key = "authentik_approver_token", optional = true },
    { name = "DISCORD_TOKEN", secret = "f1-stream-secrets", key = "discord_user_token", optional = false },
    # Announces a television taking a different build, to the same
    # #alerts webhook the source-guard already carries in this namespace.
    # optional=true so the pod starts before the guard's ExternalSecret
    # has synced; the app logs the line instead of posting it when unset.
    { name = "TV_SLACK_WEBHOOK", secret = "f1-stream-guard-secrets", key = "slack_webhook", optional = true },
    # Wanted sessions (app repo ADR-0015) post "ready" to #f1 through this
    # incoming webhook. It comes from the Vault "f1-stream" key through the
    # dataFrom.extract ExternalSecret above; optional=true so the pod
    # starts before the key exists, and the app skips the message.
    { name = "SLACK_F1_WEBHOOK_URL", secret = "f1-stream-secrets", key = "slack_f1_webhook_url", optional = true },
    # Session notifications (app repo ADR-0020) sign Web Push with this
    # VAPID identity, from the Vault "f1-stream" key through the same
    # dataFrom.extract ExternalSecret. optional=true: with any of the
    # three missing the app keeps notifications off and hides the bell.
    { name = "PUSH_VAPID_PRIVATE_KEY", secret = "f1-stream-secrets", key = "push_vapid_private_key", optional = true },
    { name = "PUSH_VAPID_PUBLIC_KEY", secret = "f1-stream-secrets", key = "push_vapid_public_key", optional = true },
    { name = "PUSH_VAPID_SUBJECT", secret = "f1-stream-secrets", key = "push_vapid_subject", optional = true },
    # Replays feature (app repo ADR-0002). optional=true so the pod still
    # starts before the Reddit app credentials exist; the app treats missing
    # creds as "replays off" (logs "Replays pipeline disabled"). The
    # ExternalSecret above uses dataFrom.extract on the Vault "f1-stream"
    # key, so adding reddit_client_id / reddit_client_secret there auto-syncs
    # them into this Secret — no ExternalSecret change needed, just a pod
    # restart to pick them up.
    { name = "REDDIT_CLIENT_ID", secret = "f1-stream-secrets", key = "reddit_client_id", optional = true },
    { name = "REDDIT_CLIENT_SECRET", secret = "f1-stream-secrets", key = "reddit_client_secret", optional = true },
    # User reports. All optional: each piece of the pipeline turns itself
    # off when its secret is missing, and reports are still stored.
    { name = "REPORTS_FORGEJO_TOKEN", secret = "f1-stream-secrets", key = "reports_forgejo_token", optional = true },
    { name = "REPORTS_WEBHOOK_SECRET", secret = "f1-stream-secrets", key = "reports_webhook_secret", optional = true },
    { name = "REPORTS_INTAKE_TOKEN", secret = "f1-stream-secrets", key = "reports_intake_token", optional = true },
    { name = "REPORTS_NTFY_TOKEN", secret = "f1-stream-secrets", key = "reports_ntfy_token", optional = true },
    { name = "REPORTS_SMTP_PASSWORD", secret = "f1-stream-secrets", key = "reports_smtp_password", optional = true },
  ]

  f1_namespace = kubernetes_namespace.f1-stream.metadata[0].name
  # In-cluster addresses the Roles use to reach each other.
  f1_edge_url       = "http://${kubernetes_service.f1-stream.metadata[0].name}.${local.f1_namespace}.svc.cluster.local"
  f1_worker_url     = "http://${kubernetes_service_v1.f1_worker.metadata[0].name}.${local.f1_namespace}.svc.cluster.local"
  f1_transcoder_url = "http://${kubernetes_service_v1.f1_transcoder.metadata[0].name}.${local.f1_namespace}.svc.cluster.local"
}

# Edge: the site, the API, /proxy, /relay and replays. Every viewer byte passes
# through an Edge, so this is the Role a rollout must not interrupt.
resource "kubernetes_deployment_v1" "f1_edge" {
  metadata {
    name      = "f1-stream-edge"
    namespace = local.f1_namespace
    labels = {
      app  = "f1-stream"
      role = "edge"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 2
    # A new Edge must be Ready, and stay Ready for 10s, before an old one is
    # taken out; with max_unavailable 0 two Edges serve throughout a rollout.
    min_ready_seconds = 10
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }
    selector {
      match_labels = {
        app  = "f1-stream"
        role = "edge"
      }
    }
    template {
      metadata {
        labels = {
          app  = "f1-stream"
          role = "edge"
        }
      }
      spec {
        # preStop 10s + uvicorn graceful shutdown 45s + about 10s of lifespan
        # shutdown + 5s margin. 45s is above Traefik's p99.9 request time of
        # 29s, so a TV's segment load in flight at SIGTERM finishes.
        termination_grace_period_seconds = 70
        # Its own account, so the Edge can list the f1-edge-peers
        # EndpointSlices (the Role below) to find the Ready Edges.
        service_account_name            = kubernetes_service_account_v1.f1_edge.metadata[0].name
        automount_service_account_token = true
        # The two Edges of one revision on different nodes, so losing a node
        # leaves one serving. A spread per revision (pod-template-hash) rather
        # than required anti-affinity: anti-affinity also counts the old
        # Edges that are draining, so a rollout would need a fourth untainted
        # node for its second surge pod, and only node2-5 qualify. Old and new
        # Edges may share a node for the length of a rollout.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "DoNotSchedule"
          match_label_keys   = ["pod-template-hash"]
          label_selector {
            match_labels = {
              app  = "f1-stream"
              role = "edge"
            }
          }
        }
        container {
          # deploy.yml in the f1-stream repo sets the image by this name.
          name  = "f1-stream"
          image = local.f1_image
          port {
            container_port = 8000
          }
          # No Edge-only process has been measured yet: the monolith's
          # 1.3-1.5 GiB working set included ffmpeg and extraction, which the
          # Edge does not run. 384Mi is a first guess and 1536Mi leaves room to
          # find out; revisit after a week of data. No CPU limit (Kyverno
          # strip-cpu-limits removes one at admission anyway) and no GPU.
          resources {
            requests = {
              cpu    = "100m"
              memory = "384Mi"
            }
            limits = {
              memory = "1536Mi"
            }
          }
          # Ready once one read of the shared stream cache in Redis has
          # answered (or, after 20s of failed reads, once /data's copy loads),
          # and latched after that, so a Redis blip cannot take both Edges out
          # of the Service at once. 503 while draining. Fast period and a short
          # failure count because the drain must leave the endpoints quickly.
          #
          # NO LIVENESS PROBE, as before the split. A liveness probe that
          # misfires kills a working pod. Measured over 30 days to
          # 2026-09-13, 177 distinct f1-stream pods reported a maximum
          # container restart count of 0, so a hung process is not a failure
          # this service has produced.
          readiness_probe {
            http_get {
              path = "/health/ready"
              port = 8000
            }
            initial_delay_seconds = 2
            period_seconds        = 2
            timeout_seconds       = 2
            failure_threshold     = 3
            success_threshold     = 1
          }
          lifecycle {
            pre_stop {
              # SIGUSR1 starts the app's drain: readiness answers 503 and
              # responses carry Connection: close, so Anubis's keep-alives
              # redial to another Edge. The sleep covers the endpoint
              # leaving kube-proxy and Traefik before SIGTERM.
              exec {
                command = ["/bin/sh", "-c", "kill -USR1 1; sleep 10"]
              }
            }
          }
          # This pod's own address, for the one env var below that cannot use
          # the Service. Declared BEFORE it, because Kubernetes expands
          # $(VAR) only against env entries that come earlier in the list.
          env {
            name = "POD_IP"
            value_from {
              field_ref {
                field_path = "status.podIP"
              }
            }
          }
          # The embed proxy (this pod's /embed?url=…) must be reachable from
          # the remote chrome-service pod. Default 127.0.0.1 only works for
          # in-process Chromium, so the remote browser needs a routable
          # address.
          #
          # The pod IP rather than the ClusterIP service, changed 2026-09-18
          # from the live streaming audit. Routing through
          # f1.f1-stream.svc.cluster.local closes a loop on every cold start:
          # the Service only carries endpoints for a READY pod, readiness is
          # /health/ready, and reaching ready involves the verification that
          # has to call back through this address. So the first verification
          # of a pod's life dials a Service that does not yet list it.
          # Measured 16 of 16 boots. The downward API address skips the
          # Service entirely and is reachable from the chrome-service pod the
          # moment the container has an IP.
          #
          # On the Edge since ADR-0029 because re-verify of watched streams
          # runs on one Edge at a time under a Redis lease.
          env {
            name  = "PLAYBACK_VERIFY_PROXY_BASE"
            value = "http://$(POD_IP):8000"
          }
          env {
            name  = "ROLE"
            value = "edge"
          }
          # Read by the uvicorn CLI (UVICORN_* env). See the grace period.
          env {
            name  = "UVICORN_TIMEOUT_GRACEFUL_SHUTDOWN"
            value = "45"
          }
          # Replay mutations, Early-copy playlists and the other routes that
          # start work or write /data are forwarded here.
          env {
            name  = "WORKER_URL"
            value = local.f1_worker_url
          }
          # Where an Edge asks for a live quality ladder. Reads of a running
          # session go to the owning Transcoder's pod IP from Redis.
          env {
            name  = "TRANSCODER_URL"
            value = local.f1_transcoder_url
          }
          # The base the Transcoder's ffmpeg reads the source through: the
          # in-cluster Edge Service rather than Cloudflare and Anubis, so a
          # read cut by an Edge drain reconnects to the other Edge.
          env {
            name  = "TRANSCODE_SOURCE_BASE"
            value = local.f1_edge_url
          }
          # Share-link thumbnails are a regenerable cache, so each Edge keeps
          # its own outside the read-only /data.
          env {
            name  = "SHARE_THUMBNAIL_DIR"
            value = "/tmp/share-thumbs"
          }
          # Proves to the app that a request came through the ingress rather
          # than straight at a pod. Straight from the random_password rather
          # than through f1-stream-secrets: the Middleware in ingress-proof.tf
          # reads the same resource, so there is nothing for Vault or an
          # ExternalSecret to add.
          #
          # Set on every Role, not only the Edges that the ingress reaches.
          # Unset, the app trusts Authentik headers from anything that can
          # reach it, and this namespace has no NetworkPolicy, so a Worker or
          # Transcoder without it would mint an admin session for any pod in
          # the cluster.
          env {
            name  = "INGRESS_PROOF_SECRET"
            value = random_password.ingress_proof.result
          }
          dynamic "env" {
            for_each = local.f1_env_values
            content {
              name  = env.value.name
              value = env.value.value
            }
          }
          dynamic "env" {
            for_each = local.f1_env_secrets
            content {
              name = env.value.name
              value_from {
                secret_key_ref {
                  name     = env.value.secret
                  key      = env.value.key
                  optional = env.value.optional
                }
              }
            }
          }
          # Last, so adding it appends to the env list rather than shifting it.
          # One upstream reader per Feed (ADR-0045 in the f1-stream repo).
          # Each upstream URL is owned by one Ready Edge, found through this
          # headless Service; the other Edge asks the owner on POD_IP:8000.
          env {
            name  = "EDGE_PEERS_DNS"
            value = "${kubernetes_service_v1.f1_edge_peers.metadata[0].name}.${kubernetes_namespace.f1-stream.metadata[0].name}.svc.cluster.local"
          }
          volume_mount {
            name       = "viewing-db"
            mount_path = "/secrets/viewing-db"
            read_only  = true
          }
          # Read-only: only the Worker writes /data (ADR-0029). A write from
          # an Edge fails with EROFS on its request path, which is how a
          # missed write shows up instead of two pods racing on one file.
          volume_mount {
            name       = "data"
            mount_path = "/data"
            read_only  = true
          }
          # Read-only: qBittorrent owns these files, we only stream them out.
          volume_mount {
            name       = "replay-cache"
            mount_path = "/replay-cache"
            read_only  = true
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
            read_only  = true
          }
        }
        # optional so the pod starts before the ExternalSecret has synced; the
        # app treats a missing password file as "record nothing".
        volume {
          name = "viewing-db"
          secret {
            secret_name = "f1-stream-viewing-db"
            optional    = true
          }
        }
        volume {
          name = "replay-cache"
          persistent_volume_claim {
            claim_name = module.nfs_replay_cache.claim_name
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
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                                          # CI_SETS_IMAGE: first-party image, deployed by its own CI
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

# Transcoder: live quality ladders on the GPU. Edges start a session through
# the f1-transcoder Service and read its playlist and segments from the owning
# pod's IP, which the session record in Redis names. Segments stay in this
# pod's memory, as before the split.
resource "kubernetes_deployment_v1" "f1_transcoder" {
  metadata {
    name      = "f1-stream-transcoder"
    namespace = local.f1_namespace
    labels = {
      app  = "f1-stream"
      role = "transcoder"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    # The surge pod takes a second 1850 gpumem seat for the length of a
    # handover, which needs the Android emulator asleep. The deploy pipeline
    # sleeps it first; for a roll from Reloader or Terraform, the emulator's
    # gate sleeps it when it sees the pod label below. See the GPU seat note
    # above the locals.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }
    selector {
      match_labels = {
        app  = "f1-stream"
        role = "transcoder"
      }
    }
    template {
      metadata {
        labels = {
          app  = "f1-stream"
          role = "transcoder"
          # The Android emulator's gate puts the emulator to sleep when a pod
          # with this label waits Pending for gpumem (infra
          # stacks/android-emulator/gate.tf, yield-watch Role).
          "android-emulator-yields-to" = "gpu-seat"
        }
      }
      spec {
        # The preStop handover is bounded at 75s, then uvicorn gets 10s, plus
        # lifespan shutdown and margin.
        termination_grace_period_seconds = 120
        # k8s-node1 carries nvidia.com/gpu=true:NoSchedule so only work that
        # wants the card lands there.
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        container {
          # deploy.yml in the f1-stream repo sets the image by this name.
          name  = "f1-stream"
          image = local.f1_image
          port {
            container_port = 8000
          }
          resources {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              # One GPU slice for NVDEC/NVENC. This pins the pod to k8s-node1.
              "nvidia.com/gpu" = "1"
              # GPU VRAM seat (ADR-0016). Live sessions measured 139-297 MiB
              # each for SDR sources, and TRANSCODE_MAX_SESSIONS is 2 (the warm
              # encoder takes one of those slots). A 2160p HDR live session is
              # inferred at about 1,800 MiB. Viktor chose (2026-10-12) to size
              # the seat for HDR live sessions rather than refuse them: 1850
              # here plus the Worker's 2000 fits the 5,700 this namespace can
              # hold during a surge exactly. If a parked GPU tenant comes back
              # first, the surge pod waits Pending and the old one keeps
              # serving. Measure an HDR session at cutover.
              "viktorbarzin.me/gpumem" = "1850"
              # Two encoders at about 360 MB RSS each, the app, and the 256Mi
              # memory emptyDir, which counts against this limit.
              memory = "2Gi"
            }
          }
          # Ready once Redis has answered and ffmpeg is on PATH; 503 while
          # draining. No liveness probe (see the Edge).
          readiness_probe {
            http_get {
              path = "/health/ready"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 12
            success_threshold     = 1
          }
          lifecycle {
            pre_stop {
              # Hands each live session to the new Transcoder and returns once
              # the new pod has caught up, or after 75s. It runs here rather
              # than on SIGTERM because uvicorn closes its listener at SIGTERM,
              # and the Edges keep reading this pod's IP until the handover.
              # An exec hook talks to localhost and adds no HTTP route that
              # Anubis, which passes every non-GET method, could reach.
              exec {
                command = ["python", "-m", "backend.transcode_handover", "--deadline", "75"]
              }
            }
          }
          # This pod's address and name, written into the Redis session records so
          # the Edges know which pod owns a session. Declared first, as on the Edge.
          env {
            name = "POD_IP"
            value_from {
              field_ref {
                field_path = "status.podIP"
              }
            }
          }
          env {
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }
          env {
            name  = "ROLE"
            value = "transcoder"
          }
          # Short: in-flight requests are segment reads, and the handover has
          # already run in the preStop hook.
          env {
            name  = "UVICORN_TIMEOUT_GRACEFUL_SHUTDOWN"
            value = "10"
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
          # HDR and 10-bit live sources are transcoded, as before the split;
          # the gpumem seat above is sized for them. Set 0 to refuse them
          # (503, and the client plays the source) if the seat must shrink.
          env {
            name  = "TRANSCODE_LIVE_HDR"
            value = "1"
          }
          # The warm encoder reads its source through an Edge; loopback no
          # longer reaches one.
          env {
            name  = "WARM_ENCODER_PROXY_BASE"
            value = local.f1_edge_url
          }
          # Signs the source URLs the warm encoder fetches and keys the header
          # the internal /internal/transcode routes require.
          env {
            name = "ADMIN_SESSION_KEY"
            value_from {
              secret_key_ref {
                name = "f1-stream-secrets"
                key  = "admin_session_key"
              }
            }
          }
          # On every Role; see the Edge.
          env {
            name  = "INGRESS_PROOF_SECRET"
            value = random_password.ingress_proof.result
          }
          volume_mount {
            name       = "transcode"
            mount_path = "/transcode"
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
        image_pull_secrets {
          name = "registry-credentials"
        }
        image_pull_secrets {
          name = "ghcr-credentials"
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                                          # CI_SETS_IMAGE: first-party image, deployed by its own CI
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

# Worker: scheduler, extraction, scrapes, replay ladders and Early copies, and
# the only Role that writes /data. A singleton: two would run every job twice.
resource "kubernetes_deployment_v1" "f1_worker" {
  metadata {
    name      = "f1-stream-worker"
    namespace = local.f1_namespace
    labels = {
      app  = "f1-stream"
      role = "worker"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    # Recreate, so the old Worker has stopped before the new one starts: no
    # two schedulers, no two writers of /data, and no second Worker gpumem seat,
    # which node1 does not have. Viewers keep playing from the Edges while it
    # restarts; the stream cache in Redis stays fresh through the Edge-leased
    # re-verify.
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app  = "f1-stream"
        role = "worker"
      }
    }
    template {
      metadata {
        labels = {
          app  = "f1-stream"
          role = "worker"
        }
      }
      spec {
        # uvicorn's 30s graceful shutdown plus lifespan shutdown and margin.
        termination_grace_period_seconds = 60
        # k8s-node1 carries nvidia.com/gpu=true:NoSchedule so only work that
        # wants the card lands there.
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        container {
          # deploy.yml in the f1-stream repo sets the image by this name.
          name  = "f1-stream"
          image = local.f1_image
          port {
            container_port = 8000
          }
          # Sizing history, carried over from the single Deployment, which ran
          # everything the Worker runs plus the live transcodes and serving.
          #
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
          # Raised 2026-08-23 for the server-side quality ladder, which is the
          # Transcoder's job since ADR-0029. Measured on the real stream, 30s of
          # video costs ~54s of CPU (~1.8 cores) and ~360MB RSS per encoder.
          #
          # No CPU limit: Kyverno's strip-cpu-limits removes one at admission.
          resources {
            limits = {
              # One GPU slice, for the replay ladders' NVDEC and the Early
              # copies' NVENC. This pins the pod to k8s-node1, so f1-stream
              # shares node1's fate. Accepted: every video path on the
              # hardware is worth more here than spreading the risk.
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
              #
              # RAISED to 2048 on 2026-09-26. Wanted sessions (app ADR-0015)
              # prefer the highest quality, so 4K HLG sources now reach the
              # ladder: NVDEC decoding 2160p 10-bit plus the encoders measured
              # 1707 MiB, and the watchdog recycled this pod at 18:03 in a
              # contention event. The node budget went 14000 -> 14200 first
              # (stacks/nvidia) so this fits. A 4K ladder plus two live
              # transcodes (1707 + 2 x 291 = 2289) can still exceed it; Viktor
              # accepted that over CPU decoding for HDR sources.
              #
              # RAISED to 2848 on 2026-10-10 for Early copies of 4K HDR replays
              # (app ADR-0024): one copy, NVDEC 2160p Main 10 + scale_cuda +
              # OpenCL tone-map + two NVENC rungs, measured 1782 MiB, and in a
              # test beside the pod's own encoders the watchdog recycled this
              # pod. 1782 + two live transcodes (2 x 291) + headroom ~= 2848.
              # The node budget went 14200 -> 15000 first (stacks/nvidia).
              # While a copy runs the card can drop under the watchdog floor,
              # and llama-swap (seatless) is then the one recycled; Viktor
              # chose this knowing that.
              #
              # LOWERED to 2000 when ADR-0029 moved the live transcodes (the
              # 2 x 291 above) to the Transcoder, so the Transcoder can take
              # 1850 and run HDR live sessions (Viktor, 2026-10-12). One Early
              # copy at 1782 fits; an Early copy beside a 4K ladder build
              # (1782 + 1707) never fit, at 2848 either.
              "viktorbarzin.me/gpumem" = "2000"
              # 2Gi -> 4Gi on 2026-09-27: a 4K HDR replay ladder build was
              # OOM-killed at 99% after ~4.5 h. Measured on a 2-minute excerpt,
              # the HDR ladder's ffmpeg alone peaks at 1405 MiB RSS, and it shares
              # this container with the app (7-day working-set peak 1532 MiB).
              memory = "4Gi"
            }
            requests = {
              cpu = "100m"
              # 384Mi -> 1Gi, closer to the measured 1.3-1.5 GiB working set.
              memory = "1Gi"
            }
          }
          # Ready once the scheduler has started and the stream store has
          # loaded (from Redis, or seeded from /data); 503 while draining. It
          # no longer waits for a first extraction, because the Edges keep
          # serving the cached streams meanwhile. 120 failures x 5s gives a
          # slow start ten minutes, the deploy pipeline's wait. No liveness
          # probe (see the Edge).
          readiness_probe {
            http_get {
              path = "/health/ready"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 120
            success_threshold     = 1
          }
          # This pod's own address, for the one env var below that cannot use
          # the Service. Declared BEFORE it, because Kubernetes expands
          # $(VAR) only against env entries that come earlier in the list.
          env {
            name = "POD_IP"
            value_from {
              field_ref {
                field_path = "status.podIP"
              }
            }
          }
          # The embed proxy (this pod's /embed?url=…) must be reachable from
          # the remote chrome-service pod. Default 127.0.0.1 only works for
          # in-process Chromium, so the remote browser needs a routable
          # address.
          #
          # The pod IP rather than the ClusterIP service, changed 2026-09-18
          # from the live streaming audit. Routing through
          # f1.f1-stream.svc.cluster.local closes a loop on every cold start:
          # the Service only carries endpoints for a READY pod, readiness is
          # /health/ready, and reaching ready involves the verification that
          # has to call back through this address. So the first verification
          # of a pod's life dials a Service that does not yet list it.
          # Measured 16 of 16 boots. The downward API address skips the
          # Service entirely and is reachable from the chrome-service pod the
          # moment the container has an IP.
          env {
            name  = "PLAYBACK_VERIFY_PROXY_BASE"
            value = "http://$(POD_IP):8000"
          }
          env {
            name  = "ROLE"
            value = "worker"
          }
          env {
            name  = "UVICORN_TIMEOUT_GRACEFUL_SHUTDOWN"
            value = "30"
          }
          # On every Role; see the Edge.
          env {
            name  = "INGRESS_PROOF_SECRET"
            value = random_password.ingress_proof.result
          }
          dynamic "env" {
            for_each = local.f1_env_values
            content {
              name  = env.value.name
              value = env.value.value
            }
          }
          dynamic "env" {
            for_each = local.f1_env_secrets
            content {
              name = env.value.name
              value_from {
                secret_key_ref {
                  name     = env.value.secret
                  key      = env.value.key
                  optional = env.value.optional
                }
              }
            }
          }
          volume_mount {
            name       = "viewing-db"
            mount_path = "/secrets/viewing-db"
            read_only  = true
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
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
          }
        }
        # optional so the pod starts before the ExternalSecret has synced; the
        # app treats a missing password file as "record nothing".
        volume {
          name = "viewing-db"
          secret {
            secret_name = "f1-stream-viewing-db"
            optional    = true
          }
        }
        volume {
          name = "replay-cache"
          persistent_volume_claim {
            claim_name = module.nfs_replay_cache.claim_name
          }
        }
        image_pull_secrets {
          name = "registry-credentials"
        }
        image_pull_secrets {
          name = "ghcr-credentials"
        }
      }
    }
  }
  # The first start after the cutover may seed the shared stream store from
  # /data and pull the image onto node1.
  timeouts {
    create = "20m"
    update = "20m"
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                                          # CI_SETS_IMAGE: first-party image, deployed by its own CI
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

# The public Service: Anubis, the /admin/login and /pair carve-out ingresses
# and the source-guard all address `f1`, and every one of them wants an Edge.
# The name stays; since ADR-0029 the selector picks Edges only.
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
      app  = "f1-stream"
      role = "edge"
    }
    port {
      port        = "80"
      target_port = "8000"
    }
  }
}

# The Ready Edges, for the Edges themselves (ADR-0045 in the f1-stream repo).
# Each Edge lists this Service's EndpointSlices through the Kubernetes API
# (the f1-stream-edge account and Role below), hashes an upstream URL over the
# Ready endpoints to find the one Edge that fetches it, and reads the URL
# itself if that Edge does not answer. A draining Edge leaves the slices as
# soon as its readiness turns 503. The DNS answer of this headless Service is
# only the Edges' fallback: cluster DNS served exited Edges for up to an hour
# on 2026-10-16, so an Edge also sets aside for 30 s any peer that does not
# answer or cannot prove it is an Edge.
resource "kubernetes_service_v1" "f1_edge_peers" {
  metadata {
    name      = "f1-edge-peers"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      app  = "f1-stream"
      role = "edge"
    }
  }

  spec {
    cluster_ip = "None"
    selector = {
      app  = "f1-stream"
      role = "edge"
    }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}

# The Edges' account: read-only on the EndpointSlices of this namespace, and
# nothing else, so an Edge can see which Edges are Ready (f1_edge_peers above).
resource "kubernetes_service_account_v1" "f1_edge" {
  metadata {
    name      = "f1-stream-edge"
    namespace = local.f1_namespace
  }
  automount_service_account_token = true
}

resource "kubernetes_role_v1" "f1_edge_peers_reader" {
  metadata {
    name      = "f1-edge-peers-reader"
    namespace = local.f1_namespace
  }
  rule {
    api_groups = ["discovery.k8s.io"]
    resources  = ["endpointslices"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "f1_edge_peers_reader" {
  metadata {
    name      = "f1-edge-peers-reader"
    namespace = local.f1_namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.f1_edge_peers_reader.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.f1_edge.metadata[0].name
    namespace = local.f1_namespace
  }
}

# Where Edges start a live quality ladder. Reads of a running session bypass
# this and go to the owning pod's IP.
resource "kubernetes_service_v1" "f1_transcoder" {
  metadata {
    name      = "f1-transcoder"
    namespace = local.f1_namespace
    labels = {
      app  = "f1-stream"
      role = "transcoder"
    }
  }
  spec {
    selector = {
      app  = "f1-stream"
      role = "transcoder"
    }
    port {
      port        = 80
      target_port = 8000
    }
  }
}

# Where Edges forward replay mutations and other Worker routes, and where the
# source-guard reads the extraction metrics.
resource "kubernetes_service_v1" "f1_worker" {
  metadata {
    name      = "f1-stream-worker"
    namespace = local.f1_namespace
    labels = {
      app  = "f1-stream"
      role = "worker"
    }
  }
  spec {
    selector = {
      app  = "f1-stream"
      role = "worker"
    }
    port {
      port        = 80
      target_port = 8000
    }
  }
}

# Keeps one Edge serving through voluntary disruptions such as a kured node
# drain. None for the Transcoder or the Worker: each is a single replica on
# k8s-node1, and a min_available 1 budget there would block every drain of
# node1 (stacks/claude-memory records that failure).
resource "kubernetes_pod_disruption_budget_v1" "f1_edge" {
  metadata {
    name      = "f1-stream-edge"
    namespace = local.f1_namespace
  }
  spec {
    min_available = "1"
    selector {
      match_labels = {
        app  = "f1-stream"
        role = "edge"
      }
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.f1-stream.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


# The per-site Anubis instance was folded into the shared one in
# stacks/turnstile-gate on 2026-10-16; see docs/plans/2026-10-16-turnstile-sitewide-design.md.

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

  # Same proof header /pair carries, for the same reason: forward-auth says who
  # a visitor is, not that they came through the front door. See
  # ingress-proof.tf.
  extra_middlewares = ["f1-stream-ingress-proof@kubernetescrd"]
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  auth   = "none" # Anubis-fronted; PoW challenge gates bots, no Authentik
  # CUT OVER 2026-09-10. "proxied" removes the explicit A and AAAA records, so
  # the host falls through to the zone-wide `*` CNAME into the cloudflared
  # tunnel (ADR-0021) and no per-name record is created. Reverting is the same
  # one line back to "non-proxied".
  #
  # Done for EDGE CACHING, not only to hide the origin: one live viewer costs
  # 4.55 Mbit/s against a measured 32.0 Mbit/s of origin egress through the
  # tunnel, so about seven concurrent origin pulls fill it. Because the edge
  # caches per colo, that is seven COLOS rather than seven people. The house
  # line itself is not the limit: 148.7 Mbit/s up, averaged over 696 speedtest
  # runs in the 30 days to 2026-09-19 (min 107, max 152). This comment used to
  # say 15.06 Mbit/s and three viewers; that came from one client pulling one
  # object at a time, which measures a single TCP stream and not the line.
  # cloudflare-cache.tf has the concurrent re-measurement and the reasoning,
  # along with the Cache Rules and the accepted terms risk. Rate limiting was already made tunnel-safe when the
  # share-link work landed: the shared `rate-limit` middleware has no
  # sourceCriterion and would key every viewer on the cloudflared pod, so f1
  # carries its own limiter keyed on X-Real-Ip (see below).
  dns_type  = "proxied"
  namespace = kubernetes_namespace.f1-stream.metadata[0].name
  name      = "f1"
  # Straight to the backend since the 2026-10-16 fold: the strict Turnstile gate
  # and the shared Anubis (stacks/turnstile-gate) do the bot check.
  service_name     = kubernetes_service.f1-stream.metadata[0].name
  port             = 80
  turnstile_strict = true
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
