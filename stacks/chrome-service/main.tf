variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

locals {
  namespace = "chrome-service"
  labels = {
    app = "chrome-service"
  }
  # Pin to the same Playwright minor that the Python client requires.
  # If you bump this image, also bump `playwright==X.Y.Z` in callers'
  # requirements (currently f1-stream, snapshot-harvester) and re-run the
  # connect smoke test. Image ships chromium under /ms-playwright/.
  image = "mcr.microsoft.com/playwright:v1.48.0-noble"
  # Python image for the snapshot-harvester CronJob and the snapshot-server
  # sidecar (the latter just runs a 60-line stdlib HTTP server). Also carries
  # the cdp-bridge sidecar + turn-cred initContainer — reusing it there costs no
  # extra pull, since it is already resident for snapshot-server in this pod.
  python_image = "mcr.microsoft.com/playwright/python:v1.48.0-noble"
  snapshot_dir = "/profile/snapshots"

  # neko v3 (WebRTC H.264 + Opus) streams the master browser — the same display
  # stack the proxy per-user browsers use, replacing noVNC/x11vnc (design
  # docs/plans/2026-08-11-chrome-service-neko-display-design.md).
  #
  # The `google-chrome` variant, NOT `chromium`: real Google Chrome carries the
  # proprietary H.264/AAC codecs that Chromium builds compile out — the original
  # reason this stack moved off the bundled Playwright Chromium. Upstream image,
  # DIGEST-pinned per the house rule (`:latest` is served stale by the
  # pull-through cache). Bump deliberately on a neko upgrade.
  neko_image = "ghcr.io/m1k1o/neko/google-chrome:3.1.4@sha256:5511a426db00c474ff15e21fcdaa3887d737f9d379080a2cd5d05bea81872fce"
  # Virtual-desktop resolution. Matches the framebuffer the old Xvfb ran, and an
  # admin can change it live from the neko UI (screen-size menu → xrandr).
  # Software x264 at this size costs ~1.2 cores while a viewer is attached, ~0
  # idle; no GPU slice, so the pod keeps floating across node2-5.
  neko_screen = "1920x1080@30"
  # Fixed WebRTC media mux port, published DIRECTLY on its own MetalLB address
  # (see kubernetes_service.chrome_media). Viewers send media straight here, which
  # is what actually carries the stream — the coturn relay stays configured as a
  # fallback but cannot reach an external client today, because the ISP router in
  # front of pfSense forwards only UDP 3478 and not coturn's 49152-49252 relay
  # range (measured 2026-08-11).
  neko_udpmux = 59000
  # Dedicated MetalLB address for the media port. Must NOT be the shared .200:
  # ETP=Local (needed so the real client address survives) cannot coexist with the
  # shared IP's ETP=Cluster. Reachable from the LAN, the London WireGuard tunnel
  # and Headscale, all of which route 10.0.0.0/8.
  media_lb_ip = "10.0.20.206"
}

# --- Namespace ---

resource "kubernetes_namespace" "chrome_service" {
  metadata {
    name = local.namespace
    labels = {
      "istio-injection"                       = "disabled"
      tier                                    = local.tiers.aux
      "chrome-service.viktorbarzin.me/server" = "true"
      "keel.sh/enrolled"                      = "true"
      # Opt out of the Kyverno-generated tier-4-aux tier-quota (3Gi requests.memory
      # — far too small for the burst-6 worker pool). We define our own quota in
      # broker.tf (kubernetes_resource_quota.pool). The tier-4-aux LimitRange still
      # applies (max 4Gi/container, which all our containers respect).
      "resource-governance/custom-quota" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# --- Secrets (single-key extract: api_bearer_token) ---

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "chrome-service-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "chrome-service-secrets"
      }
      dataFrom = [{
        extract = {
          key = "chrome-service"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.chrome_service]
}

# coturn's use-auth-secret, synced from Vault secret/coturn. The turn-cred
# initContainer mints a per-pod-start ephemeral TURN-REST credential from it so
# neko can relay its WebRTC media through coturn (same relay the proxy browsers
# use). Reloader restarts the pod when this changes, which re-mints the cred.
resource "kubernetes_manifest" "es_turn" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "chrome-service-turn"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "chrome-service-turn"
      }
      data = [{
        secretKey = "turn_secret"
        remoteRef = { key = "coturn", property = "turn_secret" }
      }]
    }
  }
  depends_on = [kubernetes_namespace.chrome_service]
}

# tls-secret for the chrome.viktorbarzin.me ingress is auto-cloned into
# every namespace by Kyverno's `sync-tls-secret` ClusterPolicy — no local
# module call needed.

# --- Encrypted profile PVC ---
# Holds Chromium user data: cookies, localStorage, IndexedDB. Sites we
# drive may set auth tokens or session cookies — encrypted is correct.
resource "kubernetes_persistent_volume_claim" "profile_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "chrome-service-profile-encrypted"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "10Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

