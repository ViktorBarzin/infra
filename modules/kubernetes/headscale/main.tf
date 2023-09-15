
variable "tls_secret_name" {}

resource "kubernetes_namespace" "headscale" {
  metadata {
    name = "headscale"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "headscale"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "headscale" {
  metadata {
    name      = "headscale"
    namespace = "headscale"
    labels = {
      app = "headscale"
    }

    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "headscale"
      }
    }
    template {
      metadata {
        labels = {
          app = "headscale"
        }
      }
      spec {
        container {
          image   = "headscale/headscale:latest"
          name    = "headscale"
          command = ["headscale", "serve"]
          resources {
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
            requests = {
              cpu    = "1"
              memory = "1Gi"
            }
          }
          port {
            container_port = 8080
          }
          port {
            container_port = 9090
          }
          port {
            container_port = 41641
          }

          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/headscale"
          }

          volume_mount {
            mount_path = "/mnt"
            name       = "nfs-config"
          }
        }
        volume {
          name = "config-volume"
          config_map {
            # name = kubernetes_config_map.headscale-config.metadata[0].name
            name = "headscale-config"
            items {
              key  = "config.yaml"
              path = "config.yaml"
            }
          }
        }

        volume {
          name = "nfs-config"
          nfs {
            path   = "/mnt/main/headscale"
            server = "10.0.10.15"
          }
        }
        container {
          image = "simcu/headscale-ui"
          name  = "headscale-ui"
          port {
            container_port = 80
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "headscale" {
  metadata {
    name      = "headscale"
    namespace = "headscale"
    labels = {
      "app" = "headscale"
    }
    # annotations = {
    #   "metallb.universe.tf/allow-shared-ip" : "shared"
    # }
  }

  spec {
    # type                    = "LoadBalancer"
    # external_traffic_policy = "Cluster"
    selector = {
      app = "headscale"

    }
    port {
      name     = "headscale"
      port     = "8080"
      protocol = "TCP"
    }
    port {
      name     = "headscale-ui"
      port     = "80"
      protocol = "TCP"
    }
    port {
      name     = "metrics"
      port     = "9090"
      protocol = "TCP"
    }
    # port {
    #   name     = "server"
    #   port     = "41641"
    #   protocol = "UDP"
    # }
  }
}

resource "kubernetes_ingress_v1" "headscale" {
  metadata {
    name      = "headscale-ingress"
    namespace = "headscale"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      #   "nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
      #   "nginx.ingress.kubernetes.io/auth-tls-secret"        = "default/ca-secret"
    }
  }

  spec {
    tls {
      hosts       = ["headscale-ui.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "headscale.viktorbarzin.me"
      http {
        path {
          path = "/manager"
          backend {
            service {
              name = "headscale"
              port {
                number = 80
              }
            }
          }
        }
        path {
          path = "/"
          backend {
            service {
              name = "headscale"
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "headscale-server" {
  metadata {
    name      = "headscale-server"
    namespace = "headscale"
    labels = {
      "app" = "headscale"
    }
    annotations = {
      "metallb.universe.tf/allow-shared-ip" : "shared"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "headscale"

    }
    # port {
    #   name     = "headscale-tcp"
    #   port     = "41641"
    #   protocol = "TCP"
    # }
    port {
      name     = "headscale-udp"
      port     = "41641"
      protocol = "UDP"
    }
  }
}

resource "kubernetes_config_map" "headscale-config" {
  metadata {
    name      = "headscale-config"
    namespace = "headscale"

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "config.yaml" = <<-EOT
        ---
        server_url: https://headscale.viktorbarzin.me
        listen_addr: 0.0.0.0:8080
        metrics_listen_addr: 0.0.0.0:9090
        #grpc_listen_addr: 127.0.0.1:50443
        #grpc_listen_addr: 0.0.0.0:50443
        grpc_listen_addr: 0.0.0.0:41641
        #grpc_allow_insecure: false
        grpc_allow_insecure: true

        #private_key_path: /etc/headscale/private.key
        private_key_path: /mnt/private.key

        noise:
            #private_key_path: /etc/headscale/noise_private.key
            private_key_path: /mnt/noise_private.key

        ip_prefixes:
        - fd7a:115c:a1e0::/48
        - 100.64.0.0/10

        disable_check_updates: false

        ephemeral_node_inactivity_timeout: 30m

        derp:
          server:
            # If enabled, runs the embedded DERP server and merges it into the rest of the DERP config
            # The Headscale server_url defined above MUST be using https, DERP requires TLS to be in place
            enabled: true

            # Region ID to use for the embedded DERP server.
            # The local DERP prevails if the region ID collides with other region ID coming from
            # the regular DERP config.
            region_id: 999

            # Region code and name are displayed in the Tailscale UI to identify a DERP region
            region_code: "headscale"
            region_name: "Headscale Embedded DERP"

            # Listens over UDP at the configured address for STUN connections - to help with NAT traversal.
            # When the embedded DERP server is enabled stun_listen_addr MUST be defined.
            #
            # For more details on how this works, check this great article: https://tailscale.com/blog/how-tailscale-works/
            stun_listen_addr: "0.0.0.0:3478"

          # List of externally available DERP maps encoded in JSON
          urls:
            - https://controlplane.tailscale.com/derpmap/default

          # Locally available DERP map files encoded in YAML
          #
          # This option is mostly interesting for people hosting
          # their own DERP servers:
          # https://tailscale.com/kb/1118/custom-derp-servers/
          #
          # paths:
          #   - /etc/headscale/derp-example.yaml
          paths: []

          # If enabled, a worker will be set up to periodically
          # refresh the given sources and update the derpmap
          # will be set up.
          auto_update_enabled: true

          # How often should we check for DERP updates?
          update_frequency: 24h

        node_update_check_interval: 10s

        db_type: sqlite3

        #db_path: /etc/headscale/db.sqlite
        db_path: /mnt/db.sqlite

        acme_url: https://acme-v02.api.letsencrypt.org/directory

        acme_email: ""

        tls_letsencrypt_hostname: ""

        tls_letsencrypt_cache_dir: /var/lib/headscale/cache

        tls_letsencrypt_challenge_type: HTTP-01
        tls_letsencrypt_listen: ":http"

        tls_cert_path: ""
        tls_key_path: ""

        log:
            format: text
            #level: info
            level: debug

        acl_policy_path: ""

        dns_config:
            override_local_dns: true

        nameservers:
            - 1.1.1.1

        domains: []

        magic_dns: true

        unix_socket: /var/run/headscale/headscale.sock
        unix_socket_permission: "0770"

        randomize_client_port: false
        
        # headscale supports experimental OpenID connect support,
        # it is still being tested and might have some bugs, please
        # help us test it.
        # OpenID Connect
        oidc:
          only_start_if_oidc_is_available: true
          issuer: "https://accounts.google.com"
          client_id: "533122798643-4ti3espgjqhfnop0rors9t7r4o5i8top.apps.googleusercontent.com"
          client_secret: "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"
        
          # The amount of time from a node is authenticated with OpenID until it
          # expires and needs to reauthenticate.
          # Setting the value to "0" will mean no expiry.
          expiry: 180d
        
          # Use the expiry from the token received from OpenID when the user logged
          # in, this will typically lead to frequent need to reauthenticate and should
          # only been enabled if you know what you are doing.
          # Note: enabling this will cause `oidc.expiry` to be ignored.
          use_expiry_from_token: false
        
          # Customize the scopes used in the OIDC flow, defaults to "openid", "profile" and "email" and add custom query
          # parameters to the Authorize Endpoint request. Scopes default to "openid", "profile" and "email".
        
          scope: ["openid", "profile", "email"]
          # extra_params:
          #   domain_hint: example.com
        
          # List allowed principal domains and/or users. If an authenticated user's domain is not in this list, the
          # authentication request will be rejected.
        
          # allowed_domains:
          #   - example.com
          # Note: Groups from keycloak have a leading '/'
          # allowed_groups:
          #   - /headscale
          allowed_users:
            - vbarzin@gmail.com
        
          # If `strip_email_domain` is set to `true`, the domain part of the username email address will be removed.
          # This will transform `first-name.last-name@example.com` to the user `first-name.last-name`
          # If `strip_email_domain` is set to `false` the domain part will NOT be removed resulting to the following
          # user: `first-name.last-name.example.com`
        
          # strip_email_domain: true
    EOT
  }
}
