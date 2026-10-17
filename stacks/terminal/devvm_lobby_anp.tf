# --- in-cluster reach to the devvm Lobby ports: policy data ---
# The devvm's nftables admits the Traefik NODE addresses, and Calico SNATs
# every pod's egress to its node address, so without these policies any pod on
# those nodes could reach ttyd (7681, header-trust auth) or skip Traefik's
# limits and CrowdSec on 8710. A ClusterNetworkPolicy in tier Admin is
# evaluated before namespace NetworkPolicies and Calico's default tier, and
# traffic it does not match continues to them unchanged.
#
# ClusterNetworkPolicy (policy.networking.k8s.io/v1alpha2), not
# AdminNetworkPolicy (v1alpha1): Calico 3.32 dropped ANP/BANP enforcement, and
# after our 3.33 upgrade (2026-10-12) the ANPs were still served by the API but
# matched nothing, so every pod reached ttyd again (infra#123).
#
# This file holds only locals so tests/devvm-lobby-anp.test.sh can evaluate it
# with `terraform console` and check who reaches which port. The resources
# that apply it are in terminal_api.tf.
locals {
  devvm_lobby_network      = "10.0.10.10/32"
  devvm_lobby_port_numbers = [7681, 7683, 7684, 7685, 7686, 7687, 7688, 7690, 8710]
  # 7690 is tl-t3-view, the lobby's T3 view (terminal-lobby ADR-0044).

  devvm_lobby_ports = [
    { tcp = { destinationPort = { number = 7681 } } },
    { tcp = { destinationPort = { range = { start = 7683, end = 7688 } } } },
    { tcp = { destinationPort = { number = 7690 } } },
    { tcp = { destinationPort = { number = 8710 } } },
  ]

  # Namespaces that need exactly one Lobby port, each with its own policy.
  # One shared policy would let every namespace in it reach every port any of
  # them needs.
  devvm_lobby_observers = {
    # the subnet-router probe checks ttyd (stacks/headscale/subnet-router-probe.tf)
    headscale = { port = 7681, priority = 11 }
    # Prometheus scrapes tmux-api metrics (prometheus_chart_values.tpl)
    monitoring = { port = 7684, priority = 12 }
  }

  devvm_lobby_cnps = merge(
    {
      "devvm-lobby-ports" = {
        tier     = "Admin"
        priority = 10
        subject = {
          namespaces = {
            matchExpressions = [{
              key      = "kubernetes.io/metadata.name"
              operator = "NotIn"
              # traefik is the proxy itself; the observers get their own
              # policies below.
              values = concat(["traefik"], sort(keys(local.devvm_lobby_observers)))
            }]
          }
        }
        egress = [{
          name      = "deny-devvm-lobby"
          action    = "Deny"
          to        = [{ networks = [local.devvm_lobby_network] }]
          protocols = local.devvm_lobby_ports
        }]
      }
    },
    {
      for ns, o in local.devvm_lobby_observers : "devvm-lobby-ports-${ns}" => {
        tier     = "Admin"
        priority = o.priority
        subject = {
          namespaces = {
            matchExpressions = [{
              key      = "kubernetes.io/metadata.name"
              operator = "In"
              values   = [ns]
            }]
          }
        }
        egress = [{
          name   = "deny-devvm-lobby-except-${o.port}"
          action = "Deny"
          to     = [{ networks = [local.devvm_lobby_network] }]
          protocols = [
            for p in local.devvm_lobby_port_numbers :
            { tcp = { destinationPort = { number = p } } } if p != o.port
          ]
        }]
      }
    },
  )
}
