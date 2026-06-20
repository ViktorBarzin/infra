# =============================================================================
# cs-firewall-bouncer — in-kernel (nftables) enforcement DaemonSet
# =============================================================================
# CrowdSec currently enforces NOTHING at the network layer: the Traefik Yaegi
# (lua) bouncer plugin is dead, so banned IPs still reach Traefik. For DIRECT
# (non-Cloudflare-proxied) hosts we drop banned source IPs IN-KERNEL via
# cs-firewall-bouncer's nftables backend — the packet is dropped before it ever
# reaches Traefik, costing zero per-request hops.
#
# Topology this respects (do NOT change without re-reading docs/architecture/networking.md):
#   - Calico CNI + kube-proxy in IPTABLES mode (NOT eBPF).
#   - Traefik is a LoadBalancer Service at 10.0.20.203, externalTrafficPolicy=Local
#     (real client IP preserved — that's the whole point of the dedicated .203 IP).
#   - LB traffic is DNAT'd to the Traefik POD, so the original source IP survives
#     into the `forward` netfilter hook. The drop rule MUST therefore cover the
#     `forward` hook, not only `input` (a pod-destined packet traverses forward,
#     not input, on the node). Hence nftables_hooks: [input, forward] below.
#
# Packaging: cs-firewall-bouncer publishes NO container image. We pin the
# official release binary (v0.0.34, 2025-08-04 — latest stable) and fetch it at
# runtime: an initContainer (curlimages/curl — has curl + tar, alpine) downloads
# + extracts the static binary into an emptyDir; the main container
# (debian:bookworm-slim) runs it. The nftables backend talks netlink DIRECTLY
# via github.com/google/nftables (go.mod + pkg/nftables/nftables.go: no os/exec)
# and the docs confirm "mode nftables relies on github.com/google/nftables to
# create table, chain and set" — so NO `nft` userspace CLI is needed and a plain
# slim base image suffices. The binary is built CGO_ENABLED=0 / -extldflags
# -static (Makefile), so it runs on glibc (debian) or musl (alpine) alike.
#
# Source: https://github.com/crowdsecurity/cs-firewall-bouncer
#         https://docs.crowdsec.net/u/bouncers/firewall/
#
# nodeSelector pins this to ONE node (k8s-node2, which runs a Traefik pod) for first validation.
# !!! REMOVING THE nodeSelector ROLLS THIS DAEMONSET CLUSTER-WIDE !!!
# Do that ONLY after the one-node validation checklist passes (see commit/PR).
# Validating on k8s-node2 (single node) before removing the nodeSelector to roll cluster-wide.

locals {
  # Pin a specific stable release. Bump deliberately (re-validate on one node first).
  firewall_bouncer_version  = "v0.0.34"
  firewall_bouncer_tgz_url  = "https://github.com/crowdsecurity/cs-firewall-bouncer/releases/download/${local.firewall_bouncer_version}/crowdsec-firewall-bouncer-linux-amd64.tgz"
  firewall_bouncer_bin_path = "/opt/firewall-bouncer/crowdsec-firewall-bouncer"
  firewall_bouncer_cfg_path = "/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"

  # Rendered firewall-bouncer config. Lives in a Secret (NOT a ConfigMap) because
  # it embeds api_key. Key names/structure verified against the reference config
  # (config/crowdsec-firewall-bouncer.yaml @ v0.0.34):
  #   - `set-only` uses a HYPHEN (not set_only).
  #   - `nftables_hooks` is a TOP-LEVEL list (sibling of `nftables:`, underscore).
  #   - `deny_action` values are uppercase DROP / REJECT.
  #   - `log_mode: stdout` sends logs to the container's stdout (default is `file`).
  #   - api_url carries a trailing slash (matches the reference default).
  firewall_bouncer_yaml = <<-YAML
    mode: nftables
    update_frequency: 10s
    log_mode: stdout
    log_level: info
    api_url: http://crowdsec-service.crowdsec.svc.cluster.local:8080/
    api_key: ${var.firewall_bouncer_key}
    insecure_skip_verify: false
    disable_ipv6: false
    deny_action: DROP
    deny_log: true
    nftables:
      ipv4:
        enabled: true
        set-only: false
        table: crowdsec
        chain: crowdsec-chain
        priority: -10
      ipv6:
        enabled: true
        set-only: false
        table: crowdsec6
        chain: crowdsec6-chain
        priority: -10
    nftables_hooks:
      - input
      - forward
  YAML
}

resource "kubernetes_secret" "firewall_bouncer_config" {
  metadata {
    name      = "crowdsec-firewall-bouncer-config"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec-firewall-bouncer"
      tier                     = var.tier
    }
    annotations = {
      # Rotate the pods if the API key / config ever changes (the binary reads
      # the config only at startup).
      "reloader.stakater.com/match" = "true"
    }
  }
  data = {
    "crowdsec-firewall-bouncer.yaml" = local.firewall_bouncer_yaml
  }
  type = "Opaque"
}

