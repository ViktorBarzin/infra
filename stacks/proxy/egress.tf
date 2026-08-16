# Cluster VPN egress — the permanent United Kingdom gateway.
#
# Design: docs/plans/2026-08-16-cluster-vpn-egress-service-design.md
#
# ONE gateway pod, TWO products, ONE NordVPN tunnel:
#
#   * Remote browsers (the existing stacks/proxy product) join over WireGuard on
#     Service `proxy-gw-1` (UDP 51820) and are FORWARDED out `tun0` by the
#     wgserver sidecar (ip_forward + MASQUERADE + the return-path `ip rule`,
#     memory #10214).
#   * Cluster workloads point HTTPS_PROXY / ALL_PROXY at Service
#     `proxy-egress-uk` (TCP 8888 HTTP proxy, TCP 1080 SOCKS5). Those are
#     gluetun's own userspace listeners running INSIDE the tunnel netns: they
#     terminate the client connection and RE-ORIGINATE the request out `tun0`.
#     That is local origination, not forwarding, so a consumer needs no
#     capabilities, no sidecar and no netns sharing — only an env var.
#
# Both share the single tunnel this pod holds. Serving both from one gateway
# avoids a second UK tunnel on the account-wide NordLynx key, which pool.py
# documents as a hard invariant (one gateway per distinct country).
#
# Tunnel budget is UNCHANGED: this gateway occupies gateway index 1, one of the
# existing `MAX_COUNTRIES` slots in pool.py. The broker reserves that index —
# `alloc_subnet_idx` never hands it out, `plan_gateway` always answers "reuse"
# for United Kingdom, and `plan_reaping` never reaps it — so the two sides
# cannot collide. Index 1 => client subnet 10.13.1.0/24, gateway at 10.13.1.1.
#
# Access control is deliberately OPEN to the whole cluster (design decision 9):
# no NetworkPolicy, no proxy credentials. A NetworkPolicy allowlist is the
# natural first hardening step if the cluster's tenancy assumptions change.
#
# Consumer contract:
#   HTTPS_PROXY / HTTP_PROXY = http://proxy-egress-uk.proxy.svc.cluster.local:8888
#   ALL_PROXY (httpx/requests) = the same URL — one variable covers both schemes
#   SOCKS5: socks5h://proxy-egress-uk.proxy.svc.cluster.local:1080  (the `h` is
#           load-bearing — plain socks5:// resolves locally via CoreDNS, which
#           both leaks the lookup and can return home-geo answers)
#   NO_PROXY must list the in-cluster suffixes, or in-cluster calls take a round
#           trip through the UK and arrive from an unexpected source address.

locals {
  # Gateway index 1 is the permanent slot (pool.PERMANENT_IDX). Names must match
  # broker.py's `_gw_name(1)` byte-for-byte — the broker resolves the Service and
  # the peers ConfigMap by those names.
  egress_idx     = 1
  egress_name    = "proxy-gw-${local.egress_idx}"
  egress_country = "United Kingdom"
  # broker.py `_label("United Kingdom")` — the pod label the broker and UI read.
  egress_country_label = "united-kingdom"
  # pool.gateway_subnet(1) / pool.gateway_ip(1), with pool.GW_SUBNET_PREFIX = 10.13.
  egress_subnet = "10.13.${local.egress_idx}.0/24"
  egress_gw_ip  = "10.13.${local.egress_idx}.1"

  # Pod labels the broker's `list_gateways()` selects and indexes on. Both keys
  # are mandatory: broker.py reads `md["labels"]["proxy/gw-idx"]` with a bare
  # dict index, so a pod carrying `app=proxy-gateway` WITHOUT `proxy/gw-idx`
  # raises KeyError and takes down the whole reaper tick.
  egress_selector = {
    "app"          = "proxy-gateway"
    "proxy/gw-idx" = tostring(local.egress_idx)
  }
  egress_pod_labels = merge(local.egress_selector, {
    "proxy/country"   = local.egress_country_label
    "proxy/permanent" = "true"
  })

  # The wg-server sidecar script. Kept byte-equivalent to `build_gw_pod`'s
  # `wg_script` in files/broker/broker.py with idx=1 substituted — the on-demand
  # gateways and this one must behave identically. Change both together.
  # The `ip rule ... lookup main pref 90` line is the non-obvious return-path fix
  # from memory #10214: without it, replies from tun0 to a WireGuard client are
  # routed by gluetun's own table and never reach wg0.
  egress_wg_script = <<-EOT
    set -x
    for i in $(seq 1 120); do ip link show tun0 >/dev/null 2>&1 && break; sleep 2; done
    ip link show tun0 || { echo TUN0_NEVER_UP; sleep 3600; }
    ip link add wg0 type wireguard 2>/dev/null || true
    wg set wg0 private-key /gw-wg/privkey listen-port 51820
    ip addr add ${local.egress_gw_ip}/24 dev wg0 2>/dev/null || true
    ip link set wg0 up
    iptables -t nat -C POSTROUTING -s ${local.egress_subnet} -o tun0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s ${local.egress_subnet} -o tun0 -j MASQUERADE
    iptables -C FORWARD -i wg0 -o tun0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i wg0 -o tun0 -j ACCEPT
    iptables -C FORWARD -i tun0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i tun0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    ip rule show | grep -q 'to ${local.egress_subnet} lookup main' || ip rule add to ${local.egress_subnet} lookup main pref 90
    echo GATEWAY_READY
    while true; do
      if [ -f /peers/peers ]; then
        while read pub aip; do [ -n "$pub" ] && wg set wg0 peer "$pub" allowed-ips "$aip"; done < /peers/peers
        want=$(awk '{print $1}' /peers/peers | sort -u)
        for p in $(wg show wg0 peers); do echo "$want" | grep -qx "$p" || wg set wg0 peer "$p" remove; done
      fi
      sleep 10
    done
  EOT
}

