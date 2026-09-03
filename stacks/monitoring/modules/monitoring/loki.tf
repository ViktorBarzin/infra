variable "nfs_server" { type = string }

# Loki + Alloy — re-enabled 2026-05-18 for wave 1 security audit logging
# (beads code-8ywc + code-146x). Original disable rationale was "operational
# overhead vs benefit after node2 incident" — re-evaluated because the wave 1
# detection layer (K8s audit, Vault audit, source-IP anomaly rules) needs Loki.
# Resource budget: SingleBinary mode, 2-4Gi memory, 50Gi proxmox-lvm PVC,
# 30-day retention, ruler enabled pointed at prometheus-alertmanager.
resource "helm_release" "loki" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "loki"

  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  # Pin to the deployed chart version (same rationale as the traefik pin):
  # unpinned, a refreshed helm repo index silently upgrades to the latest
  # chart on the next apply. Pinned 2026-07-06 while fixing the inert
  # `loki.ruler` values key (chart consumes `loki.rulerConfig`). Bump
  # deliberately, with values migration.
  version = "7.0.0"

  values  = [templatefile("${path.module}/loki.yaml", {})]
  timeout = 600

  depends_on = [kubernetes_config_map.loki_alert_rules]
}

resource "helm_release" "alloy" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "alloy"

  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"

  values  = [file("${path.module}/alloy.yaml")]
  atomic  = true
  timeout = 900 # 5-pod DS rolling update + occasional runc-stuck-Terminating on k8s-master needs >300s default

  depends_on = [helm_release.loki]
}