# --- NFS backup target ---
module "nfs_chrome_service_backup_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "chrome-service-backup-host"
  namespace          = kubernetes_namespace.chrome_service.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/chrome-service-backup"
  storage_class_name = "nfs-pve"
}

# --- Deployment ---

resource "kubernetes_deployment" "chrome_service" {
  metadata {
    name      = "chrome-service"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
      # Deliberate pin: the neko image is digest-pinned (local.neko_image) and
      # the sidecars track local.python_image, so a neko upgrade is a reviewed
      # bump rather than an automatic roll — a display regression here takes the
      # hand-login surface with it. The Keel opt-out is the annotation below.
    })
    annotations = {
      "reloader.stakater.com/auto" = "true"
      # Opt out of Keel. This was a LABEL in the merge above until 2026-08-17,
      # when the inject-keel-annotations exclude moved off labels onto this
      # annotation (a keel.sh/* label is drift — see
      # stacks/kyverno/modules/kyverno/keel-annotations.tf).
      #
      # `ignore_changes` below covers this key, so declaring it here does not
      # fight Kyverno on updates — but ignore_changes does not apply on CREATE,
      # so a recreated Deployment still comes up opted out. That matters: the
      # neko image is digest-pinned deliberately and an automatic roll would
      # take the hand-login surface with it.
      "keel.sh/policy" = "never"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        # Kyverno's `sync-registry-credentials` ClusterPolicy syncs this into
        # every namespace. All three images here are public (ghcr.io/m1k1o,
        # mcr.microsoft.com), so nothing in this pod needs it today — kept
        # because the pool workers in the same namespace pull a private image.
        image_pull_secrets {
          name = "registry-credentials"
        }
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # Fix profile dir ownership (PVC may have root-owned files from prior run)
        # and clear Chrome's stale profile singleton lock.
        #
        # The lock is a symlink Chrome writes as <hostname>-<pid>. A pod name
        # changes on every rollout, so the lock left behind by the previous pod
        # names a host Chrome cannot verify, and it refuses to start with "The
        # profile appears to be in use by another Google Chrome process on
        # another computer" — Chrome then never launches at all (observed
        # 2026-08-11: SingletonLock -> chrome-service-5786cb9b7f-b5p5w-1).
        # Removing them here is safe: these three files are per-instance lock
        # artifacts, never user data, and the Recreate strategy guarantees the
        # previous pod is gone before this one starts.
        init_container {
          name    = "fix-perms"
          image   = "busybox:1.37"
          command = ["sh", "-c", "chown -R 1000:1000 /profile && rm -f /profile/chromium-data/Singleton*"]
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "profile"
            mount_path = "/profile"
          }
          resources {
            requests = { memory = "32Mi" }
            limits   = { memory = "64Mi" }
          }
        }

        # Mint the ephemeral coturn TURN-REST credential neko relays its WebRTC
        # media through, and write the two ICE-server JSON documents to the
        # shared `ice` volume. neko takes ICE servers from env and env can't be
        # computed at pod start, so the neko container exports these files before
        # exec'ing supervisord. Re-minting every start means no long-lived
        # credential to rotate by hand. Logic + tests: files/turn_cred{,_test}.py.
        init_container {
          name              = "turn-cred"
          image             = local.python_image
          image_pull_policy = "IfNotPresent"
          command           = ["python3", "/scripts/turn_cred.py"]

          env {
            name = "TURN_SECRET"
            value_from {
              secret_key_ref {
                name = "chrome-service-turn"
                key  = "turn_secret"
              }
            }
          }
          # BACKEND: coturn's LB IP, reached direct in-cluster. FRONTEND + STUN:
          # coturn's public name, handed to the viewer's browser. coturn
          # advertises relay candidates on its external-ip (the WAN address)
          # either way, so LAN viewers hairpin — see the design doc's D7.
          env {
            name  = "COTURN_BACKEND_URL"
            value = "turn:10.0.20.205:3478"
          }
          env {
            name  = "COTURN_FRONTEND_URL"
            value = "turn:turn.viktorbarzin.me:3478"
          }
          env {
            name  = "COTURN_STUN_URL"
            value = "stun:turn.viktorbarzin.me:3478"
          }

          volume_mount {
            name       = "ice"
            mount_path = "/ice"
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "96Mi" }
          }
        }

        # neko v3 — the browser AND the display. neko owns Xorg, openbox,
        # PulseAudio and the H.264/Opus capture pipeline, and launches real
        # Google Chrome as its single app. This replaced the previous
        # [Chrome+Xvfb] + [x11vnc/websockify noVNC] pair on 2026-08-11 (design
        # docs/plans/2026-08-11-chrome-service-neko-display-design.md), which
        # also retires the two x11vnc gotchas documented in
        # docs/architecture/chrome-service.md (fd-table sweep, supervision).
        #
        # Chrome's flags are OURS, not upstream's: the neko-conf volume mounts
        # files/neko/google-chrome.conf over the image's supervisord program
        # file, keeping --user-data-dir=/profile/chromium-data and the anti-bot
        # flag set. See that file for the per-flag rationale.
        container {
          name              = "neko"
          image             = local.neko_image
          image_pull_policy = "IfNotPresent"

          # Runs as root like the proxy browsers do (verified working there):
          # neko's supervisord needs root to bring up Xorg/PulseAudio, then drops
          # to its own `neko` user (uid 1000) for Xorg, openbox and Chrome — the
          # same uid that owns the profile PVC, so no chown is involved. This
          # overrides the pod-level run_as_user = 1000, which would otherwise
          # leave supervisord unable to start the desktop.
          security_context {
            run_as_user = 0
          }

          # Two things the stock entrypoint can't do for us:
          #   1. ICE servers are only knowable at pod start (the turn-cred
          #      initContainer mints an ephemeral coturn credential), and neko
          #      reads them from env — so export them from the shared /ice files.
          #   2. The multiuser provider needs a user-role password as well as an
          #      admin one. A fresh random value per pod start makes the
          #      view-only role unusable by design: the Vault-held admin password
          #      is the only way in, and no second secret has to be managed.
          command = ["sh", "-c", <<-EOT
            set -e
            export NEKO_WEBRTC_ICESERVERS_BACKEND="$(cat /ice/backend.json)"
            export NEKO_WEBRTC_ICESERVERS_FRONTEND="$(cat /ice/frontend.json)"
            export NEKO_MEMBER_MULTIUSER_USER_PASSWORD="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
            exec /usr/bin/supervisord -c /etc/neko/supervisord.conf
            EOT
          ]

          env {
            name  = "NEKO_DESKTOP_SCREEN"
            value = local.neko_screen
          }
          # Authentik forward-auth on the ingress is the outer gate; this
          # password is the inner one, so a single misconfigured gate doesn't
          # expose a browser holding every logged-in cookie. Bookmark with
          # ?pwd=<value> to keep it one click.
          env {
            name = "NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = "chrome-service-secrets"
                key  = "neko_admin_password"
              }
            }
          }
          env {
            name  = "NEKO_MEMBER_PROVIDER"
            value = "multiuser"
          }
          # Single-owner browser: whoever connects gets control without having to
          # request it, and a dropped WebSocket resumes the same session.
          env {
            name  = "NEKO_SESSION_IMPLICIT_HOSTING"
            value = "true"
          }
          env {
            name  = "NEKO_SESSION_MERCIFUL_RECONNECT"
            value = "true"
          }
          env {
            name  = "NEKO_SERVER_BIND"
            value = "0.0.0.0:8080"
          }
          # Trust Traefik's forwarded headers (neko is always behind the ingress).
          env {
            name  = "NEKO_SERVER_PROXY"
            value = "true"
          }
          # Full ICE, not ice-lite: neko has to gather the coturn relay candidate
          # itself, since its host candidate is an unroutable pod IP.
          env {
            name  = "NEKO_WEBRTC_ICELITE"
            value = "false"
          }
          env {
            name  = "NEKO_WEBRTC_UDPMUX"
            value = tostring(local.neko_udpmux)
          }
          # Advertise the media LoadBalancer address as the ICE host candidate, so
          # viewers connect to the media port DIRECTLY and carry no dependency on
          # a relay. Anything that routes 10.0.0.0/8 — the LAN, the London
          # WireGuard tunnel, Headscale — reaches it.
          #
          # Why not the relay: coturn's relayed addresses are advertised on the WAN
          # address, and the ISP router in front of pfSense forwards only UDP 3478,
          # not the 49152-49252 relay range. Measured 2026-08-11 — pfSense's rdr
          # counter for that range does not move when an external host sends to a
          # relayed address, so the packet is dropped upstream of the firewall. No
          # relay-based candidate pair can complete from outside in either
          # direction until that forward exists, which is a change on the ISP
          # device rather than anything in this repo. Direct media needs none of
          # it. coturn stays in the ICE list as a fallback for the day it is fixed.
          #
          # Left UNSET this variable is actively harmful: neko then HTTP-GETs
          # checkip.amazonaws.com and advertises our WAN address as the host
          # candidate (nothing forwards 59000 either), and pion suppresses srflx
          # gathering once a 1:1 mapping exists — so the client is offered nothing
          # reachable and ICE sits at `checking` with the UI logged in and no video.
          env {
            name  = "NEKO_WEBRTC_NAT1TO1"
            value = local.media_lb_ip
          }
          # H.264, explicitly, with an explicit pipeline.
          #
          # The codec variable ALONE is not enough: with no pipeline set, neko
          # logs "no video pipelines specified, using default" and builds a VP8
          # pipeline (vp8enc, ~2 Mbps) regardless of the codec — verified live on
          # the first two rollouts. H.264 is what this display was sized and
          # chosen for: the ~25 fps @1080p / ~1.2 cores figure is a software x264
          # measurement, and a viewer's browser gets hardware H.264 decode far
          # more often than VP8.
          #
          # Software x264, mirroring the proxy's pipeline shape but with x264enc
          # in place of its GPU nvh264enc (verified present in this image as
          # libgstx264.so, with h264parse from libgstvideoparsersbad.so).
          # zerolatency + veryfast keep interactive latency and CPU down; 4 Mbps
          # suits 1080p30 (the proxy runs 8 Mbps at 1440p on hardware). The
          # element names matter — neko looks up `encoder` and `framerate` to
          # adjust bitrate and fps at runtime.
          env {
            name  = "NEKO_CAPTURE_VIDEO_CODEC"
            value = "h264"
          }
          env {
            name = "NEKO_CAPTURE_VIDEO_PIPELINE"
            value = join(" ", [
              "ximagesrc display-name={display} show-pointer=true use-damage=false",
              "! capsfilter caps=video/x-raw,framerate=30/1 name=framerate",
              "! videoconvert ! queue ! video/x-raw,format=I420",
              "! x264enc name=encoder threads=4 bitrate=4000 key-int-max=30",
              "byte-stream=true tune=zerolatency speed-preset=veryfast",
              "! h264parse config-interval=-1 ! video/x-h264,stream-format=byte-stream",
              "! appsink name=appsink",
            ])
          }
          # Fallback for a client that cannot establish WebRTC at all: JPEG over
          # HTTP. Upstream is explicit that it is high-latency and not a primary
          # stream — it fills exactly the role noVNC used to.
          env {
            name  = "NEKO_CAPTURE_SCREENCAST_ENABLED"
            value = "true"
          }
          env {
            name  = "NEKO_CAPTURE_SCREENCAST_RATE"
            value = "10/1"
          }
          env {
            name  = "NEKO_CAPTURE_SCREENCAST_QUALITY"
            value = "60"
          }

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }
          # Media mux. Viewers reach it through the coturn relay, so this needs
          # no Service port and no NetworkPolicy ingress rule — the relay traffic
          # rides the allocation neko opens outbound.
          port {
            name           = "media"
            container_port = local.neko_udpmux
            protocol       = "UDP"
          }

          # One probe, two failure modes. `/health` catches a dead neko server;
          # the CDP `/json/version` check catches the wedged-Chrome class that a
          # TCP probe misses (a wedged Chrome keeps its port open). Restarting
          # this container takes supervisord down with it, so Chrome comes back.
          liveness_probe {
            exec {
              command = ["sh", "-c",
                "curl -fsS --max-time 5 http://127.0.0.1:8080/health >/dev/null && curl -fsS --max-time 5 http://127.0.0.1:9223/json/version >/dev/null"
              ]
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 3
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          # Xorg + openbox + PulseAudio + Chrome is a longer boot than the bare
          # Chrome launch this replaced; 3 minutes of grace before liveness arms.
          startup_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            period_seconds    = 5
            failure_threshold = 36
          }

          volume_mount {
            name       = "profile"
            mount_path = "/profile"
          }
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }
          volume_mount {
            name       = "ice"
            mount_path = "/ice"
            read_only  = true
          }
          volume_mount {
            name       = "neko-conf"
            mount_path = "/etc/neko/supervisord/google-chrome.conf"
            sub_path   = "google-chrome.conf"
            read_only  = true
          }
          # Chrome managed policy. The stock image ships one tuned for a public
          # kiosk browser, and its DeveloperToolsAvailability=2 makes Chrome
          # refuse every per-page DevTools session (-32001) while still answering
          # browser-level CDP — which hangs connect_over_cdp for all five callers.
          # Ours is upstream's file with three values changed; see
          # files/neko/README.md for the diff and the evidence.
          volume_mount {
            name       = "neko-conf"
            mount_path = "/etc/opt/chrome/policies/managed/policies.json"
            sub_path   = "policies.json"
            read_only  = true
          }

          # CPU request covers the software x264 encoder while a viewer is
          # attached (~1.2 cores at 1080p, ~0 idle) — the old 200m request would
          # be squeezed under node contention and drop frames. No CPU limit, per
          # house policy. Memory keeps the previous 4Gi ceiling; the 1Gi
          # /dev/shm tmpfs counts against it.
          resources {
            requests = {
              cpu    = "1"
              memory = "3Gi"
            }
            limits = {
              memory = "4Gi"
            }
          }
        }

        # cdp-bridge sidecar — republishes Chrome's loopback CDP on the pod IP.
        # Stock Chrome ignores --remote-debugging-address and rejects non-local
        # Host headers, so files/cdp_bridge.py rewrites Host and forwards
        # 0.0.0.0:9222 → 127.0.0.1:9223. This used to run inside the browser
        # container; the neko image ships no python3, and the pod's shared netns
        # makes a sidecar equivalent. Callers keep hitting :9222 unchanged.
        container {
          name              = "cdp-bridge"
          image             = local.python_image
          image_pull_policy = "IfNotPresent"
          command           = ["python3", "/scripts/cdp_bridge.py"]

          port {
            name           = "cdp"
            container_port = 9222
            protocol       = "TCP"
          }
          # Readiness gates the chrome-service Service: no CDP caller is routed
          # here until the bridge can actually reach Chrome. Chrome's own health
          # is the neko container's liveness probe, not this one — restarting the
          # bridge would not clear a wedged browser.
          readiness_probe {
            tcp_socket { port = 9222 }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            tcp_socket { port = 9222 }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
        }

        # snapshot-server sidecar — serves the hourly storage-state.json
        # snapshot (written by the snapshot-harvester CronJob to the same
        # PVC) over an HTTP endpoint, bearer-gated by PW_TOKEN. Mounted
        # behind Traefik at chrome.viktorbarzin.me/api/snapshot with
        # auth=none; the bearer check inside this server is the gate.
        # Source: files/snapshot_server.py — 60 lines, stdlib only.
        container {
          name              = "snapshot-server"
          image             = local.python_image
          image_pull_policy = "IfNotPresent"
          command           = ["python3", "/scripts/snapshot_server.py"]

          env {
            name = "PW_TOKEN"
            value_from {
              secret_key_ref {
                name = "chrome-service-secrets"
                key  = "api_bearer_token"
              }
            }
          }
          env {
            name  = "SNAPSHOT_PATH"
            value = "${local.snapshot_dir}/storage-state.json"
          }
          env {
            name  = "PORT"
            value = "8088"
          }

          port {
            name           = "snap"
            container_port = 8088
            protocol       = "TCP"
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8088
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8088
            }
            initial_delay_seconds = 2
            period_seconds        = 10
          }

          volume_mount {
            name       = "profile"
            mount_path = "/profile"
            read_only  = true
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }

          resources {
            requests = { cpu = "5m", memory = "32Mi" }
            limits   = { memory = "96Mi" }
          }
        }

        volume {
          name = "profile"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.profile_encrypted.metadata[0].name
          }
        }
        volume {
          name = "dshm"
          empty_dir {
            medium = "Memory"
            # A `medium: Memory` emptyDir counts against the container memory
            # limit, so this 1Gi sits inside the neko container's 4Gi ceiling.
            size_limit = "1Gi"
          }
        }
        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map_v1.snapshot_scripts.metadata[0].name
            default_mode = "0555"
          }
        }
        # ICE-server JSON written by the turn-cred initContainer, read by neko.
        volume {
          name = "ice"
          empty_dir {}
        }
        # Our Chrome launch flags, mounted over neko's stock supervisord program
        # file for the browser (files/neko/google-chrome.conf).
        volume {
          name = "neko-conf"
          config_map {
            name = kubernetes_config_map_v1.neko_conf.metadata[0].name
          }
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
      # Every container image here is TF-managed and digest- or minor-pinned
      # (neko, and local.python_image for cdp-bridge + snapshot-server); none is
      # KEEL_IGNORE'd, so a stray clobber gets reverted on the next apply. Keel
      # is inert for this deployment anyway (keel.sh/policy=never) and no deploy
      # step touches it. The one exception is the busybox fix-perms initContainer
      # below, which Kyverno may restamp — init_container[0] is that one; keep it
      # first in the file so this index keeps pointing at it.
      spec[0].template[0].spec[0].init_container[0].image,
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

# --- ConfigMap: sidecar + harvester scripts ---
resource "kubernetes_config_map_v1" "snapshot_scripts" {
  metadata {
    name      = "snapshot-scripts"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = local.labels
  }
  data = {
    "snapshot_server.py"    = file("${path.module}/files/snapshot_server.py")
    "snapshot_harvester.py" = file("${path.module}/files/snapshot_harvester.py")
    # Tiny TCP forwarder used by chrome-service container to bridge
    # 0.0.0.0:9222 → 127.0.0.1:9223 (Chromium silently ignores
    # --remote-debugging-address on stock builds; see cdp_bridge.py).
    "cdp_bridge.py" = file("${path.module}/files/cdp_bridge.py")
    # Pool worker Chrome launcher (mounted into broker-created worker pods, which
    # also reuse cdp_bridge.py above). See files/broker/worker_pod.json.
    "worker_entrypoint.sh" = file("${path.module}/files/worker_entrypoint.sh")
    # Mints the ephemeral coturn credential + writes neko's ICE-server JSON at
    # pod start (turn-cred initContainer). Unit-tested: files/turn_cred_test.py.
    "turn_cred.py" = file("${path.module}/files/turn_cred.py")
  }
}

# --- ConfigMap: neko's Chrome launch flags + managed policy ---
# Both keys are mounted (subPath) over files the stock upstream image ships, which
# is how the master keeps chrome-service's own browser behaviour without a custom
# image or a fork: the supervisord program file carries our launch flags and the
# persistent profile path, and policies.json re-enables the DevTools and incognito
# that upstream's kiosk policy disables. Rationale + evidence:
# files/neko/README.md.
resource "kubernetes_config_map_v1" "neko_conf" {
  metadata {
    name      = "neko-conf"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = local.labels
  }
  data = {
    "google-chrome.conf" = file("${path.module}/files/neko/google-chrome.conf")
    "policies.json"      = file("${path.module}/files/neko/policies.json")
  }
}

# --- Services ---
# CDP endpoint (internal only, gated by NetworkPolicy). 2026-06-04: switched
# from Playwright WS (:3000) to direct chromium CDP (:9222) so the persistent
# user-data-dir actually persists cookies; callers use `connect_over_cdp()`.
resource "kubernetes_service" "chrome_service" {
  metadata {
    name      = "chrome-service"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = local.labels
  }

  spec {
    selector = local.labels
    port {
      name        = "cdp"
      port        = 9222
      target_port = 9222
      protocol    = "TCP"
    }
  }
}

# neko view — the UI + WebSocket signaling (Authentik-gated, via the ingress).
# WebRTC media does NOT pass through here; it relays via coturn.
resource "kubernetes_service" "chrome_view" {
  metadata {
    name      = "chrome"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = local.labels
  }

  spec {
    selector = local.labels
    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

# Renamed from chrome_novnc when neko replaced noVNC (2026-08-11). Without this
# Terraform would destroy+recreate the Service, changing its ClusterIP for no
# reason; the Service name on the wire is unchanged.
moved {
  from = kubernetes_service.chrome_novnc
  to   = kubernetes_service.chrome_view
}

# WebRTC media, published directly on its own MetalLB address.
#
# This is what carries the stream. The UI and signaling ride the Traefik ingress
# (TCP), but WebRTC media is UDP and cannot: neko advertises this address as its
# ICE host candidate (NEKO_WEBRTC_NAT1TO1), and any viewer that routes
# 10.0.0.0/8 — LAN, the London tunnel, Headscale — sends media straight here.
#
# ETP=Local so the viewer's real address survives; that also means only the node
# running this pod answers for the IP, which MetalLB handles by announcing from
# wherever the endpoint is. A dedicated IP is required either way, since ETP=Local
# cannot share an IP with the ETP=Cluster services on .200.
resource "kubernetes_service" "chrome_media" {
  metadata {
    name      = "chrome-media"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = local.labels
    annotations = {
      "metallb.io/loadBalancerIPs" = local.media_lb_ip
    }
  }

  lifecycle {
    # METALLB_LIFECYCLE_V1: MetalLB's controller writes this annotation on the
    # live object after it allocates an IP. Without the ignore, every apply
    # plans to strip it and MetalLB re-adds it — permanent drift.
    ignore_changes = [metadata[0].annotations["metallb.io/ip-allocated-from-pool"]]
  }
  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Local"
    selector                = local.labels
    port {
      name        = "media"
      port        = local.neko_udpmux
      target_port = local.neko_udpmux
      protocol    = "UDP"
    }
  }
}

# Snapshot-server endpoint (bearer-gated, exposed via ingress sub-path
# chrome.viktorbarzin.me/api/snapshot — auth=none at the ingress layer
# because the bearer check happens inside snapshot_server.py).
resource "kubernetes_service" "chrome_snapshot" {
  metadata {
    name      = "chrome-snapshot"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = local.labels
  }

  spec {
    selector = local.labels
    port {
      name        = "snap"
      port        = 8088
      target_port = 8088
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.chrome_service.metadata[0].name
  name            = "chrome"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  # ADR-0023: live shared-browser sessions — Chrome Users only (admins via bypass).
  allowed_groups = ["Chrome Users"]
  # neko serves its UI at / and the signaling WebSocket at /ws on the same host.
  ingress_path = ["/"]
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/name"        = "Chrome Service"
    "gethomepage.dev/description" = "Live neko WebRTC view of headed Chrome"
    "gethomepage.dev/icon"        = "chromium.png"
    "gethomepage.dev/group"       = "Infrastructure"
  }
}

# Second ingress on the same host (chrome.viktorbarzin.me) carving out
# /api/snapshot to the snapshot-server sidecar. Path-level carve-out
# pattern — see CLAUDE.md "For path-level carve-outs (e.g. wrongmove has
# `/` behind Anubis but `/api` direct), declare a second ingress_factory
# with `ingress_path = ["/<path>"]` pointing at the bare backend service."
module "ingress_snapshot" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": bearer-token gated inside snapshot-server.py; Authentik
  # forward-auth would require an OIDC cookie that the dev-box refresh
  # timer can't replay.
  auth            = "none"
  dns_type        = "none" # DNS already created by module.ingress
  namespace       = kubernetes_namespace.chrome_service.metadata[0].name
  name            = "chrome-snapshot"
  host            = "chrome"
  service_name    = kubernetes_service.chrome_snapshot.metadata[0].name
  port            = 8088
  ingress_path    = ["/api/snapshot"]
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}

# --- NetworkPolicy: scoped ingress.
# - TCP/9222 (Chromium CDP): only from labelled client namespaces.
# - TCP/8080 (neko UI + WS signaling): only from the traefik namespace (public
#   path is chrome.viktorbarzin.me → Traefik → neko; Authentik forward-auth
#   gates external access at the Traefik layer, and neko's own admin password
#   is the inner gate).
# - UDP/59000 (WebRTC media): from the LANs, remote-site tunnels and the tailnet
#   — the networks that can route to the media LoadBalancer IP.
# - TCP/8088 (snapshot-server): only from the traefik namespace
#   (chrome.viktorbarzin.me/api/snapshot → Traefik → sidecar; bearer token
#   is the gate inside snapshot-server.py).
# The cluster has no default-deny, so this NP only takes effect inside
# chrome-service ns — pods elsewhere remain unaffected.
resource "kubernetes_network_policy_v1" "ws_ingress" {
  metadata {
    name      = "chrome-service-ws-ingress"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "chrome-service.viktorbarzin.me/client" = "true"
          }
        }
      }
      # Explicit fallback list — admit f1-stream by name in case the label
      # is removed by accident. Keep this in sync with the labels above.
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "f1-stream"
          }
        }
      }
      # Also admit chrome-service's own namespace (the snapshot-harvester
      # CronJob runs here and needs to reach the CDP endpoint).
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "chrome-service"
          }
        }
      }
      ports {
        port     = "9222"
        protocol = "TCP"
      }
    }
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "traefik"
          }
        }
      }
      ports {
        port     = "8080"
        protocol = "TCP"
      }
      ports {
        port     = "8088"
        protocol = "TCP"
      }
    }
    # WebRTC media, straight from the viewer to the media LoadBalancer address.
    # ETP=Local preserves the real source, so this admits the networks that can
    # actually route to that IP: the homelab LANs, the remote-site tunnels
    # (London arrives as 192.168.8.x) and the Headscale tailnet. Deliberately not
    # 0.0.0.0/0 — an off-LAN viewer cannot reach this IP anyway.
    ingress {
      from {
        ip_block { cidr = "10.0.0.0/8" }
      }
      from {
        ip_block { cidr = "192.168.0.0/16" }
      }
      from {
        ip_block { cidr = "100.64.0.0/10" }
      }
      ports {
        port     = tostring(local.neko_udpmux)
        protocol = "UDP"
      }
    }
  }
}

