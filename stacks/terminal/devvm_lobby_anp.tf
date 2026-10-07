# --- in-cluster reach to the devvm Lobby ports: policy data ---
# The devvm's nftables admits the Traefik NODE addresses, and Calico SNATs
# every pod's egress to its node address, so without these policies any pod on
# those nodes could reach ttyd (7681, header-trust auth) or skip Traefik's
# limits and CrowdSec on 8710. AdminNetworkPolicy is evaluated before
# namespace NetworkPolicies and Calico's default tier, and traffic it does not
# match continues to them unchanged.
#
# This file holds only locals so tests/devvm-lobby-anp.test.sh can evaluate it
# with `terraform console` and check who reaches which port. The resources
# that apply it are in terminal_api.tf.
locals {
  devvm_lobby_network      = "10.0.10.10/32"
  devvm_lobby_port_numbers = [7681, 7683, 7684, 7685, 7686, 7687, 7688, 8710]

  devvm_lobby_ports = [
    { portNumber = { protocol = "TCP", port = 7681 } },
    { portRange = { protocol = "TCP", start = 7683, end = 7688 } },
    { portNumber = { protocol = "TCP", port = 8710 } },
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

  devvm_lobby_anps = merge(
    {
      "devvm-lobby-ports" = {
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
          name   = "deny-devvm-lobby"
          action = "Deny"
          to     = [{ networks = [local.devvm_lobby_network] }]
          ports  = local.devvm_lobby_ports
        }]
      }
    },
    {
      for ns, o in local.devvm_lobby_observers : "devvm-lobby-ports-${ns}" => {
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
          ports = [
            for p in local.devvm_lobby_port_numbers :
            { portNumber = { protocol = "TCP", port = p } } if p != o.port
          ]
        }]
      }
    },
  )
}