resource "kubernetes_daemon_set_v1" "firewall_bouncer" {
  metadata {
    name      = "crowdsec-firewall-bouncer"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec-firewall-bouncer"
      tier                     = var.tier
    }
  }
  spec {
    selector {
      match_labels = {
        "app.kubernetes.io/name" = "crowdsec-firewall-bouncer"
      }
    }
    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "crowdsec-firewall-bouncer"
          tier                     = var.tier
        }
        annotations = {
          # Bounce pods when the config Secret changes (api_key rotation etc.).
          "secret.reloader.stakater.com/reload" = kubernetes_secret.firewall_bouncer_config.metadata[0].name
        }
      }
      spec {
        priority_class_name = "tier-1-cluster"

        # Program the HOST's nftables ruleset (not the pod netns) — the bouncer's
        # drop rules must live in the host network namespace where DNAT'd LB
        # traffic transits the forward hook.
        host_network = true
        dns_policy   = "ClusterFirstWithHostNet"

        # ---- FIRST-VALIDATION PIN ----------------------------------------------
        # Pinned to a SINGLE node so a mistake in the nftables rules can only
        # affect one node. k8s-node2 is chosen because it currently runs a Traefik
        # pod — required to validate the `forward`-hook drop on DNAT'd LoadBalancer
        # traffic (under ETP=Local a node with no Traefik pod never sees that path,
        # so the validation would be meaningless there).
        # REMOVE this nodeSelector to roll the bouncer to EVERY node (the normal
        # end state for a firewall bouncer) — but ONLY after the one-node
        # validation checklist passes.
        node_selector = {
          "kubernetes.io/hostname" = "k8s-node2"
        }
        # ------------------------------------------------------------------------

        # initContainer fetches + extracts the pinned release binary into the
        # shared emptyDir. curlimages/curl is alpine and ships curl + tar.
        init_container {
          name  = "fetch-bouncer"
          image = "curlimages/curl:8.10.1"
          command = [
            "sh", "-c",
            <<-EOT
              set -eu
              echo "Downloading cs-firewall-bouncer ${local.firewall_bouncer_version}..."
              curl -fsSL "${local.firewall_bouncer_tgz_url}" -o /tmp/fb.tgz
              # Archive layout (verified @ v0.0.34): a single versioned top dir
              # `crowdsec-firewall-bouncer-vX.Y.Z/` containing the binary plus
              # config/, scripts/, install.sh. The curl image is BusyBox, whose
              # tar lacks GNU --wildcards/--strip-components selection — so extract
              # everything to a scratch dir, then cp ONLY the binary out via a
              # shell glob (`*/` matches the single versioned top dir).
              mkdir -p /tmp/fb-extract
              tar -xzf /tmp/fb.tgz -C /tmp/fb-extract
              cp /tmp/fb-extract/*/crowdsec-firewall-bouncer ${local.firewall_bouncer_bin_path}
              chmod +x ${local.firewall_bouncer_bin_path}
              echo "Fetched: $(ls -l ${local.firewall_bouncer_bin_path})"
            EOT
          ]
          volume_mount {
            name       = "binary"
            mount_path = "/opt/firewall-bouncer"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        container {
          name  = "firewall-bouncer"
          image = "debian:bookworm-slim"
          command = [
            local.firewall_bouncer_bin_path,
            "-c", local.firewall_bouncer_cfg_path,
          ]

          # nftables backend needs NET_ADMIN to program the host ruleset. NET_RAW
          # is the proven-safe companion the reference container images add. We
          # deliberately AVOID full `privileged: true` — these two caps are
          # sufficient for the netlink nftables path (no iptables/ipset shell-out
          # here). If validation shows rules are NOT being installed, the next
          # thing to try is privileged:true (see checklist) — but start minimal.
          security_context {
            capabilities {
              add = ["NET_ADMIN", "NET_RAW"]
            }
          }

          volume_mount {
            name       = "binary"
            mount_path = "/opt/firewall-bouncer"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = local.firewall_bouncer_cfg_path
            sub_path   = "crowdsec-firewall-bouncer.yaml"
            read_only  = true
          }

          # No liveness probe: the bouncer runs as PID 1, so a crash — or a bad
          # config that makes it exit non-zero at startup — surfaces on its own as
          # a pod restart / CrashLoopBackOff. This avoids coupling pod liveness to
          # a periodic LAPI round-trip (a brief LAPI blip must NOT bounce the pod).

          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            # crowdsec-quota enforces limits.memory on every pod in the ns.
            limits = {
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "binary"
          empty_dir {}
        }
        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret.firewall_bouncer_config.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}