# inotify limits raised for Alloy pod log tailing (one watch per container).
resource "kubernetes_daemon_set_v1" "sysctl-inotify" {
  metadata {
    name      = "sysctl-inotify"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "sysctl-inotify"
    }
  }
  spec {
    selector {
      match_labels = {
        app = "sysctl-inotify"
      }
    }
    template {
      metadata {
        labels = {
          app = "sysctl-inotify"
        }
      }
      spec {
        init_container {
          name  = "sysctl"
          image = "busybox:1.37"
          command = [
            "sh", "-c",
            "sysctl -w fs.inotify.max_user_watches=1048576 && sysctl -w fs.inotify.max_user_instances=8192 && sysctl -w fs.inotify.max_queued_events=1048576"
          ]
          security_context {
            privileged = true
          }
        }
        container {
          name  = "pause"
          image = "registry.k8s.io/pause:3.10"
          resources {
            requests = {
              cpu    = "1m"
              memory = "4Mi"
            }
            limits = {
              cpu    = "1m"
              memory = "4Mi"
            }
          }
        }
        host_pid = true
        toleration {
          operator = "Exists"
        }
        dns_config {
          option {
            name  = "ndots"
            value = "2"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    # KEEL: monitoring ns is keel-enrolled — Keel owns the pause image tag and
    # injects keel.sh annotations. Ignore so TF stops reverting Keel each plan
    # (completes the cdb7d9a8 KEEL sweep that missed this daemonset and was
    # tripping drift-detection exit 2 every run). 2026-05-31.
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      metadata[0].labels["tier"],                                         # tier stamped live by tier-labeling; TF doesn't declare it here
    ]
  }
}

# resource "helm_release" "k8s-monitoring" {
#  namespace = kubernetes_namespace.monitoring.metadata[0].name
#   create_namespace = true
#   name             = "k8s-monitoring"

#   repository = "https://grafana.github.io/helm-charts"
#   chart      = "k8s-monitoring"

#   values = [templatefile("${path.module}/k8s-monitoring-values.yaml", {})]
#   atomic = true
# }

# 2026-06-28: trivial touch to re-trigger a clean `terragrunt apply monitoring`
# so TF state is persisted after CI pipeline #414 (the pfSense egress-monitoring
# apply, commit 7fe2d978) was cancel-raced by a newer push and SIGKILLed
# mid-helm-upgrade: the live resources applied but the state write + helm-release
# finalize were lost (the stuck pending-upgrade release was manually unstuck).
# See docs/runbooks/pfsense-egress.md and the Woodpecker cancel-previous gotcha.
resource "kubernetes_config_map" "loki_alert_rules" {
  metadata {
    name      = "loki-alert-rules"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "rules.yaml" = yamlencode({
      groups = [
        {
          name = "Node Health"
          rules = [
            {
              # Re-scoped 2026-07-27 (Viktor): fire ONLY on a REAL OOM — a
              # container/app OOM-kill OR a global node OOM — never on the
              # kured-sentinel-gate's benign memcg churn. On a pending-reboot
              # node the gate reaps its OWN (kubectl)/(bash) children ~14x/hr
              # against the gate's own cgroup limit (verified 2026-07-27: node5
              # at 83% free, ZERO containers OOMKilled cluster-wide, ~28 flap
              # msgs/6h). Excluding those two victim comms drops the gate to 0
              # (validated live) while still firing on any real process the
              # OOM-killer takes: a real container OOM (which also fires
              # ContainerOOMKilled) or a global node OOM (which only happens
              # when the node is at its memory limit). See memory #8811 / #10378.
              # Names the killed process. The old rule aggregated by node only,
              # so the alert said "killed a real container/app on k8s-node3"
              # and you had to go read the journal to learn what died. The
              # journal line is
              #   Memory cgroup out of memory: Killed process 3185742 (kubectl) \
              #   total-vm:... anon-rss:...
              # so `proc` comes straight out of the parenthesised comm field.
              #
              # The 5m window is widened to 2h because this alert fires per
              # OOM EVENT: with `for: 0m` it went firing -> resolved as soon as
              # the 5m lookback emptied, then fired again on the next kill.
              # Measured 2026-08-10: 21 fire/resolve pairs in 7 days = 42 Slack
              # posts, every firing duration <= 5m, driven by ONE leaking pod
              # (f1-stream, OOMKilled roughly hourly). A 2h window spans that
              # cadence so a repeating OOM loop reads as one continuous alert
              # and resolves 2h after the last kill.
              alert = "KernelOOMKiller"
              expr  = "sum by (node, proc) (count_over_time({job=\"node-journal\"} |~ \"(?i)Out of memory.*Killed process\" != \"(kubectl)\" != \"(bash)\" | regexp \"Killed process [0-9]+ \\\\((?P<proc>[^)]+)\\\\)\" [2h])) > 0"
              for   = "0m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary = "OOM killer killed {{ $labels.proc }} on {{ $labels.node }}"
              }
            },
            {
              # Contention signal for the gpu-vram-watchdog (ADR-0016,
              # docs/plans/2026-08-31-gpu-vram-admission-and-oom-observability.md).
              #
              # The tenants most likely to be starved of VRAM carry no gpumem
              # seat, so they never appear to the scheduler as Pending: llama-swap
              # declares no budget by design and fails inside an already-running
              # pod, and frigate's ffmpeg decoders fail the same way. Their only
              # externally visible symptom is a CUDA allocation error in the log.
              # The watchdog reads this alert from Alertmanager and treats an
              # ACTIVE instance as "somebody wants the card", which is what lets
              # it reclaim a ratcheted arena instead of waiting for free VRAM to
              # hit the emergency floor.
              #
              # Both spellings are matched deliberately: llama.cpp/ggml emits
              # "CUDA error: out of memory" while ffmpeg's CUDA hwcontext emits
              # "CUDA_ERROR_OUT_OF_MEMORY".
              #
              # 5m window: long enough that a load failure is still visible on
              # the watchdog's next tick, short enough that the signal clears
              # once the starvation is resolved rather than pinning the guard on.
              # It is a first estimate; tune from observed behaviour.
              alert = "GpuCudaOom"
              expr  = "sum by (namespace) (count_over_time({namespace=~\"llama-cpp|frigate|immich|tts|ytdlp|f1-stream|stremio|android-emulator\"} |~ \"CUDA_ERROR_OUT_OF_MEMORY|CUDA error: out of memory\" [5m])) > 0"
              for   = "0m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "CUDA out-of-memory reported by {{ $labels.namespace }} on the shared T4"
                description = "A GPU tenant could not allocate VRAM. The gpu-vram-watchdog uses this as its contention signal and will recycle the biggest over-budget tenant, so this normally self-heals within a minute or two. If it persists, either every tenant is within its declared gpumem budget (in which case the card is genuinely oversubscribed and the budgets need retuning) or the watchdog is not running (see GPUVRAMWatchdogDown)."
              }
            },
            {
              # The guard's interventions should be visible, not inferred from a
              # cold Immich search. The watchdog logs one line per recycle:
              #   CONTENTION (<reason>): recycling <ns>/<pod> (used=...) 
              # so this reports what it did and why. Expected cadence is low; a
              # steady stream means a budget is set below a tenant's real
              # working set and should be retuned rather than enforced harder.
              alert = "GpuVramWatchdogRecycled"
              expr  = "sum by (reason) (count_over_time({namespace=\"nvidia\", app=\"gpu-vram-watchdog\"} |~ \"CONTENTION\" != \"DRY_RUN\" | regexp \"CONTENTION \\\\((?P<reason>[^)]+)\\\\)\" [15m])) > 0"
              for   = "0m"
              labels = {
                severity = "info"
              }
              annotations = {
                summary     = "gpu-vram-watchdog reclaimed VRAM ({{ $labels.reason }})"
                description = "The watchdog recycled an over-budget GPU tenant because something else needed the card. Immich smart search and face recognition are unavailable for roughly 2.5 minutes after an immich-ml recycle. Check the watchdog log for which pod and by how much it was over."
              }
            },
            {
              # llama-swap holds no gpumem seat by design, so a starved model
              # load produces no Pending pod and no scheduler event. Without
              # this, paperless-ai simply gets 500s and nothing says why.
              # llama.cpp logs "starting <model> failed: upstream command exited
              # prematurely" whichever way the load fails, so this covers VRAM
              # starvation and non-VRAM causes (bad GGUF, OOM-killed process)
              # alike; GpuCudaOom distinguishes the VRAM case.
              alert = "LlamaSwapModelLoadFailed"
              expr  = "sum by (namespace) (count_over_time({namespace=\"llama-cpp\"} |~ \"starting .* failed\" [15m])) > 0"
              for   = "0m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "llama-swap could not start a model"
                description = "A model load failed, so consumers (paperless-ai, recruiter-responder, tripit) get HTTP 500 or fall back. If GpuCudaOom is also firing this is VRAM starvation and the watchdog should clear it; if not, look at the model files on the NFS-SSD PVC and the llama-swap log."
              }
            },
            {
              alert = "KernelPanic"
              expr  = "sum by (node) (count_over_time({job=\"node-journal\"} |~ \"(?i)Kernel panic\" [5m])) > 0"
              for   = "0m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary = "Kernel panic on {{ $labels.node }}"
              }
            },
            {
              alert = "KernelHungTask"
              expr  = "sum by (node) (count_over_time({job=\"node-journal\"} |~ \"blocked for more than\" [5m])) > 0"
              for   = "0m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary = "Hung task detected on {{ $labels.node }}"
              }
            },
            {
              alert = "KernelSoftLockup"
              expr  = "sum by (node) (count_over_time({job=\"node-journal\"} |~ \"(?i)soft lockup\" [5m])) > 0"
              for   = "0m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary = "Soft lockup on {{ $labels.node }}"
              }
            },
            {
              alert = "ContainerdDown"
              expr  = "sum by (node) (count_over_time({job=\"node-journal\", unit=\"containerd.service\"} |~ \"(?i)(dead|failed|deactivating)\" [5m])) > 0"
              for   = "1m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary = "containerd service unhealthy on {{ $labels.node }}"
              }
            },
          ]
        },
        {
          # Image pull & GC (added 2026-09-02, Phase 0 of
          # docs/plans/2026-09-02-node1-large-image-handling.md).
          #
          # On 2026-09-01 kubelet on k8s-node1 discarded 130 images and
          # 56.8567 GiB of warm image cache in one 4m38s pass, and nothing
          # alerted. That cache wipe is what turns the next reschedule of a
          # 3 GB GPU image into a 6m24s cold pull instead of a 405 ms warm one.
          # There was no alert on an image-GC pass anywhere in this repo before
          # this group.
          #
          # These are Loki-ruler rules because the signal is a journal line, not
          # a metric: kubelet exposes no counter for "images discarded". They
          # read the node-runtime-journal job that alloy.yaml ships (see the
          # long comment there) — NOT job="node-journal", which drops these
          # lines because they are journal priority 6.
          #
          # Message strings verified against the running binary rather than
          # remembered: `strings /usr/bin/kubelet` on k8s-node1 (v1.35.7,
          # 2026-09-02) contains "Removing image to free bytes",
          # "Disk usage on image filesystem is over the high threshold",
          # "Attempting to delete unused images" and "Eviction manager:
          # attempting to reclaim" (capital E, a space, no underscore — the
          # underscore form some notes use is the eviction_manager.go source
          # filename klog prints, not the message). The (?i) guards the casing
          # either way.
          #
          # Why 30m windows and for=0m: these fire per EVENT, and the known pass
          # emitted its 131 lines inside 4m38s. A 5m window would have gone
          # firing -> resolved -> firing across one incident. Same reasoning as
          # KernelOOMKiller's 2h window above.
          name = "Image pull & GC"
          rules = [
            {
              # The threshold crossing itself, one line per pass. This is the
              # line the plan wanted and could not read, because it states the
              # observed usage against imageGCHighThresholdPercent — the
              # 2026-09-01 crossing is still INFERRED (the sampled trough was
              # 83.57%, 3.86 GB short of the 85% threshold) purely because this
              # line had already rotated out of node1's volatile journal.
              #
              # Emitted only by the threshold path in image_gc_manager.go, so it
              # stays correct after Phase 3 gives imageMaximumGCAge a finite
              # value and age-based collection starts running routinely.
              alert = "NodeImageGCThresholdCrossed"
              expr  = "sum by (node) (count_over_time({job=\"node-runtime-journal\", unit=\"kubelet.service\"} |= \"Disk usage on image filesystem is over the high threshold\" [30m])) > 0"
              for   = "0m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "kubelet crossed the image-GC disk threshold on {{ $labels.node }} — warm image cache is being discarded"
                description = "Live imageGCHighThresholdPercent is 85 on all six nodes and imagefs shares the root filesystem, so this fires at the same instant as evictionHard imagefs.available 15%. The line itself carries the observed usage and the amount kubelet intends to free: homelab logs query '{job=\"node-runtime-journal\", unit=\"kubelet.service\"} |= \"high threshold\"' --since 1h. Headroom per node: kubectl get --raw /api/v1/nodes/<node>/proxy/stats/summary | jq '.node.fs.availableBytes - .node.fs.capacityBytes*0.15'. As of 2026-09-02 k8s-node5 had 4.07 GB of headroom and k8s-node2 12.53 GB, against 9.2-12.3 GB written by a single cold pull of a 3 GB image."
              }
            },
            {
              # Volume signal: how much cache actually went. 130 lines in the
              # 2026-09-01 pass. Threshold 20 in 30m, so this stays quiet for
              # the handful of images a routine age-based sweep will remove once
              # Phase 3 sets a finite imageMaximumGCAge, and still catches a
              # mass eviction. Phase 3's FIRST sweep is expected to clear
              # 100-170 GiB on node2/node5 and will legitimately fire this once
              # — that is the alert working, not a false positive.
              alert = "NodeImageCacheMassEviction"
              expr  = "sum by (node) (count_over_time({job=\"node-runtime-journal\", unit=\"kubelet.service\"} |= \"Removing image to free bytes\" [30m])) > 20"
              for   = "0m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "{{ $value }} cached images discarded on {{ $labels.node }} in 30m"
                description = "Every image removed here is a future cold pull. The 2026-09-01 pass on k8s-node1 removed 130 images / 56.8567 GiB in 4m38s and left the node with 52 unique digests, the fewest of any worker. WHICH images: homelab logs query '{job=\"node-runtime-journal\", unit=\"kubelet.service\"} |= \"Removing image to free bytes\"' --since 1h. Pull cost that will be paid back later: kubelet_image_pull_duration_seconds_sum by image_size_in_bytes (restored to Prometheus in the same phase)."
              }
            },
            {
              # The eviction manager's own reclaim attempt. Broader than the two
              # above — it also covers memory and nodefs pressure, so it is the
              # earlier and less specific signal. One line appeared in the
              # 2026-09-01 pass, ahead of the 130 removals.
              alert = "NodeEvictionManagerReclaiming"
              expr  = "sum by (node) (count_over_time({job=\"node-runtime-journal\", unit=\"kubelet.service\"} |~ `(?i)Eviction manager: attempting to reclaim` [30m])) > 0"
              for   = "0m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "kubelet eviction manager is reclaiming node resources on {{ $labels.node }}"
                description = "Which resource is in the line's resourceName field (ephemeral-storage / memory / imagefs): homelab logs query '{job=\"node-runtime-journal\", unit=\"kubelet.service\"} |~ `(?i)attempting to reclaim`' --since 1h. This precedes pod eviction; on 2026-09-01 it preceded 130 image removals on k8s-node1 instead, and DiskPressure flipped 5m later when evictionPressureTransitionPeriod expired."
              }
            },
            {
              # Liveness guard for the three rules above. Without it they read
              # as green when alloy stops shipping the runtime journals, which
              # is the exact failure mode this phase exists to close — the
              # 2026-09-01 event was invisible because these lines reached
              # nothing, not because nothing happened.
              #
              # `or vector(0)` is load-bearing: when the streams disappear
              # entirely, sum(count_over_time(...)) returns NO series and a
              # bare `< 1` never evaluates, so the alert goes silent in exactly
              # the case it exists to catch. Same shape as DevvmJournalSilent.
              #
              # Threshold: cluster-wide, measured 2026-09-02 at 23,674 lines/hr
              # from these two units (kubelet 2,793 + containerd 20,881), with
              # the quietest single node at ~20 lines/hr. `< 1` over 1h means
              # total silence, not a quiet node. A per-node version would need
              # its own calibration, because k8s-master's kubelet emits 2
              # lines/hr and would trip a naive threshold.
              #
              # for=30m covers the alloy DaemonSet rollout: the rules ConfigMap
              # and the DS apply in the same terragrunt run and the DS has a
              # 900s helm timeout, so the ruler can start evaluating before the
              # first line arrives.
              alert = "RuntimeJournalSilent"
              expr  = "(sum(count_over_time({job=\"node-runtime-journal\"}[1h])) or vector(0)) < 1"
              for   = "30m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "No kubelet/containerd journal lines in Loki for >1h — NodeImageGCThresholdCrossed and its two siblings are blind"
                description = "Check the alloy DaemonSet: kubectl get ds -n monitoring alloy; kubectl logs -n monitoring ds/alloy | grep -i journal. The two loki.source.journal blocks named kubelet_journal and containerd_journal in stacks/monitoring/modules/monitoring/alloy.yaml are the source of truth. Also check Loki-side stream limits: a 429 means the global 5000 active-stream cap is saturated. Expected steady state is ~23,674 lines/hr cluster-wide as measured 2026-09-02."
              }
            },
          ]
        },
        {
          # Egress / pfSense (added 2026-06-28 after the 2026-06-27 WAN/egress
          # incident). Cloudflared edge-connection failures are the log canary
          # that fired FIRST + most reliably — the cloudflared *deployment*
          # replica metric stays GREEN during a tunnel-connection outage (pods
          # Running, tunnels failing), so a metric alert is blind to this.
          # Routed via Loki ruler → Alertmanager → slack by severity; inhibited
          # under WANGatewayUnreachable/InternetEgressDown so it doesn't
          # double-page. Calibrated against live Loki 2026-06-28: steady-state
          # ~2 matches/6h; the incident ran 37-85 matches/5m, so >20/5m sits
          # well clear of noise. Runbook: docs/runbooks/pfsense-egress.md.
          name = "Egress / pfSense"
          rules = [
            {
              alert  = "CloudflaredTunnelConnLoss"
              expr   = "sum(count_over_time({namespace=\"cloudflared\"} |~ \"(?i)(lost connection with the edge|failed to dial|register tunnel error|failed to serve quic)\" [5m])) > 20"
              for    = "2m"
              labels = { severity = "warning", subsystem = "pfsense" }
              annotations = {
                summary     = "cloudflared losing edge/tunnel connections (>20/5m) — possible egress/WAN trouble"
                description = "cloudflared edge-connection failures exceeded 20 in 5m (steady-state ~2/6h; the 2026-06-27 egress incident hit 37-85/5m). Pods usually stay Running so the replica-health alert is blind — this log canary is the early egress signal. Correlate with InternetEgressDown / EgressOnlyDivergence. Runbook: docs/runbooks/pfsense-egress.md."
              }
            },
          ]
        },
        {
          # Immich worker split (2026-07-12): the job tier (immich-worker) has
          # no HTTP surface, so its death is invisible to HTTP probes — but the
          # api pods' checkWorkers() logs this exact warning every interval
          # while no microservices worker is registered in Redis. Message text
          # verified at v3.0.2 (server/src/repositories/job.repository.ts:128).
          name = "Immich"
          rules = [
            {
              alert  = "ImmichNoJobWorker"
              expr   = "sum(count_over_time({namespace=\"immich\"} |= \"No microservices worker is connected\" [5m])) > 0"
              for    = "5m"
              labels = { severity = "warning", subsystem = "immich" }
              annotations = {
                summary     = "Immich job tier down — thumbnails/transcodes/ML jobs silently paused"
                description = "immich-api pods keep logging Immich's 'No microservices worker is connected' warning: the single immich-worker (GPU job tier) is dead or can't reach Redis. Photo viewing keeps working; background jobs buffer in Redis until the worker returns. Check: kubectl -n immich get pods -l app=immich-worker. Design: docs/plans/2026-07-12-immich-horizontal-scaling-design.md §7. Brief flaps during worker deploys (Recreate, ~1 min) stay under the 5m for-window."
              }
            },
          ]
        },
        {
          # App auto-upgrades (Keel). Keel's direct Slack notifier was disabled
          # 2026-07-02 after a stuck update (gotenberg vs require-trusted-
          # registries) re-posted an identical failure to #general on every
          # hourly poll for days. This log alert is the replacement failure
          # signal: alert-on-change routing notifies ONCE and the daily digest
          # carries it while it persists — never an hourly drip.
          name = "App auto-upgrades (Keel)"
          rules = [
            {
              alert  = "KeelUpdateFailing"
              expr   = "sum(count_over_time({namespace=\"keel\"} |= \"level=error\" |= \"got error while updating resource\" [3h])) > 2"
              for    = "10m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "Keel repeatedly failing to roll out an image update"
                description = "Keel failed the same resource update >2 times in 3h (its poll is hourly, so this means a persistently stuck rollout, not a blip). kubectl -n keel logs deploy/keel | grep level=error. Common causes: kyverno require-trusted-registries denying the new tag (extend the allowlist in stacks/kyverno/modules/kyverno/security-policies.tf), a ResourceQuota rejecting the surge pod, or a bad imagePullSecret."
              }
            },
          ]
        },
        {
          # t3 session-auth + auto-upgrade health (devvm host scripts → journald →
          # Loki). Backstops the gated-nightly t3 tracker: the dispatch logs every
          # real-user pairing outcome (success endpoint + fallback) and the enforcer
          # logs every rollback/freeze. These catch a bad nightly that broke pairing
          # for real users between the tracker's own bump-time gate runs — the
          # 2026-06-09 failure class (mint/bootstrap broke, all users on the pair
          # prompt). Route: Loki ruler → Alertmanager → default #alerts Slack.
          # Runbook: docs/runbooks/t3-version-bump.md.
          # The T3AutoUpdate* identifier regex covers every t3-safe-restart.sh
          # caller (t3-autoupdate, t3-migrate-idle, t3-watchdog) — rollback/freeze
          # log lines are identical regardless of which timer triggered them.
          name = "t3 Auth & Upgrades"
          rules = [
            {
              # Real users failing to pair: mint error, exchange transport error, or
              # a non-2xx from the instance pairing API. Threshold >3/10m rides out a
              # benign single-instance restart race; sustained = pairing is broken.
              alert  = "T3PairingBroken"
              expr   = "sum(count_over_time({job=\"devvm-journal\", unit=\"t3-dispatch.service\"} |~ \"mint for .* failed|pairing exchange for .* failed|pairing for .* returned [0-9]\" [10m])) > 3"
              for    = "5m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "t3 dispatch pairing is failing for real users (>3/10m)"
                description = "t3-dispatch is failing to mint/exchange session cookies — users land on the t3 pair prompt instead of their workspace. Likely a bad t3 build broke the pairing API/schema (2026-06-09 class). Freeze the tracker (touch /etc/t3-autoupdate.freeze) and roll back per the runbook."
                runbook     = "docs/runbooks/t3-version-bump.md"
              }
            },
            {
              # The dispatch fell back off its first-preference pairing endpoint
              # (browser-session) to the legacy one — the running build moved/renamed
              # the pairing API. Pin-compatible today (the fallback works), but it
              # signals contract drift that a future build could break entirely.
              alert  = "T3PairFallbackHigh"
              expr   = "sum(count_over_time({job=\"devvm-journal\", unit=\"t3-dispatch.service\"} |~ \"paired .* fallback=true\" [30m])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "t3 dispatch is using the FALLBACK pairing endpoint — t3 moved the pairing API"
                description = "A t3 build is pairing via the legacy /api/auth/bootstrap because the preferred /api/auth/browser-session 404s. Still works via fallback, but add the new endpoint to pairEndpoints in scripts/t3-dispatch/main.go before a future build drops the legacy one."
                runbook     = "docs/runbooks/t3-version-bump.md"
              }
            },
            {
              # The enforcer's health-check failed a build and auto-rolled-back the
              # binary. The gate worked — but a bad nightly shipped, so you should know.
              # Window widened 15m -> 12h: this is an event-count alert with
              # `for: 0m`, so each rollback fired then resolved 15m later when
              # the lookback emptied, and the next nightly retry fired it again.
              # Measured 2026-08-10: 7 fire/resolve pairs in 7 days = 14 Slack
              # posts, every firing duration 15-20m. A 12h window keeps one
              # alert per nightly cycle instead of one per rollback event.
              alert  = "T3AutoUpdateRolledBack"
              expr   = "sum(count_over_time({job=\"devvm-journal\", identifier=~\"t3-autoupdate|t3-migrate-idle|t3-watchdog\"} |~ \"rolling back|rolled back\" [12h])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "t3 auto-update rolled back a bad build (gate worked)"
                description = "The t3 enforcer installed a new build, its pairing health-check failed, and it auto-rolled-back. Investigate the bad build before the next cycle retries it; pin T3_PIN to a known-good if it recurs."
                runbook     = "docs/runbooks/t3-version-bump.md"
              }
            },
            {
              # Rollback itself failed (npm couldn't reinstall the previous build):
              # the box may be left on a broken t3. Manual fix needed.
              alert  = "T3AutoUpdateRollbackFailed"
              expr   = "sum(count_over_time({job=\"devvm-journal\", identifier=~\"t3-autoupdate|t3-migrate-idle|t3-watchdog\"} |~ \"ROLLBACK FAILED\" [15m])) > 0"
              for    = "0m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "t3 auto-update rollback FAILED — t3 may be broken on the devvm"
                description = "The enforcer detected a bad build but could not reinstall the previous version. t3 may be broken for all users. Fix manually per the runbook (set T3_PIN to last-good, npm i -g, restore state if migrated)."
                runbook     = "docs/runbooks/t3-version-bump.md"
              }
            },
            {
              # The tracker refused to advance (pre-run auth gate tripped, or the
              # /etc/t3-autoupdate.freeze switch is set). Surfaces a stuck-on-purpose
              # tracker so it isn't silently frozen forever.
              alert  = "T3AutoUpdateFrozen"
              expr   = "sum(count_over_time({job=\"devvm-journal\", identifier=~\"t3-autoupdate|t3-migrate-idle|t3-watchdog\"} |~ \"FROZEN\" [25h])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "t3 auto-update is FROZEN (not tracking nightly)"
                description = "The t3 tracker froze — either the pre-run pairing gate tripped or /etc/t3-autoupdate.freeze is set. t3 is held at the last-good pin and is NOT picking up new builds until cleared. Confirm pairing is healthy, then remove the freeze."
                runbook     = "docs/runbooks/t3-version-bump.md"
              }
            },
            {
              # The wedge watchdog detected a dead/unresponsive t3-serve listener
              # and safe-restarted it (2026-07-08 class: OOMPolicy=continue keeps
              # the main proc alive but it drops its listener after a cgroup OOM).
              # Self-healed — skim why it wedged (cgroup OOM is the usual suspect).
              alert  = "T3WatchdogRestarted"
              expr   = "sum(count_over_time({job=\"devvm-journal\", identifier=\"t3-watchdog\"} |~ \"WATCHDOG: restarted\" [15m])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "t3-watchdog auto-restarted a wedged t3-serve instance"
                description = "A t3-serve instance stopped answering its local port while its unit stayed active; the watchdog safe-restarted it and pairing verified. Self-healed. Check the devvm journal (identifier=t3-watchdog) for which user and the failure reason."
                runbook     = "docs/runbooks/t3-watchdog.md"
              }
            },
            {
              # The watchdog hit its flap cap (default 3 restarts/30m) and stood
              # down while the instance is still unhealthy — restarting isn't
              # curing it. That user's t3 is DOWN until a human intervenes.
              alert  = "T3WatchdogExhausted"
              expr   = "sum(count_over_time({job=\"devvm-journal\", identifier=\"t3-watchdog\"} |~ \"WATCHDOG-EXHAUSTED\" [15m])) > 0"
              for    = "0m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "t3-watchdog EXHAUSTED — a t3-serve instance keeps wedging and stays down"
                description = "The watchdog restarted the same t3-serve instance to its flap cap within the window and it is still failing probes, so it stood down. Investigate: cgroup OOM kills (journalctl -k), state.sqlite size, the running build; restart manually once the cause is addressed."
                runbook     = "docs/runbooks/t3-watchdog.md"
              }
            },
            {
              # DEAD-MAN switch for the devvm log pipeline. Every rule in this
              # group is blind if the devvm journal stops reaching Loki — which
              # happened SILENTLY 2026-06-30..07-09 (journald went Storage=volatile,
              # promtail kept tailing the now-empty /var/log/journal; found only
              # because the t3-watchdog drill's alert never arrived). The devvm
              # logs every minute (t3 timers), so 30m of absence = pipeline dead.
              alert  = "DevvmJournalSilent"
              expr   = "absent_over_time({job=\"devvm-journal\"}[30m]) == 1"
              for    = "15m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "devvm journal has stopped reaching Loki — ALL devvm alerts are blind"
                description = "No {job=\"devvm-journal\"} lines for >45m. Every t3/claude-auth alert in this group is non-functional until fixed. Check on the devvm: systemctl status promtail; curl -s localhost:9080/metrics | grep -E 'sent_entries|journal_target_lines|429'; journalctl -u promtail. Config source-of-truth: scripts/devvm-promtail.yaml (journald is Storage=volatile — the journal lives in /run/log/journal; promtail must NOT pin path to /var/log/journal). Loki-side: 429 stream-limit = global 5000 active-stream cap saturated."
              }
            },
            {
              # Per-user Claude refresh/backup/restore exhausted its automatic
              # recovery path. This is actionable: that user needs interactive SSO,
              # or the scoped Vault token/bootstrap needs repair.
              # Groups by the USER, which is the whole point of the alert.
              # It used to `sum by (unit)`, but this stream carries no `unit`
              # label (its labels are host, identifier, job, service_name,
              # detected_level), so the group key was always empty: every user
              # collapsed into one series and the summary rendered as
              # "...recovery failed on" with nothing after it. Verified against
              # live Loki 2026-08-10. The user is in the line body instead —
              #   user=ancamilea FAIL no recoverable Claude OAuth credential...
              # — so it is extracted with regexp. (logfmt would choke on the
              # bare FAIL/WARN token that follows.)
              #
              # Window widened 15m -> 7h. The per-user timer runs every ~6h, and
              # with a 15m lookback the alert resolved 15m after each run and
              # re-fired at the next one: 24 fire/resolve pairs in 7 days = 48
              # Slack posts, every single firing duration exactly 15m, for one
              # standing condition (a user who has never completed interactive
              # SSO). 7h spans the timer interval, so a persistent failure stays
              # one continuous alert and clears once a run succeeds.
              alert  = "WorkstationClaudeAuthInvalid"
              expr   = "sum by (user) (count_over_time({job=\"devvm-journal\", identifier=\"claude-auth-sync\"} |~ \"FAIL\" | regexp \"user=(?P<user>[a-zA-Z0-9_.-]+)\" [7h])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "Claude authentication recovery failed for user={{ $labels.user }}"
                description = "The Workstation renewal agent could not validate Claude auth, renew its scoped Vault token, or recover from the Vault backup. Follow the per-user SSO recovery runbook."
                runbook     = "docs/runbooks/claude-auth-renew-workstation.md"
              }
            },
          ]
        },
        {
          # Claude session loss on the devvm. Until this group existed, a session
          # dying was found by looking at the sidebar and counting — which is how
          # the 2026-09-01 05:55 kill was noticed, hours later.
          #
          # Two producers. The kernel writes the oom-kill line itself; everything
          # else comes from tl-session-watch, which ships in the terminal-lobby
          # package and logs logfmt under SyslogIdentifier=tl-session-watch. That
          # identifier MUST stay in the allowlist in scripts/devvm-promtail.yaml:
          # the label is what these selectors match, and without it they match
          # nothing and say nothing about it.
          #
          # All four group by USER over a wide window, so a burst reads as one
          # continuous alert rather than one Slack post per kill. Replaying the
          # 2026-08-16 event (~21 kills in two minutes) gives one message per
          # affected user. severity=warning means notify once, no re-ping while
          # firing, with the daily digest carrying standing state.
          #
          # Design: docs/plans/2026-09-01-devvm-session-loss-alerting.md
          name = "Claude Session Loss (devvm)"
          rules = [
            {
              # The cap doing its job, on the wrong victim. constraint=MEMCG means
              # the PANE hit its own 6G ceiling, which is independent of box
              # memory: this fires with 20 GiB free on the box, and
              # DevvmMemoryPressure does not fire with it. Measured over the 7
              # days before this rule: 3 panes hit the cap, 2 of them killing a
              # claude.
              #
              # Grouped by uid because that is what the kernel line carries
              # (1000=wizard, 1002=emo); tl-session-watch's own lines carry the
              # username.
              # The OTHER killer on this box, and the one that acts when the
              # BOX is short rather than a single pane. earlyoom runs with
              # -m 5,3: SIGTERM at 5% MemAvailable, SIGKILL at 3%. It picks by
              # badness, which on a workstation full of Claude sessions
              # usually means a claude. Measured on 2026-09-01 18:49-18:51,
              # the last event before this rule: 90 kill signals against uid
              # 1000 in one 2h window, taking claude processes, a vitest run
              # and python3; uid 1002 lost 1.
              #
              # Matched on "to process" deliberately. earlyoom prints its
              # thresholds at startup as "sending SIGTERM when mem <= 5.00%",
              # which a bare /sending SIGTERM/ matches, so that filter would
              # have paged on every restart of the service (3 in the 397h to
              # 2026-09-03). This version of earlyoom never prints "Killing
              # process" at all. Both signals are counted: earlyoom escalates
              # SIGTERM to SIGKILL for the same victim, so one stubborn process
              # can contribute two, and it also SIGKILLs directly once below
              # the lower threshold.
              #
              # 2h window grouped by uid, matching ClaudeOOMKilled, so a burst
              # is one Slack line per affected user rather than ninety. uid
              # 1000=wizard, 1002=emo, 0=root. Distinct from ClaudeOOMKilled,
              # which reads the KERNEL's memcg oom-kill line: that one is a
              # pane hitting its own 6G cap with the box otherwise healthy,
              # this one is the box itself running out.
              alert  = "EarlyoomKilledProcess"
              expr   = "sum by (uid) (count_over_time({job=\"devvm-journal\", identifier=\"earlyoom\"} |~ \"sending SIG(TERM|KILL) to process\" | regexp \"uid (?P<uid>[0-9]+)\" [2h])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "earlyoom killed {{ $value }} processes on the devvm (uid={{ $labels.uid }})"
                description = "The box ran out of memory and earlyoom started picking victims, which on this machine usually means Claude sessions. WHAT DIED: homelab logs query '{job=\"devvm-journal\", identifier=\"earlyoom\"} |~ \"to process\"' --since 2h. uid 1000=wizard, 1002=emo, 0=root. A SIGTERM that escalated counts twice. DevvmMemoryPressure should have fired first at 8% available; if it did not, the box crossed from healthy to 5% inside one 2-minute scrape. Containment design: docs/post-mortems/2026-06-22-devvm-mem-io-overload-containment.md."
              }
            },
            {
              alert  = "ClaudeOOMKilled"
              expr   = "sum by (uid) (count_over_time({job=\"devvm-journal\", identifier=\"kernel\"} |= \"oom-kill:\" |= \"task=claude\" | regexp \"uid=(?P<uid>[0-9]+)\" [2h])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "A claude was OOM-killed on the devvm (uid={{ $labels.uid }})"
                description = "The kernel killed a claude process to satisfy a memory limit. constraint=CONSTRAINT_MEMCG means the pane hit its own 6G cap, not that the box ran out. Which pane and which victim: homelab logs query '{job=\"devvm-journal\", identifier=\"kernel\"} |= \"oom-kill:\" |= \"task=claude\"' --since 2h. uid 1000=wizard, 1002=emo. Cap design: docs/plans/2026-08-16-devvm-pane-memory-cap.md."
              }
            },
            {
              # The effect, from the watcher rather than the kernel, so it covers
              # every cause and not just OOM. session_died = the session left tmux
              # with no tmux-persist TOMBSTONE written in the last 90s, which means
              # nobody ended it on purpose. claude_died = the session survived and
              # the conversation in it did not.
              #
              # The tombstone, not the manifest row: tmux-persist-forget appends to
              # <user>.forgotten.tsv and leaves the manifest row alone until the
              # next 5-minute save. The first version of this read an orphaned row
              # and so called every deliberate kill a death for up to five minutes.
              #
              # A clean /exit used to land here too, and paged emo on
              # 2026-09-03 for tidying up. tmux-api's DELETE handler writes the
              # tombstone, which covers a kill from the lobby and a T3 thread
              # deletion, since t3-sync goes through that endpoint. It never saw
              # a user typing /exit: claude ends, its pane exits, the session
              # closes, and tmux-api is not involved. The SessionEnd hook now
              # records that ending itself, in /run/user/<uid>/tl-clean-exit.tsv,
              # and the watcher reads it alongside the tombstones. A hook cannot
              # run when the process is SIGKILLed or OOM-killed, so this narrows
              # the rule without blinding it (terminal-lobby 239324c).
              #
              # Remaining false positive: `tmux kill-session` typed at a CLI.
              # It tombstones nothing and fires no hook, so it still reads as a
              # death.
              alert  = "ClaudeSessionDied"
              expr   = "sum by (user) (count_over_time({job=\"devvm-journal\", identifier=\"tl-session-watch\"} |~ \"event=(session_died|claude_died)\" | logfmt [2h])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "{{ $value }} of {{ $labels.user }}'s Claude sessions died in the last 2h"
                description = "A session disappeared without being deliberately killed, or its claude died inside a pane that survived. WHICH ONES: homelab logs query '{job=\"devvm-journal\", identifier=\"tl-session-watch\"} |~ \"event=(session_died|claude_died)\"' --since 2h. Correlate with ClaudeOOMKilled for the memory cause; a death with no OOM line beside it was something else. A CLI `tmux kill-session` that skipped tmux-persist-forget also lands here."
              }
            },
            {
              # The pre-warning, and the only signal that arrives while the
              # conversation can still be saved. Gated on claude being the largest
              # process in the pane, which is the same ranking the kernel uses at
              # the cap: when a build or a test run is the largest, the cap eating
              # it is the mechanism working correctly and not worth a message.
              #
              # The watcher compares UNRECLAIMABLE memory (anon + shmem), not
              # memory.current. current rides up to the cap in any pane doing file
              # I/O because the cap reclaims cache instead of killing: one pane
              # measured 6143 MB of a 6144 MB cap with memory.events max=45450 and
              # oom_kill=0, while holding only 628 MB that could not be reclaimed.
              #
              # 30s detection, deliberately not a Prometheus rule. The devvm is
              # scraped every 2 minutes and the house floor for `for:` is 3, so a
              # metric rule cannot react to a pane that crosses and dies inside one
              # interval. tl_pane_memory_bytes exists for history and threshold
              # tuning, not for this.
              alert  = "PaneNearMemoryCap"
              expr   = "sum by (user) (count_over_time({job=\"devvm-journal\", identifier=\"tl-session-watch\"} |= \"event=pane_near_cap\" | logfmt [30m])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "{{ $labels.user }} has a pane approaching its 6G cap with claude as the largest process"
                description = "The next cap kill in this pane takes the conversation, not a build. Normal claude is ~0.5 GB and the busiest pane measured is 1.5 GB, so 3 GB is already ~6x. WHICH SESSION: homelab logs query '{job=\"devvm-journal\", identifier=\"tl-session-watch\"} |= \"event=pane_near_cap\"' --since 30m. CHECK WHAT KIND OF MEMORY IT IS FIRST: cat /sys/fs/cgroup/<scope>/memory.stat. If shmem dominates, the pane is holding RAM-backed /tmp files (8G tmpfs, 7.0G of it /tmp/claude-1000 on 2026-09-01) and closing the session will NOT help — the kernel would kill the ~0.5 GB claude and leave the tmpfs behind. Delete the scratch files instead. If anon dominates, closing a session does help (~659 MB each). Panes can also SHARE a cgroup — four of emo's claudes sat in one run-r*.scope — so several sessions may cross together and all are genuinely at risk."
              }
            },
            {
              # DEAD-MAN switch for the watcher, mirroring DevvmJournalSilent one
              # level down: that one catches the pipeline dying, this one catches
              # the producer dying. It exists because DevvmJournalSilent was itself
              # added only after a t3-watchdog drill's alert never arrived, and a
              # watcher whose whole job is preventing silent failure is the worst
              # possible thing to lose silently.
              #
              # The watcher heartbeats every 30s whether or not it found anything,
              # so 30m of absence is unambiguous. Its /health on 127.0.0.1:7689
              # reports stale rather than up once ticks stop, which covers the
              # running-but-wedged case at release time.
              alert  = "SessionWatchSilent"
              expr   = "absent_over_time({job=\"devvm-journal\", identifier=\"tl-session-watch\"}[30m]) == 1"
              for    = "10m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "tl-session-watch has gone quiet — nothing is reporting lost Claude sessions"
                description = "No heartbeat for >40m, so ClaudeSessionDied and PaneNearMemoryCap are blind. On the devvm: systemctl status tl-session-watch; curl -s 127.0.0.1:7689/health; journalctl -u tl-session-watch -n 50. If the journal pipeline is the problem instead, DevvmJournalSilent fires alongside this."
              }
            },
          ]
        },
        {
          # Wave 1 security alerts (beads code-8ywc). Routed via Loki ruler →
          # prometheus-alertmanager → #security Slack receiver. Allowlist CIDRs:
          # 10.0.20.0/22, 192.168.1.0/24, K8s pod CIDR 10.10.0.0/16, K8s service
          # CIDR 10.96.0.0/12. Identity allowlist: me@viktorbarzin.me only.
          # NOTE: K1 (cluster-admin grant) intentionally skipped.
          name = "Security Wave 1"
          rules = [
            # V1: Root token created (Vault audit, vault-tail sidecar stream)
            {
              alert  = "VaultRootTokenCreated"
              expr   = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | request_path=\"auth/token/create\" |~ \"\\\"policies\\\":\\\\[\\\"root\\\"\\\\]\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary     = "Vault root token created"
                description = "A token with policies=[root] was issued via auth/token/create. Verify this is a planned bootstrap or break-glass; otherwise treat as critical compromise."
                runbook     = "docs/runbooks/security-incident.md#v1-root-token-created"
              }
            },
            # V2: Audit device disabled/modified
            {
              alert  = "VaultAuditDeviceModified"
              expr   = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | request_path=~\"sys/audit/.+\" | operation=~\"(create|delete|update)\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Vault audit device modified — attacker may be silencing visibility"
                runbook = "docs/runbooks/security-incident.md#v2-audit-device-disabledmodified"
              }
            },
            # V3: Seal status changed
            {
              alert  = "VaultSealChanged"
              expr   = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | request_path=\"sys/seal\" | operation=\"update\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Vault seal status changed via API — confirm planned operation"
                runbook = "docs/runbooks/security-incident.md#v3-seal-status-changed"
              }
            },
            # V4: Policy modified
            {
              alert  = "VaultPolicyModified"
              expr   = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | request_path=~\"sys/policies/acl/.+\" | operation=~\"(create|update|delete)\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary = "Vault policy modified — verify Terraform-driven change"
                runbook = "docs/runbooks/security-incident.md#v4-policy-modified"
              }
            },
            # V5: Auth failure spike
            {
              alert  = "VaultAuthFailureSpike"
              expr   = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | type=\"response\" |~ \"\\\"error\\\":\\\"permission denied\\\"\" [1m])) > 10"
              for    = "1m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary = "Vault permission-denied spike >10/min — possible brute force or CI rotation glitch"
                runbook = "docs/runbooks/security-incident.md#v5-auth-failure-spike"
              }
            },
            # V7: Viktor identity from non-allowlist source IP
            # XFF trust enabled, so request.remote_address is the real client IP.
            # Allowlist regex covers: 10.0.20.x, 192.168.1.x, pod CIDR 10.10.x.x,
            # service CIDR 10.96-111.x.x, Headscale tailnet 100.64-127.x.x.
            {
              alert  = "VaultViktorFromUnexpectedIP"
              expr   = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | auth_metadata_username=\"me@viktorbarzin.me\" | request_remote_address!~\"^(10\\\\.0\\\\.2[0-3]\\\\.|192\\\\.168\\\\.1\\\\.|10\\\\.10\\\\.|10\\\\.(9[6-9]|1[01][0-9]|111)\\\\.|100\\\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\\\.).*\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Vault auth as me@viktorbarzin.me from non-allowlist source IP — possible stolen OIDC token"
                runbook = "docs/runbooks/security-incident.md#v7-viktors-vault-identity-from-unexpected-source-ip"
              }
            },
            # K2: ServiceAccount token used from outside cluster.
            # Allowlist = pod CIDR + LAN + devvm VLAN 10 + Headscale tailnet.
            # Anything else = likely stolen SA token used externally.
            # NOTE: sourceIPs is a JSON *array*; Loki's no-arg `| json` flattens
            # nested objects but does NOT index arrays, so it never populates
            # `sourceIPs_0` (always empty -> matched every event). Use an
            # explicit array expression + a non-empty guard. (fixed 2026-07-06)
            {
              alert  = "K8sSATokenFromUnexpectedIP"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json user_username=\"user.username\", sourceIPs_0=\"sourceIPs[0]\" | user_username=~\"system:serviceaccount:.+\" | sourceIPs_0!=\"\" | sourceIPs_0!~\"^(10\\\\.0\\\\.2[0-3]\\\\.|192\\\\.168\\\\.1\\\\.|10\\\\.0\\\\.10\\\\.|10\\\\.10\\\\.|10\\\\.(9[6-9]|1[01][0-9]|111)\\\\.|100\\\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\\\.).*\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "K8s ServiceAccount token used from non-allowlist source IP — possible stolen SA token"
                runbook = "docs/runbooks/security-incident.md#k2-serviceaccount-token-used-from-outside-cluster"
              }
            },
            # K3: Secret read in sensitive namespace by unexpected actor.
            # Allowlisted readers: ESO controller, sealed-secrets controller,
            # Vault SA, me@viktorbarzin.me. Anyone else = alert.
            {
              alert  = "K8sSensitiveSecretReadByUnexpectedActor"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=~\"get|list\" | objectRef_resource=\"secrets\" | objectRef_namespace=~\"vault|sealed-secrets|external-secrets\" | user_username!~\"^(me@viktorbarzin\\\\.me|system:serviceaccount:external-secrets:.+|system:serviceaccount:sealed-secrets:.+|system:serviceaccount:vault:.+)$\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Sensitive Secret read in vault/sealed-secrets/external-secrets by non-allowlisted actor"
                runbook = "docs/runbooks/security-incident.md#k3-secret-read-in-sensitive-namespace-by-unexpected-actor"
              }
            },
            # K4: Exec into pod in sensitive namespace.
            {
              alert  = "K8sExecIntoSensitiveNamespace"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=\"create\" | objectRef_resource=\"pods\" | objectRef_subresource=\"exec\" | objectRef_namespace=~\"vault|kube-system|dbaas|cnpg-system\" | user_username!=\"me@viktorbarzin.me\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary = "kubectl exec into sensitive namespace (vault/kube-system/dbaas/cnpg-system) by non-Viktor actor"
                runbook = "docs/runbooks/security-incident.md#k4-exec-into-sensitive-pod"
              }
            },
            # K5: Mass delete of pods/secrets/configmaps in 60s by single actor.
            # Excludes legitimate bulk-deleters (2026-07-06, extended 2026-07-07
            # — these fired SECURITY/CRITICAL + RESOLVED on a loop): kubelets
            # (system:node:* reap pods), the kube-system GC + namespace-controller
            # + daemon-set-controller (replaces evicted DS pods during node
            # pressure), woodpecker CI (pipeline-pod cleanup), and the local-path
            # provisioner (deletes its helper pods for every Woodpecker workspace
            # PVC — >5/60s on any busy CI window), and post-boot-reconcile
            # (reboot self-heal: restarts pods that missed Kyverno wait-for
            # injection on a cold boot — capped at 15/run). A human (me@viktorbarzin.me /
            # kubernetes-admin) or an app-namespace SA doing >5 deletes/60s still
            # fires.
            {
              alert  = "K8sMassDelete"
              expr   = "sum by (user_username) (count_over_time({job=\"kubernetes-audit\"} | json | verb=\"delete\" | objectRef_resource=~\"pods|secrets|configmaps\" | user_username!~\"^system:(node:.+|serviceaccount:(kube-system:(generic-garbage-collector|namespace-controller|daemon-set-controller)|woodpecker:.+|local-path-storage:local-path-provisioner-service-account|kyverno:post-boot-reconcile))$\" [1m])) > 5"
              for    = "1m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Mass delete (>5 Pod/Secret/ConfigMap in 60s) by {{ $labels.user_username }}"
                runbook = "docs/runbooks/security-incident.md#k5-mass-delete"
              }
            },
            # K6: Audit policy or audit-log path modified — attacker silencing
            # visibility. The audit policy file is /etc/kubernetes/policies/audit-policy.yaml
            # on master; changes go via kubeadm reconfig. Detect via API access
            # to apiserver kubeadm-config ConfigMap.
            {
              alert  = "K8sAuditPolicyModified"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=~\"update|patch\" | objectRef_resource=\"configmaps\" | objectRef_name=\"kubeadm-config\" | objectRef_namespace=\"kube-system\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "kubeadm-config ConfigMap modified — could be audit policy change"
                runbook = "docs/runbooks/security-incident.md#k6-audit-policy-modified"
              }
            },
            # K7: New ClusterRole created with verbs=* and resources=*.
            # Allowlist excludes calico-system, kyverno, nvidia, etc. which legitimately
            # create such ClusterRoles via Helm.
            {
              alert  = "K8sClusterRoleWildcardCreated"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=\"create\" | objectRef_resource=\"clusterroles\" |~ \"\\\"verbs\\\":\\\\[\\\"\\\\*\\\"\\\\]\" |~ \"\\\"resources\\\":\\\\[\\\"\\\\*\\\"\\\\]\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary = "New ClusterRole with verbs=[*]+resources=[*] created — privilege escalation primitive"
                runbook = "docs/runbooks/security-incident.md#k7-new-clusterrole-with-full-wildcards"
              }
            },
            # K8: Anonymous binding granted — catastrophic.
            {
              alert  = "K8sAnonymousBindingGranted"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=\"create\" | objectRef_resource=~\"rolebindings|clusterrolebindings\" |~ \"system:(anonymous|unauthenticated)\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Binding granted to system:anonymous or system:unauthenticated — full cluster compromise risk"
                runbook = "docs/runbooks/security-incident.md#k8-anonymous-binding"
              }
            },
            # K9: Viktor's identity from non-allowlist source IP.
            # Same sourceIPs array-extraction fix + VLAN 10 allowlist as K2
            # above (no-arg `| json` never populates `sourceIPs_0`). (fixed 2026-07-06)
            {
              alert  = "K8sViktorFromUnexpectedIP"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json user_username=\"user.username\", sourceIPs_0=\"sourceIPs[0]\" | user_username=\"me@viktorbarzin.me\" | sourceIPs_0!=\"\" | sourceIPs_0!~\"^(10\\\\.0\\\\.2[0-3]\\\\.|192\\\\.168\\\\.1\\\\.|10\\\\.0\\\\.10\\\\.|10\\\\.10\\\\.|10\\\\.(9[6-9]|1[01][0-9]|111)\\\\.|100\\\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\\\.).*\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "K8s API request as me@viktorbarzin.me from non-allowlist source IP — possible stolen kubeconfig/OIDC token"
                runbook = "docs/runbooks/security-incident.md#k9-viktors-identity-from-unexpected-source-ip"
              }
            },
            # S1: PVE sshd auth success from non-allowlist IP.
            # Conditional on the pve-sshd promtail unit being live on PVE host
            # (deployed via stacks/infra/scripts — out of scope until W1.3 host
            # piece lands). Rule is defined so it fires automatically once logs
            # flow with job=sshd-pve.
            {
              alert  = "PVEsshLoginFromUnexpectedIP"
              expr   = "sum(count_over_time({job=\"sshd-pve\"} |~ \"Accepted (publickey|password|keyboard-interactive)\" | regexp \"Accepted (?P<method>\\\\S+) for (?P<user>\\\\S+) from (?P<ip>\\\\S+) port\" | ip!~\"^(10\\\\.0\\\\.2[0-3]\\\\.|192\\\\.168\\\\.1\\\\.|100\\\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\\\.).*\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "PVE sshd login from non-allowlist source IP — possible stolen SSH key"
                runbook = "docs/runbooks/security-incident.md#s1-pve-sshd-auth-success-from-unexpected-ip"
              }
            },
          ]
        },
        {
          # Matrix (tuwunel) — notify on every new signup. Registration was open
          # when this rule was written and is CLOSED as of 2026-08-15, which makes
          # the rule more valuable rather than less: it is now the canary that
          # tells us if the door reopened. tuwunel logs `... New user "@x:..."
          # registered on this server` only on SUCCESS (the disabled path logs
          # "Rejecting ... registration is disabled"), so this matcher never
          # false-fires on the rejected attempts a closed server now produces.
          # lane=security routes it to the existing #security Slack receiver.
          name = "CrowdSec L7 bouncer"
          rules = [
            {
              # The in-process Traefik bouncer (stacks/traefik
              # crowdsec-bouncer-plugin) runs under Yaegi, where Prometheus
              # counters are not cheaply available, so its decisions are
              # structured log lines and this is where they are alerted on.
              # Liveness lives in prometheus_chart_values.tpl instead
              # (CrowdSecL7BouncerNotPolling, off LAPI's per-bouncer counter).
              #
              # Fail-open means a LAPI outage is NOT an availability incident —
              # traffic keeps flowing on the last known decision set. It is a
              # staleness incident: nothing new is enforced and an unban does not
              # take effect. 30m before firing, since a single failed poll during
              # a LAPI roll is routine and the next one 30s later recovers.
              alert = "CrowdSecL7BouncerRefreshFailing"
              expr  = "sum(count_over_time({namespace=\"traefik\"} |= \"[crowdsec-bouncer] action=refresh-failed\" [15m])) > 0"
              for   = "30m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "Traefik CrowdSec bouncer cannot reach LAPI — serving a stale ban set"
                description = <<-EOT
                  The bouncer has been failing to refresh decisions for 30m. It
                  fails OPEN on the last known set, so nothing is being blocked
                  that was not already blocked, and legitimate traffic is
                  unaffected — but a new ban will not be enforced and a DELETED
                  ban will keep blocking. The log line carries the underlying
                  error; a connection refused usually means crowdsec-lapi.
                EOT
              }
            },
            {
              # The feedback loop this guards: blocked requests now reach Traefik
              # and are access-logged, so a burst of 403s can itself trip
              # crowdsecurity/http-403-abuse, whose profile notifies per decision.
              # A false-positive ban on a busy shared address would show up here
              # first, as sustained blocking on one IP across many hosts.
              #
              # Threshold is deliberately loose: the enforced set is currently the
              # 4 non-CAPI decisions, and normal scanner traffic against a banned
              # IP is a handful of requests. Re-derive it before enabling CAPI —
              # 22.7k community bans will change the baseline completely.
              alert = "CrowdSecL7BlockBurst"
              expr  = "sum by (ip) (count_over_time({namespace=\"traefik\"} |= \"[crowdsec-bouncer] action=block\" | regexp \"ip=(?P<ip>[^ ]+)\" [15m])) > 200"
              for   = "15m"
              labels = {
                severity = "info"
              }
              annotations = {
                summary     = "CrowdSec bouncer has blocked {{ $labels.ip }} over 200 times in 15m"
                description = <<-EOT
                  Either a real attacker persisting against a ban, or a false
                  positive on an address that carries legitimate traffic — a
                  NAT/CGNAT egress, or one of our own. Check what the address is
                  before assuming: our own London WAN egress was hand-banned on
                  2026-08-16 exactly this way. `cscli decisions list --ip <ip>`
                  shows the scenario that decided it, and `cscli decisions delete
                  --ip <ip>` takes effect within one 30s poll.
                EOT
              }
            },
          ]
        },
        {
          name = "Matrix"
          rules = [
            {
              alert = "MatrixNewUserRegistered"
              # Carries WHO in the alert itself (2026-08-15) rather than telling
              # the reader to go grep the pod. The full tuwunel line is
              # `New user "@x:host" registered on this server from IP <ip> with
              # device name <dev>`, so mxid/client_ip/device are extracted into
              # labels and land in the Slack text — the client name separates a
              # real client (Element, SchildiChat) from a scripted signup at a
              # glance. Backtick-quoted regex so the literal `"` around the mxid
              # needs no second layer of escaping. Verified against every
              # matching line in Loki's 30-day retention (2026-08-15): all parse,
              # and at ~2 signups/month the per-signup label cardinality is
              # negligible. Non-matching lines would aggregate into one
              # empty-label series, which reads as an unnamed signup rather than
              # silently vanishing.
              expr = "sum by (mxid, client_ip, device) (count_over_time({namespace=\"matrix\",container=\"matrix\"} |= \"registered on this server\" | regexp `New user \"(?P<mxid>[^\"]+)\" registered on this server from IP (?P<client_ip>\\S+) with device name (?P<device>.*)` [10m])) > 0"
              for  = "0m"
              # Raised info -> warning on 2026-08-15 when registration was closed.
              # While signups were open this fired on every routine stranger and
              # info was right; on a closed server a signup should only happen
              # when Viktor deliberately runs `!admin users create-user`, so
              # anything else means allow_registration has regressed.
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary     = "New Matrix signup: {{ $labels.mxid }} from {{ $labels.client_ip }}"
                description = "Client/device name: \"{{ $labels.device }}\". Registration on matrix.viktorbarzin.me has been CLOSED since 2026-08-15, so this is expected only if you just created the account yourself with `!admin users create-user`. If you did not, check that TUWUNEL_ALLOW_REGISTRATION is still false in stacks/matrix (a regression there reopens the server to strangers), then `!admin users deactivate {{ $labels.mxid }}` in the admin room."
              }
            },
          ]
        },
        {
          # Vaultwarden vault CLI (`homelab vault`) traceability. The audit SPINE
          # is the Vault audit device (reads of secret/data/workstation/claude-users/*
          # are already captured in the vault-tail stream above). These add
          # visibility/anomaly alerts off the per-user CLI op-log
          # (`logger -t homelab-vault[-totp]` → devvm-journal). A true "Vault
          # creds-read with NO matching CLI op-log = direct bypass" alert needs
          # cross-stream correlation the Loki ruler can't express — tracked as a
          # follow-up (small correlation CronJob). lane=security → #security.
          name = "Vaultwarden vault CLI"
          rules = [
            {
              alert  = "VaultwardenTOTPFetched"
              expr   = "sum by (user) (count_over_time({job=\"devvm-journal\", identifier=\"homelab-vault-totp\"} | logfmt [5m])) > 0"
              for    = "0m"
              labels = { severity = "info", lane = "security" }
              annotations = {
                summary     = "Vaultwarden TOTP (2nd factor) fetched via homelab vault by {{ $labels.user }}"
                description = "A TOTP code was retrieved with `homelab vault code`. A stored TOTP co-located with its password collapses that downstream account's 2FA to 1FA under a same-UID compromise — confirm this fetch was expected."
              }
            },
            {
              alert  = "VaultwardenFetchVolumeHigh"
              expr   = "sum by (user) (count_over_time({job=\"devvm-journal\", identifier=\"homelab-vault\"} | logfmt | verb=~\"get|code\" [10m])) > 100"
              for    = "0m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary     = "Unusually high homelab vault fetch volume (>100/10m) for {{ $labels.user }}"
                description = "A burst of credential fetches for one user — possible runaway loop or exfiltration. Cross-check the op-log parent process and the Vault audit stream (namespace=vault,container=audit-tail) for reads of secret/data/workstation/claude-users/{{ $labels.user }}."
              }
            },
          ]
        },
        {
          # Mail delivery failures (added 2026-08-21). Calibre-Web's "Send to
          # Kindle" had been failing since the 2025-11-30 migration to
          # calibre-web-automated, and nothing watched postfix's refusals, so it
          # stayed invisible until someone noticed the books never arrived.
          # Background on the credential itself: the init_container comment in
          # stacks/ebooks/main.tf.
          #
          # Thresholds are measured, not guessed — checked against the full 30d
          # Loki retention on 2026-08-21: the in-cluster reject filter matched 13
          # lines in 30 days (all of them that one incident), and status=bounced
          # and status=deferred each matched zero. So >0 really is the noise
          # floor here. Rejecting inbound spam is constant and wanted, which is
          # why none of these rules look at rejects in general.
          #
          # That gap is now closed. When this group shipped, 192.168.1.127
          # (helo=pve.local) was being refused ~100-200x/24h and a rule for it
          # would have fired continuously, so the class was left out. The cause
          # turned out to be in-cluster reverse DNS rather than a missing record
          # (fixed 2026-08-22), and InternalHostCannotSendMail below now covers
          # it against a zero floor.
          #
          # Route: Loki ruler -> Alertmanager -> #alerts.
          name = "Mail delivery"
          rules = [
            {
              # One of our own services was refused relay. Postfix resolves
              # in-cluster clients to *.svc.cluster.local, and an internet
              # sender cannot forge that into the client position, so this
              # separates "a service of ours cannot send mail" from ordinary
              # spam rejection. The usual cause is credentials: mynetworks is
              # deliberately empty, so SASL AUTH is the only relay path, and a
              # service that fails to authenticate lands here.
              alert  = "ClusterServiceCannotRelayMail"
              expr   = "sum(count_over_time({namespace=\"mailserver\"} |= \"NOQUEUE: reject\" |~ `svc\\.cluster\\.local\\[` [15m])) > 0"
              for    = "5m"
              labels = { severity = "warning", subsystem = "mail" }
              annotations = {
                summary     = "An in-cluster service is being refused mail relay"
                description = "A pod tried to send mail through the mailserver and was refused. Find the sender and the reason with: homelab logs query '{namespace=\"mailserver\"} |= \"NOQUEUE: reject\" |~ `svc.cluster.local[`' --since 1h — the line carries from=, to= and the helo, and the helo is the pod IP. A reject line with no sasl_username= means the client never authenticated, which is what happens when its stored password is unusable; check the sending service's SMTP credential against the secret it reads."
              }
            },
            {
              # A host of ours failed SASL AUTH. The constant background of
              # failed logins comes from public IPs guessing usernames; scoping
              # to private client IPs leaves only our own senders, where a
              # failure means a real credential problem (rotated secret, stale
              # copy) that is about to turn into undelivered mail.
              alert  = "InternalMailAuthFailure"
              expr   = "sum(count_over_time({namespace=\"mailserver\"} |~ `SASL (LOGIN|PLAIN) authentication failed` |~ `\\[(10\\.|192\\.168\\.)` [15m])) > 0"
              for    = "5m"
              labels = { severity = "warning", subsystem = "mail" }
              annotations = {
                summary     = "A host on the internal network is failing SMTP authentication"
                description = "SASL AUTH is failing for a client on 10.x or 192.168.x — our own network, not an internet password-guesser. The sasl_username= on the log line names the account. Most likely its password was rotated in Vault while a consumer still holds the old copy. Check the failing service's secret and, for Calibre-Web specifically, that the seed-smtp-password init container ran clean."
              }
            },
            {
              # Permanent delivery failure after we accepted the message.
              # Outbound mail leaves via the Brevo smarthost, so a rejection by
              # the far end (Amazon refusing a Send-to-Kindle address that is no
              # longer approved, for instance) comes back as a bounce rather
              # than an SMTP error the sending app can see.
              alert  = "OutboundMailBounced"
              expr   = "sum(count_over_time({namespace=\"mailserver\"} |= \"status=bounced\" [1h])) > 0"
              for    = "0m"
              labels = { severity = "warning", subsystem = "mail" }
              annotations = {
                summary     = "Mail we accepted has bounced"
                description = "Postfix logged status=bounced, so a message was accepted from a sender and then permanently rejected downstream — the sending application already reported success. Read the reason with: homelab logs query '{namespace=\"mailserver\"} |= \"status=bounced\"' --since 2h. For Send-to-Kindle, a bounce from Amazon usually means the From address is not on that Kindle's approved-sender list, or the @kindle.com address has changed."
              }
            },
            {
              # Sustained queue deferrals. A lone deferral is normal (remote
              # greylisting) and clears itself, so this waits for a handful
              # rather than firing on the first one.
              alert  = "OutboundMailDeferred"
              expr   = "sum(count_over_time({namespace=\"mailserver\"} |= \"status=deferred\" [1h])) > 5"
              for    = "15m"
              labels = { severity = "warning", subsystem = "mail" }
              annotations = {
                summary     = "Mail is piling up deferred in the queue (>5/1h)"
                description = "More than five deferrals in an hour, against a 30d baseline of zero — mail is sitting in the queue rather than being delivered. Check the queue and the reason: kubectl -n mailserver exec deploy/mailserver -- postqueue -p, then homelab logs query '{namespace=\"mailserver\"} |= \"status=deferred\"' --since 2h. Common causes are the Brevo smarthost refusing or throttling us, and DNS resolution failing for the destination."
              }
            },
            {
              # A host on our own network refused relay for a reason other than
              # authentication. In practice that means reverse DNS, since
              # smtpd_sender_restrictions ends in reject_unknown_client_hostname:
              # a client whose PTR is missing, or does not forward-confirm, is
              # turned away with 450 4.7.25 and its mail is retried until the
              # sending host gives up.
              #
              # Left out when this group shipped on 2026-08-21 because the
              # Proxmox host was tripping it 100-217x/24h and the rule would
              # have fired continuously. That was fixed on 2026-08-22 (CoreDNS
              # gained a 1.168.192.in-addr.arpa block so pods can resolve LAN
              # reverse DNS at all), and the floor is now zero, so >0 means
              # something real.
              #
              # for=15m on purpose: a CoreDNS or Technitium blip makes reverse
              # DNS fail for a few seconds and the sending host simply retries,
              # so a shorter window would page for something that heals itself.
              # Fifteen minutes of a host unable to send mail is still caught
              # long before a person would notice.
              alert  = "InternalHostCannotSendMail"
              expr   = "sum(count_over_time({namespace=\"mailserver\"} |= \"cannot find your hostname\" |~ `\\[(10\\.|192\\.168\\.)` [15m])) > 0"
              for    = "15m"
              labels = { severity = "warning", subsystem = "mail" }
              annotations = {
                summary     = "An internal host is being refused mail relay — reverse DNS is failing"
                description = "A host on 10.x or 192.168.x is getting 450 4.7.25 'cannot find your hostname', so its mail is not being accepted and will sit in its queue until it gives up. Find the host: homelab logs query '{namespace=\"mailserver\"} |= \"cannot find your hostname\"' --since 1h. Then check reverse DNS the way postfix does, from inside a pod: dig -x <ip> must return a name, and that name must resolve back to the same address. If the PTR resolves against Technitium (dig -x <ip> @10.96.0.53) but not through CoreDNS, the zone is missing a block in stacks/technitium/modules/technitium/main.tf — that was the 2026-08-22 fault, which had been silently discarding the nightly Proxmox backup report for a month."
              }
            },
          ]
        },
        {
          # Terminal-lobby transport health (added 2026-08-28). ttyd logs one
          # `WS   /ws - <ip>, clients: N` line per SUCCESSFUL WebSocket upgrade,
          # so counting that line counts terminals that actually attached — not
          # page loads, not TCP connections. devvm's journal already ships it;
          # no exporter and no code needed.
          #
          # Why this exists: terminal mode did not connect from any touch device
          # between 25 and 28 Aug 2026 (a temporal-dead-zone ReferenceError in
          # term.html rejected the whole page IIFE before `/token` and
          # `new WebSocket(...)` ever ran, so a phone loaded the lobby and never
          # attached while a desktop was unaffected). The collapse was plainly
          # visible in this exact stream the whole time and nothing was watching,
          # which is what cost three days — the same shape as the Vault
          # audit-volume incident the same week. Fixed by terminal-lobby 89b0ed7.
          # Runbook: docs/runbooks/terminal-lobby-upgrades.md.
          name = "Terminal Lobby"
          rules = [
            {
              # Threshold measured against the real incident, not guessed
              # (verified 2026-08-28 by evaluating this expr at each day's
              # 23:59Z): 22 Aug 227, 23 Aug 259 — healthy; 24 Aug 73, 25 Aug 57
              # — degrading; 26 Aug 1, 27 Aug 11 — dead. `< 50` fires on the two
              # dead days, stays quiet on the healthy baseline, and leaves ~4x
              # headroom for a genuinely quiet day.
              #
              # 24h window, NOT an hourly rate: terminals are driven by a person,
              # so an hourly threshold false-fires every night. A 24h window
              # spans a full usage cycle.
              #
              # Known limit — this catches DEAD, not DEGRADED. 25 Aug sat at 57
              # and would not have fired, because desktop was still connecting
              # normally; only when touch was effectively the only traffic left
              # did the total collapse. Catching it on 26 Aug is still two days
              # earlier than it was actually found. A baseline-ratio rule would
              # also catch the partial regression, but needs a recording rule
              # plus a trailing comparison — worth revisiting if a partial
              # regression recurs, not worth the machinery today.
              #
              # severity=warning deliberately, per the severity hygiene settled
              # this week (QBittorrentDisconnected critical -> warning):
              # `critical` is for things that are down for everyone right now. A
              # transport regression is serious and slow-burning, not a 3am page.
              # Warnings still post to #alerts.
              #
              # `or vector(0)` is LOAD-BEARING, not defensive padding. A bare
              # `sum(count_over_time(...))` returns NO SERIES when nothing
              # matches, so `< 50` yields an empty result and the alert stays
              # SILENT on a total outage — it would have fired on 26 Aug (1) and
              # 27 Aug (11) but said nothing at 0, the worst case. Verified live
              # 2026-08-28 against a filter matching no lines: bare expr empty,
              # `or vector(0)` returns 0 and fires. It also covers the journal
              # shipping stopping entirely (nonexistent unit → 0, verified the
              # same way), which reads as "terminals are dead" — correct enough
              # at warning severity, since both need someone to look.
              alert  = "TerminalUpgradesCollapsed"
              expr   = "(sum(count_over_time({job=\"devvm-journal\", unit=\"ttyd.service\"} |= \"WS   /ws\" [24h])) or vector(0)) < 50"
              for    = "2h"
              labels = { severity = "warning" }
              annotations = {
                summary     = "Terminal upgrades have collapsed ({{ $value }} in 24h, baseline ~250)"
                description = <<-EOT
                  Almost nobody's terminal is attaching. ttyd logs one line per
                  successful WebSocket upgrade and that count has fallen to
                  {{ $value }} over 24h, against a ~227-259/day healthy baseline.
                  Check ttyd FIRST, because the two branches need different fixes
                  and the interesting one looks like nothing is wrong:
                  `systemctl status ttyd` on the devvm. If ttyd is DOWN it is an
                  ordinary service problem. If ttyd is UP and healthy — which it
                  was throughout the 25-28 Aug outage — the page is failing before
                  it ever opens a socket, so look at the frontend's own boot
                  telemetry rather than the backend. The runbook carries both
                  branches and the exact queries.
                EOT
                runbook     = "docs/runbooks/terminal-lobby-upgrades.md"
              }
            },
          ]
        },
        {
          # Immich share-link analytics (recording rules → Prometheus
          # remote-write, 2026-07-06). Continuous per-slug counters that
          # OUTLIVE Loki's 30d log retention (Prometheus keeps 26w): a shared
          # album link lives up to a year, so ad-hoc log sweeps can't answer
          # "total visits" after week 4. Query totals with e.g.
          # sum_over_time(immich:share_link_opens:count1m{slug="x"}[90d]).
          # CARDINALITY / INJECTION GUARDS — all four are load-bearing:
          # (1) slug extraction is ANCHORED to the JSON key `"RequestPath":"`,
          #     because the line also carries attacker-controlled User-Agent and
          #     Referer values — an unanchored regexp would let any client mint
          #     arbitrary slug label values via a crafted header (Prometheus
          #     cardinality bomb). This anchor is STRONGER than the CLF byte
          #     position it replaced (2026-09-01, when the access log became
          #     JSON): Traefik escapes `"` as `\"` inside every string value, so
          #     the literal sequence `"RequestPath":"` cannot appear inside a
          #     header value at all, and `[^"]*` can never cross out of one
          #     field into another. Verified on traefik:v3.7.1 by sending
          #     `User-Agent: x","RequestPath":"/s/EVILSLUG",...` — the log line
          #     carries it as `x\",\"RequestPath\":\"/s/EVILSLUG` and neither
          #     rule matches it.
          # (2) status 2xx/304 required — Immich 404s unknown /s/<slug> and 401s
          #     API calls with a bad ?slug=, so junk-slug probes don't mint
          #     series. Read from the DownstreamStatus field, not a position.
          # (3) the slug charset regex bounds label values.
          # (4) `container="traefik"` keeps the nginx auth-proxy and
          #     bot-block-proxy streams — still CLF, same namespace — out of the
          #     scan entirely. `|= "immich-immich"` (main immich router token;
          #     kiosk immich-frame routers don't match) is only a scan
          #     prefilter — false positives are dropped by the anchors.
          # NOTE ON `\\u0026`: Traefik's JSON encoder HTML-escapes `&` inside
          # values, so a query string reaches Loki as `?size=preview\u0026slug=`.
          # The requests rule must accept both separators; matching a bare `&`
          # alone silently returns zero. Found by capturing a real line rather
          # than reasoning about it.
          # Complemented by the daily share-link-geo CronJob
          # (share_link_analytics.tf) for unique-IP + per-country gauges
          # (exact distincts need IP-level data that doesn't belong in
          # Prometheus labels).
          name     = "Immich Share Link Analytics"
          interval = "1m"
          rules = [
            {
              # Page opens: successful GET/HEAD of the share page /s/<slug>.
              record = "immich:share_link_opens:count1m"
              expr   = "sum by (slug) (count_over_time({namespace=\"traefik\", container=\"traefik\"} |= \"immich-immich\" |~ `\"RequestMethod\":\"(GET|HEAD)\"` |~ `\"RequestPath\":\"/s/` | regexp `\"RequestPath\":\"/s/(?P<slug>[A-Za-z0-9][A-Za-z0-9_-]{0,63})[?/\"]` | slug != \"\" | json status=\"DownstreamStatus\" | status =~ \"2..|304\" [1m]))"
              labels = { source = "loki-ruler" }
            },
            {
              # Browsing volume: successful API/asset requests carrying
              # ?slug=<slug> in the request path (thumbnails, originals, video).
              record = "immich:share_link_requests:count1m"
              expr   = "sum by (slug) (count_over_time({namespace=\"traefik\", container=\"traefik\"} |= \"immich-immich\" |= \"slug=\" | regexp `\"RequestPath\":\"[^\"]*(?:[?&]|\\\\u0026)slug=(?P<slug>[A-Za-z0-9][A-Za-z0-9_-]{0,63})` | slug != \"\" | json status=\"DownstreamStatus\" | status =~ \"2..|304\" [1m]))"
              labels = { source = "loki-ruler" }
            },
          ]
        }
      ]
    })
  }
}

resource "kubernetes_config_map" "grafana_loki_datasource" {
  metadata {
    name      = "grafana-loki-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "loki-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Loki"
        type      = "loki"
        access    = "proxy"
        url       = "http://loki.monitoring.svc.cluster.local:3100"
        isDefault = false
      }]
    })
  }
}