# --- Backup CronJob: tar+gzip the profile every 6h, 30-day retention. ---
resource "kubernetes_cron_job_v1" "chrome_service_backup" {
  metadata {
    name      = "chrome-service-backup"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    schedule                      = "47 */6 * * *"
    starting_deadline_seconds     = 60
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            # PVC is RWO — colocate the backup pod with the chrome-service
            # pod so both can mount the volume on the same node.
            affinity {
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = local.labels
                  }
                  topology_key = "kubernetes.io/hostname"
                }
              }
            }
            container {
              name  = "backup"
              image = "docker.io/library/alpine:3.20"
              command = ["/bin/sh", "-c", <<-EOT
                set -euxo pipefail
                apk add --no-cache rsync
                ts=$(date +"%Y_%m_%d_%H")

                # Generations are plain directories, not tarballs, so rsync
                # --link-dest can hardlink the unchanged majority against the
                # previous run. A gzip blob cannot dedupe at all: every tarball
                # is fresh bytes even when the profile has barely moved, which
                # is how 4 runs a day for 30 days reached 51G.
                #
                # Names sort lexically, so the newest generation is the tail.
                # [0-9][0-9]* not [0-9]+ — BusyBox find uses POSIX BRE, where +
                # is a literal (the same trap fixed in mailserver on 2026-09-01).
                gens='.*/[0-9][0-9]*_[0-9][0-9]*_[0-9][0-9]*_[0-9][0-9]*$'
                prev=$(find /backup -maxdepth 1 -mindepth 1 -type d -regex "$gens" | sort | tail -1)
                link_dest_arg=""
                [ -n "$prev" ] && link_dest_arg="--link-dest=$prev"

                # Excluded paths are regenerable: browser and build caches, and
                # component/model stores Chrome re-downloads on demand. Measured
                # 2026-09-01, they were 82.8% of every tarball (655.5 MiB of
                # 792). What stays is the state that cannot be recreated —
                # Cookies, Login Data, Web Data, Preferences, Local State,
                # History, Local Storage, IndexedDB and Extensions.
                rsync -aH --delete $link_dest_arg \
                  --exclude='/.npm/' \
                  --exclude='/.cache/' \
                  --exclude='/lost+found/' \
                  --exclude='/chromium-data/Default/Cache/' \
                  --exclude='/chromium-data/Default/Code Cache/' \
                  --exclude='/chromium-data/Default/Service Worker/' \
                  --exclude='/chromium-data/Default/GPUCache/' \
                  --exclude='/chromium-data/Default/DawnCache/' \
                  --exclude='/chromium-data/Default/DawnGraphiteCache/' \
                  --exclude='/chromium-data/Default/GrShaderCache/' \
                  --exclude='/chromium-data/Default/ShaderCache/' \
                  --exclude='/chromium-data/GrShaderCache/' \
                  --exclude='/chromium-data/ShaderCache/' \
                  --exclude='/chromium-data/GraphiteDawnCache/' \
                  --exclude='/chromium-data/optimization_guide_model_store/' \
                  --exclude='/chromium-data/component_crx_cache/' \
                  --exclude='/chromium-data/extensions_crx_cache/' \
                  --exclude='/chromium-data/WidevineCdm/' \
                  --exclude='/chromium-data/WasmTtsEngine/' \
                  --exclude='/chromium-data/OnDeviceHeadSuggestModel/' \
                  --exclude='/chromium-data/SafeBrowsing/' \
                  --exclude='/chromium-data/Safe Browsing*' \
                  --exclude='BrowserMetrics*' \
                  /profile/ "/backup/$${ts}/"

                # Keep 120 generations = 30 days at 4 runs a day, matching the
                # window the old -mtime +30 tarball rule kept. Count-based
                # rather than -mtime because rsync -a stamps a generation
                # directory with the SOURCE mtime, so -mtime would not measure
                # when the backup was taken.
                find /backup -maxdepth 1 -mindepth 1 -type d -regex "$gens" | sort | head -n -120 | xargs -r rm -rf

                # Legacy tarballs from before 2026-09-01 age out on their
                # original 30-day rule; nothing is deleted early.
                find /backup -maxdepth 1 -type f -name '*.tar.gz' -mtime +30 -delete

                echo "Backup complete: $${ts} ($(du -sh /backup | cut -f1) total across $(find /backup -maxdepth 1 -mindepth 1 -type d -regex "$gens" | wc -l) generations)"
              EOT
              ]
              volume_mount {
                name       = "profile"
                mount_path = "/profile"
                read_only  = true
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "64Mi" }
              }
            }
            volume {
              name = "profile"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.profile_encrypted.metadata[0].name
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_chrome_service_backup_host.claim_name
              }
            }
            restart_policy = "OnFailure"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# --- Snapshot harvester CronJob: hourly storage_state() dump via CDP ---
