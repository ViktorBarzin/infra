# bastion — jump-only SSH entry point on port 443.
#
# Clients wrap SSH in TLS and connect to ssh.viktorbarzin.me:443. Traefik's
# websecure entrypoint matches that SNI with an IngressRouteTCP, terminates TLS
# with the default wildcard cert, and forwards plain TCP to this sshd. From here
# a client can only ProxyJump to the PermitOpen targets in files/sshd_config;
# the Calico egress policy below enforces the same list at the network layer.
#
# Client accounts come from Vault secret/bastion: every authorized_key_<client>
# field becomes a nologin account named <client>. Adding or removing a client
# is a Vault write — the ExternalSecret syncs it and Reloader restarts the pod.
#
# Design: docs/plans/2026-09-28-ssh-bastion-443-design.md
# Runbook: docs/runbooks/bastion-ssh.md

variable "public_ip" { type = string }
variable "public_ipv6" { type = string }
variable "cloudflare_zone_id" { type = string }

locals {
  namespace = "bastion"
  hostname  = "ssh"
  labels = {
    app = "bastion"
  }
  # Keep in sync with PermitOpen in files/sshd_config (egress allowlist).
  targets = {
    devvm   = "10.0.10.10/32"
    pfsense = "10.0.20.1/32"
    pve     = "192.168.1.127/32"
  }
}

resource "kubernetes_namespace" "bastion" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.edge
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Host key + one authorized_key_<client> per client, from Vault secret/bastion.
resource "kubernetes_manifest" "keys" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "bastion-keys"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "5m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "bastion-keys"
      }
      dataFrom = [{
        extract = {
          key = "bastion"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.bastion]
}

resource "kubernetes_config_map" "conf" {
  metadata {
    name      = "bastion-conf"
    namespace = kubernetes_namespace.bastion.metadata[0].name
  }
  data = {
    "sshd_config"   = file("${path.module}/files/sshd_config")
    "entrypoint.sh" = file("${path.module}/files/entrypoint.sh")
  }
}

resource "kubernetes_deployment" "bastion" {
  metadata {
    name      = "bastion"
    namespace = kubernetes_namespace.bastion.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.edge
    })
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        automount_service_account_token = false
        container {
          name = "sshd"
          # Used only as an Alpine base that ships the OpenSSH server; the
          # image's s6 init is bypassed by the command below.
          image   = "lscr.io/linuxserver/openssh-server:10.3_p1-r1-ls237"
          command = ["sh", "/etc/bastion/conf/entrypoint.sh"]
          port {
            name           = "ssh"
            container_port = 22
          }
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
              # sshd privilege separation: chroot + drop to the client's uid.
              add = ["CHOWN", "SETUID", "SETGID", "SYS_CHROOT", "NET_BIND_SERVICE", "KILL"]
            }
          }
          # Exec probes, not tcp_socket: a TCP probe is an unauthenticated
          # connection that sshd logs three lines for, every period.
          readiness_probe {
            exec {
              command = ["sh", "-c", "kill -0 $(cat /run/bastion/sshd.pid)"]
            }
            period_seconds = 10
          }
          liveness_probe {
            exec {
              command = ["sh", "-c", "kill -0 $(cat /run/bastion/sshd.pid)"]
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
          volume_mount {
            name       = "conf"
            mount_path = "/etc/bastion/conf"
            read_only  = true
          }
          volume_mount {
            name       = "keys"
            mount_path = "/etc/bastion/keys"
            read_only  = true
          }
        }
        volume {
          name = "conf"
          config_map {
            name = kubernetes_config_map.conf.metadata[0].name
          }
        }
        volume {
          name = "keys"
          secret {
            secret_name  = "bastion-keys"
            default_mode = "0400"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],                      # LEGACY_TEMPLATE_ANNOTATIONS
    ]
  }
  depends_on = [kubernetes_manifest.keys]
}

resource "kubernetes_service" "bastion" {
  metadata {
    name      = "bastion"
    namespace = kubernetes_namespace.bastion.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      name        = "ssh"
      port        = 22
      target_port = 22
    }
  }
}

# Containment, ingress: only Traefik may connect in.
resource "kubernetes_network_policy_v1" "bastion" {
  metadata {
    name      = "bastion"
    namespace = kubernetes_namespace.bastion.metadata[0].name
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
            "kubernetes.io/metadata.name" = "traefik"
          }
        }
      }
      ports {
        port     = "22"
        protocol = "TCP"
      }
    }
  }
}

# Containment, egress: the pod may only connect out to the three targets on
# 22. Nothing else, not even DNS (targets are IPs).
#
# This has to be a Calico policy with an explicit Deny. A Kubernetes egress
# NetworkPolicy has no effect in this namespace: the Calico GNP
# wave1-egress-observe-tier34 (stacks/calico, order 2000) allows all egress
# for tier 3-edge/4-aux namespaces, and Kubernetes policies (order 1000) only
# add allows, so unmatched traffic falls through to that allow-all. Verified
# 2026-09-28: with only the Kubernetes policy, the pod reached 1.1.1.1:443.
resource "kubectl_manifest" "egress" {
  yaml_body = yamlencode({
    apiVersion = "projectcalico.org/v3"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "bastion-egress"
      namespace = local.namespace
    }
    spec = {
      order    = 100
      selector = "app == 'bastion'"
      types    = ["Egress"]
      egress = [
        {
          action   = "Allow"
          protocol = "TCP"
          destination = {
            nets  = values(local.targets)
            ports = [22]
          }
        },
        { action = "Deny" },
      ]
    }
  })
  depends_on = [kubernetes_namespace.bastion]
}

# Per-client-IP cap on concurrent connections. Traefik's TCP layer has no
# per-minute limiter; key-only auth leaves nothing to guess, so this bounds
# resource use rather than brute force.
resource "kubernetes_manifest" "inflight" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "MiddlewareTCP"
    metadata = {
      name      = "bastion-inflight"
      namespace = local.namespace
    }
    spec = {
      inFlightConn = {
        amount = 4
      }
    }
  }
  depends_on = [kubernetes_namespace.bastion]
}

# A TCP router with a specific HostSNI on websecure claims only this hostname;
# Traefik tries TCP routers first, and every other SNI falls through to the
# HTTP routers unchanged. tls {} = terminate with the default TLSStore cert
# (*.viktorbarzin.me).
resource "kubernetes_manifest" "route" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRouteTCP"
    metadata = {
      name      = "bastion"
      namespace = local.namespace
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match       = "HostSNI(`${local.hostname}.viktorbarzin.me`)"
        middlewares = [{ name = "bastion-inflight" }]
        services = [{
          name = kubernetes_service.bastion.metadata[0].name
          port = 22
        }]
      }]
      tls = {}
    }
  }
  depends_on = [kubernetes_manifest.inflight]
}

# Non-proxied: Cloudflare's proxy cannot carry raw TLS to a TCP router. Same
# A/AAAA pair ingress_factory writes for dns_type = "non-proxied".
resource "cloudflare_record" "a" {
  name            = local.hostname
  content         = var.public_ip
  proxied         = false
  ttl             = 1
  type            = "A"
  zone_id         = var.cloudflare_zone_id
  allow_overwrite = true
}

resource "cloudflare_record" "aaaa" {
  name            = local.hostname
  content         = var.public_ipv6
  proxied         = false
  ttl             = 1
  type            = "AAAA"
  zone_id         = var.cloudflare_zone_id
  allow_overwrite = true
}