# --- Adoption of the two index-1 objects that already exist in-cluster --------
# `proxy-gw-1` (Service) and `proxy-gw-1-peers` (ConfigMap) were created by the
# broker for an earlier, on-demand gateway and outlived its Pod (the orphaned-
# gateway bug, design §3). They are live right now, so a plain create would fail
# with `already exists`. These blocks are idempotent — a no-op once the objects
# are in state — and may be removed after the next green apply. Same class as
# stacks/monitoring/imports.tf and stacks/tasks/imports.tf.
import {
  to = kubernetes_service.proxy_gw_1
  id = "proxy/proxy-gw-1"
}

import {
  to = kubernetes_config_map_v1.proxy_gw_1_peers
  id = "proxy/proxy-gw-1-peers"
}

# --- Peers ConfigMap — created here, CONTENTS owned by the broker ------------
# The broker rewrites `data.peers` every reaper tick (`update_gw_peers`, ~60s)
# and on every browser create; the sidecar reconciles wg0 from it. Terraform
# only guarantees the object exists so the pod's optional volume mount has
# something to bind — `ignore_changes = [data]` keeps the two from fighting on
# every apply. Do NOT remove that ignore: without it, each apply would blank the
# peer list and deregister every browser on this gateway.
resource "kubernetes_config_map_v1" "proxy_gw_1_peers" {
  metadata {
    name      = "${local.egress_name}-peers"
    namespace = local.namespace
    labels    = local.egress_selector
  }
  data = {
    peers = "\n"
  }
  lifecycle {
    ignore_changes = [data]
  }
}