# Connects to the live chrome-service CDP endpoint, accesses the
# persistent default browser context (where Viktor's noVNC logins live),
# and writes cookies + localStorage to /profile/snapshots/storage-state.json
# (atomic rename). The snapshot-server sidecar reads from the same file.
resource "kubernetes_cron_job_v1" "chrome_service_snapshot_harvester" {
  metadata {
    name      = "chrome-service-snapshot-harvester"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    # Hourly, offset from the backup CronJob (which runs at :47 every 6h)
    # so they don't fight for the encrypted PVC at the same minute.
    schedule                  = "23 * * * *"
    starting_deadline_seconds = 60
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            # PVC is RWO — colocate with the chrome-service pod.
            affinity {
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = local.labels
                  }
                  topology_key = "kubernetes.io/hostname"
                }
              }
            }
            container {
              name              = "harvester"
              image             = local.python_image
              image_pull_policy = "IfNotPresent"
              # The Microsoft playwright/python image ships only browsers +
              # Python — the `playwright` pip package itself is NOT installed
              # (it's meant for CI that brings its own requirements). We
              # install at startup, caching to the PVC so subsequent runs
              # are near-instant.
              command = ["bash", "-c"]
              args = [
                <<-EOT
                set -e
                export PIP_CACHE_DIR=/profile/.cache/pip
                export PIP_DISABLE_PIP_VERSION_CHECK=1
                python3 -c 'import playwright' 2>/dev/null \
                  || pip install --quiet --no-warn-script-location playwright==1.48.0
                exec python3 /scripts/snapshot_harvester.py
                EOT
              ]
              env {
                name  = "CDP_URL"
                value = "http://chrome-service.chrome-service.svc.cluster.local:9222"
              }
              env {
                name  = "SNAPSHOT_DIR"
                value = local.snapshot_dir
              }
              # Don't try to download browsers — connect_over_cdp doesn't
              # need them locally.
              env {
                name  = "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD"
                value = "1"
              }
              volume_mount {
                name       = "profile"
                mount_path = "/profile"
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              resources {
                requests = { cpu = "20m", memory = "128Mi" }
                limits   = { memory = "512Mi" }
              }
            }
            volume {
              name = "profile"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.profile_encrypted.metadata[0].name
              }
            }
            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map_v1.snapshot_scripts.metadata[0].name
                default_mode = "0555"
              }
            }
            restart_policy = "OnFailure"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