# --- The permanent gateway ---------------------------------------------------
resource "kubernetes_deployment" "proxy_gw_uk" {
  metadata {
    name      = local.egress_name
    namespace = local.namespace
    labels    = merge(local.labels, local.egress_selector)
    annotations = {
      # The NordLynx key is account-wide and rotates on multi-device login
      # (memory #8307). The broker re-fetches it into Secret `nordvpn-wg` and
      # an on-demand gateway picks the new value up at spawn — an always-on pod
      # holds it in an env var, which never hot-reloads. Reloader restarts this
      # Deployment when the Secret changes.
      # NOTE: this only fires if something actually re-fetches the key. The
      # broker calls `ensure_nordvpn_secret()` at startup and on the gateway-
      # CREATE path, which this gateway never takes, so a periodic re-fetch in
      # the broker's reaper loop is what makes this annotation live.
      "secret.reloader.stakater.com/reload" = "nordvpn-wg"
    }
  }
  spec {
    # This pod requests the `net.ipv4.ip_forward` unsafe sysctl, which the
    # kubelet only permits when the node lists it in `allowedUnsafeSysctls`.
    # Without it the pod is rejected at admission with `SysctlForbidden` and the
    # ReplicaSet retries in a tight loop (27 rejected pods in ~40s, observed
    # 2026-08-16). Restored on node2-5 the same day; verify with:
    #   kubectl get --raw /api/v1/nodes/k8s-node3/proxy/configz \
    #     | jq .kubeletconfig.allowedUnsafeSysctls
    #
    # That allowlist does not survive a Kubernetes upgrade on its own:
    # `kubeadm upgrade node` rewrites /var/lib/kubelet/config.yaml from the
    # cluster-wide `kube-system/kubelet-config` ConfigMap, which wiped it (and
    # the rest of the post-join tune) on all five nodes during the v1.35.7
    # upgrade on 2026-07-26/27. Drift check: `scripts/check-node-kubelet-tune`.
    replicas = 1
    strategy {
      # Recreate, never RollingUpdate: two pods would briefly hold two NordVPN
      # tunnels to the same country on one account-wide NordLynx key.
      type = "Recreate"
    }
    selector {
      # Narrow enough that this Deployment can never adopt a broker-created
      # gateway pod: those carry other `proxy/gw-idx` values (index 1 is
      # reserved in pool.py). Browser pods also carry `proxy/gw-idx`, which is
      # why `app=proxy-gateway` has to be in here too.
      match_labels = local.egress_selector
    }
    template {
      metadata {
        labels = local.egress_pod_labels
        annotations = {
          # `list_gateways()` reads the country from this annotation.
          "proxy/country-name" = local.egress_country
          # DELIBERATELY ABSENT — `proxy/wg-pub` and `proxy/last-used`:
          #   * `proxy/wg-pub` must be the public half of the private key in
          #     Secret `proxy-gw-1-wg`. Terraform cannot derive an X25519 public
          #     key, and a hardcoded value would silently desync if the Secret is
          #     ever regenerated (browsers would then hand out a key the gateway
          #     does not hold — handshakes fail with no log on either side). The
          #     broker owns the keypair (wgkeys.py) and stamps this annotation on
          #     the running POD, which its RBAC allows (it has no `apps` access).
          #   * `proxy/last-used` is a timestamp; a literal one in a pod template
          #     is stale the moment it is written, and generating one per apply
          #     would roll the tunnel on every apply. `list_gateways()` defaults
          #     it to 0 and `plan_reaping` skips PERMANENT_IDX, so THIS broker
          #     never reads it. A broker build that PREDATES PERMANENT_IDX does:
          #     it reads the missing annotation as "idle since the epoch" and its
          #     delete_gateway would strip this gateway's Service, peers ConfigMap
          #     and WireGuard Secret out from under the running pod. Two things
          #     close that window: the broker Deployment now carries a
          #     `checksum/broker-scripts` annotation (main.tf) so Terraform rolls
          #     it and WAITS before `depends_on` lets this Deployment be created,
          #     and the new broker stamps `proxy/last-used` once on any gateway
          #     pod that lacks it (`_stamp_gw_last_used_if_absent`).
        }
      }
      spec {
        # net.ipv4.ip_forward is an unsafe sysctl the kubelet only allows on
        # node2-5 (see kubernetes_labels.gateway_nodes in main.tf); a pod
        # requesting it elsewhere is rejected SysctlForbidden.
        node_selector = {
          "proxy.viktorbarzin.me/gateway" = "true"
        }
        security_context {
          sysctl {
            name  = "net.ipv4.ip_forward"
            value = "1"
          }
        }
        # Resolve through gluetun's own DoT resolver on loopback, so DNS for a
        # proxied request is answered inside the tunnel netns rather than
        # leaking to CoreDNS (and returning home-geo answers).
        dns_policy = "None"
        dns_config {
          nameservers = ["127.0.0.1"]
        }

        container {
          name = "gluetun"
          # Pinned, not `:latest`. Keel (policy=patch, hourly poll) resolves a
          # floating tag to a concrete one on the live Deployment, and Terraform
          # then reverts it on the next apply — the two fought and replaced this
          # pod six times in ~30 minutes on 2026-08-16, each round trip dropping
          # the NordVPN tunnel. That is worse here than on an ordinary app:
          # NordVPN refuses an over-limit connection with a ~10-minute cooldown
          # (memory #10182), so a looping gateway can lock itself out of its own
          # slot. This is the version Keel had settled on and which was verified
          # end to end. DIGEST-pinned, not a version tag, for a specific reason:
          # SOCKS5 is UNRELEASED. The newest gluetun RELEASE (v3.41.3, commit
          # 3d1e20c, 2026-07-30) has NO socks5 listener at all — pinning to it on
          # 2026-08-16 silently left Service port 1080 with nothing behind it.
          # This digest is the `:latest` build (commit 7eed6ea, 2026-08-07) that
          # was verified to carry BOTH the http proxy and socks5, end to end.
          # Same pattern as NEKO_IMAGE in main.tf. If you bump this, re-verify
          # `socks5` appears in the gluetun startup log before trusting :1080.
          image = "ghcr.io/qdm12/gluetun@sha256:e3272b29a4bc177b389fbdcb54cf9716ccbfc30f04d8b7a35b0a5be9cdb58461"
          security_context {
            capabilities {
              # Kernelspace WireGuard needs no /dev/net/tun, no privileged and
              # no device plugin (proven 2026-07-24) — this is why the proxy
              # namespace stays off the Kyverno security exclude list.
              add = ["NET_ADMIN", "SYS_MODULE"]
            }
          }
          env {
            name  = "VPN_SERVICE_PROVIDER"
            value = "nordvpn"
          }
          env {
            name  = "VPN_TYPE"
            value = "wireguard"
          }
          env {
            name  = "SERVER_COUNTRIES"
            value = local.egress_country
          }
          env {
            name  = "DOT"
            value = "on"
          }
          # gluetun's kill-switch DROPS inbound traffic to any port not listed
          # here. Loopback tests do not catch a missing entry — only a cross-pod
          # request does (`:6080` hit exactly this during the geo-browser build).
          # 51820 = WireGuard (browsers), 8888 = HTTP proxy, 1080 = SOCKS5.
          env {
            name  = "FIREWALL_INPUT_PORTS"
            value = "51820,8888,1080"
          }
          # Pod CIDR + Service CIDR so replies to in-cluster clients (both the
          # WireGuard browsers and the proxy consumers) leave outside the tunnel;
          # plus this gateway's own /24 of WireGuard clients.
          env {
            name  = "FIREWALL_OUTBOUND_SUBNETS"
            value = "10.10.0.0/16,10.96.0.0/12,${local.egress_subnet}"
          }
          # The two userspace listeners that make this a service, not just a
          # browser gateway. Verified present in the running image on 2026-08-16
          # (gluetun commit 7eed6ea, built 2026-08-07): the internal/socks5 and
          # internal/httpproxy packages are both linked into the binary and the
          # startup settings tree renders both sections. Defaults are :8888 and
          # :1080, so HTTPPROXY_LISTENING_ADDRESS / SOCKS5_LISTENING_ADDRESS are
          # not needed. HTTPPROXY_LOG exists; SOCKS5_LOG does NOT — gluetun errors
          # out on unknown env keys, so do not add it.
          # The image is unpinned (`:latest`, design decision 13), so re-check
          # these two variables after a gluetun bump.
          env {
            name  = "HTTPPROXY"
            value = "on"
          }
          env {
            name  = "SOCKS5_ENABLED"
            value = "on"
          }
          # No HTTPPROXY_USER / SOCKS5_USER: open to the whole cluster by design.
          env {
            name = "WIREGUARD_PRIVATE_KEY"
            value_from {
              secret_key_ref {
                # Broker-maintained (ensure_nordvpn_secret), NOT Terraform-owned.
                name = "nordvpn-wg"
                key  = "wg_key"
              }
            }
          }
          port {
            name           = "http-proxy"
            container_port = 8888
            protocol       = "TCP"
          }
          port {
            name           = "socks5"
            container_port = 1080
            protocol       = "TCP"
          }
          # gluetun's own HEALTHCHECK command: an ephemeral instance that queries
          # the long-running one's health server and exits 0/1 (~30ms, reads
          # cached state — it does not dial out itself). An httpGet probe is not
          # workable: the control server on :8000 requires auth on EVERY route in
          # current images (401 -> never Ready), and the health server binds
          # 127.0.0.1:9999 where the kubelet cannot reach it. This exec form needs
          # no env var, no extra port and no FIREWALL_INPUT_PORTS entry.
          #
          # This probe is what makes the VPNEgressGatewayDown alert meaningful —
          # without it a pod whose tunnel is dead still reads Ready (observed on
          # the live browser pod, 2026-08-16). Readiness is per-POD, so an
          # unhealthy gluetun drops this pod out of BOTH Services: fail-closed for
          # consumers, and a behaviour change for the browser path, which is why
          # failure_threshold is generous (3 x 30s = 90s) — gluetun restarts the
          # VPN itself every ~11s while failing, and one reconnect must not yank
          # live browser tunnels.
          #
          # NO liveness probe on this check, deliberately: gluetun already
          # self-heals the VPN, and killing the container mid-recovery risks
          # NordVPN's ~10-minute over-limit cooldown (memory #10182).
          readiness_probe {
            exec {
              command = ["/gluetun-entrypoint", "healthcheck"]
            }
            initial_delay_seconds = 20
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          resources {
            requests = { cpu = "20m", memory = "80Mi" }
            limits   = { memory = "256Mi" }
          }
        }

        container {
          name = "wgserver"
          # Pinned for the same reason as gluetun above.
          image = "ghcr.io/linuxserver/wireguard:1.0.20260223"
          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
          }
          command = ["bash", "-c", local.egress_wg_script]
          port {
            name           = "wg"
            container_port = 51820
            protocol       = "UDP"
          }
          volume_mount {
            name       = "gw-wg"
            mount_path = "/gw-wg"
            read_only  = true
          }
          volume_mount {
            name       = "peers"
            mount_path = "/peers"
            read_only  = true
          }
          resources {
            requests = { cpu = "10m", memory = "48Mi" }
            limits   = { memory = "128Mi" }
          }
        }

        volume {
          name = "gw-wg"
          secret {
            # This gateway's own WireGuard SERVER key — broker-owned, not
            # Terraform-owned (Terraform cannot generate an X25519 keypair; see
            # the pod-annotation note above). `ensure_permanent_gateway_secret()`
            # in files/broker/broker.py creates it if absent, at broker startup
            # and on every reaper tick, so a fresh cluster / DR restore converges
            # on its own; it NEVER replaces an existing key. Not optional here: a
            # missing Secret should hold the pod in ContainerCreating (visible as
            # PodStuckPending) rather than crash-loop a keyless wg0.
            # The script reads the file once at container start, so a rotated
            # key needs a pod restart, not just a remount.
            secret_name  = "${local.egress_name}-wg"
            default_mode = "0400"
          }
        }
        volume {
          name = "peers"
          config_map {
            name = kubernetes_config_map_v1.proxy_gw_1_peers.metadata[0].name
            # Optional so a pod restart is never blocked on the broker having
            # written the ConfigMap yet; the sidecar re-checks /peers every 10s.
            optional = true
          }
        }
      }
    }
  }

  # The tunnel comes up against an external provider, and readiness now gates on
  # tunnel health — a NordVPN over-limit cooldown (~10 min, memory #10182) must
  # not block the whole stack's apply. VPNEgressGatewayDown is the signal that a
  # gateway did not come back.
  wait_for_rollout = false

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].labels["tier"],             # stamped by Kyverno sync-tier-label-from-namespace

      # NOTE: do NOT add `spec[0].template[0].spec[0].container[N].image` here.
      # `ignore_changes` is POSITIONAL, and the live container order is
      # [wgserver, gluetun] while this file declares [gluetun, wgserver]. Adding
      # those two paths on 2026-08-16 made Terraform keep the live images at
      # positions 0 and 1 while applying the declared names in the other order,
      # which CROSSED them — the container called `gluetun` ran the WireGuard
      # image and vice versa, and egress went down until the images were pinned
      # explicitly below. Pinning is what removes the Terraform/Keel fight;
      # a positional ignore is not a safe substitute here.
    ]
  }

  depends_on = [
    # Secret `nordvpn-wg` is created by the broker, not by Terraform.
    kubernetes_deployment.broker,
    kubernetes_labels.gateway_nodes,
  ]
}

# --- Service 1/2: the WireGuard endpoint the remote browsers dial -------------
# Moves from broker-created to HCL-declared. gluetun's custom-WireGuard mode
# needs an endpoint IP rather than a name (memory #10222), so browsers are baked
# with this Service's ClusterIP — which the import above preserves.
resource "kubernetes_service" "proxy_gw_1" {
  metadata {
    name      = local.egress_name
    namespace = local.namespace
    labels    = local.egress_selector
  }
  spec {
    # `app=proxy-gateway` is load-bearing and differs from the broker's own
    # `build_gw_service`, which selects on `proxy/gw-idx` ALONE. Browser pods
    # carry that same label, so a gw-idx-only selector resolves this Service to
    # a BROWSER pod — live on 2026-08-16, where proxy-gw-1's only endpoint was
    # the browser dialling itself. `build_gw_service` needs the identical fix or
    # every on-demand gateway keeps the bug.
    selector = local.egress_selector
    port {
      name        = "wg"
      port        = 51820
      target_port = 51820
      protocol    = "UDP"
    }
  }
}

# --- Service 2/2: the consumer-facing proxy endpoint -------------------------
resource "kubernetes_service" "proxy_egress_uk" {
  metadata {
    name      = "proxy-egress-uk"
    namespace = local.namespace
    labels    = local.egress_selector
  }
  spec {
    # Same reasoning as proxy-gw-1: without `app=proxy-gateway` this VIP would
    # round-robin proxy clients onto browser pods, which listen on neither port.
    selector = local.egress_selector
    port {
      name        = "http-proxy"
      port        = 8888
      target_port = 8888
      protocol    = "TCP"
    }
    port {
      name        = "socks5"
      port        = 1080
      target_port = 1080
      protocol    = "TCP"
    }
  }
}
