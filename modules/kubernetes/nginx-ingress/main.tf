# module "nginx-controller" {
#   source = "terraform-iaac/nginx-controller/helm"
#   namespace                = "ingress-nginx-test"
#   create_namespace         = true
#   atomic                   = true
#   ingress_class_is_default = false
#   ingress_class_name       = "nginx-test"
# }
variable "honeypotapikey" {
  default = null
}
variable "crowdsec_api_key" {}
variable "crowdsec_captcha_secret_key" {}
variable "crowdsec_captcha_site_key" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
    labels = {
      "app.kubernetes.io/instance" = "ingress-nginx"
      "app.kubernetes.io/name"     = "ingress-nginx"
      # "istio-injection" : "enabled"
    }
  }
}
resource "kubernetes_service_account" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx"
    namespace = "ingress-nginx"
    labels = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
    }
  }
  automount_service_account_token = true
}

# Jobs create a cert and modify this secret. This is problematic as TF recreates it every time
# Instead, on each fresh install, uncomment this, get nginx working and comment it.
# Also rm from state: tf state rm module.kubernetes_cluster.module.nginx-ingress.kubernetes_service_account.ingress_nginx_admission 
resource "kubernetes_service_account" "ingress_nginx_admission" {
  metadata {
    name      = "ingress-nginx-admission"
    namespace = "ingress-nginx"
    labels = {
      "app.kubernetes.io/component" = "admission-webhook"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
    }
  }
}
resource "kubernetes_role" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx"
    namespace = "ingress-nginx"
    labels = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
    }
  }
  rule {
    verbs      = ["get"]
    api_groups = [""]
    resources  = ["namespaces"]
  }
  rule {
    verbs      = ["get", "list", "watch", "update", "create", "delete"]
    api_groups = [""]
    resources  = ["configmaps", "pods", "secrets", "endpoints"]
  }
  rule {
    verbs      = ["get", "list", "watch"]
    api_groups = [""]
    resources  = ["services"]
  }
  rule {
    verbs      = ["get", "list", "watch"]
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
  }
  rule {
    verbs      = ["update"]
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses/status"]
  }
  rule {
    verbs      = ["get", "list", "watch"]
    api_groups = ["networking.k8s.io"]
    resources  = ["ingressclasses"]
  }
  rule {
    verbs          = ["get", "update"]
    api_groups     = ["coordination.k8s.io"]
    resources      = ["leases"]
    resource_names = ["ingress-nginx-leader"]
  }
  rule {
    verbs      = ["create"]
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
  }
  rule {
    verbs      = ["create", "patch"]
    api_groups = [""]
    resources  = ["events"]
  }
  rule {
    verbs      = ["list", "watch", "get"]
    api_groups = ["discovery.k8s.io"]
    resources  = ["endpointslices"]
  }
}
resource "kubernetes_role" "ingress_nginx_admission" {
  metadata {
    name      = "ingress-nginx-admission"
    namespace = "ingress-nginx"
    labels = {
      "app.kubernetes.io/component" = "admission-webhook"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
    }
  }
  rule {
    verbs      = ["get", "create", "patch", "update", "watch", "list"]
    api_groups = [""]
    resources  = ["secrets"]
  }
}
resource "kubernetes_cluster_role" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
    labels = {
      "app.kubernetes.io/instance" = "ingress-nginx"
      "app.kubernetes.io/name"     = "ingress-nginx"
      "app.kubernetes.io/part-of"  = "ingress-nginx"
      "app.kubernetes.io/version"  = "1.13.1"
    }
  }
  rule {
    verbs      = ["list", "watch"]
    api_groups = [""]
    resources  = ["configmaps", "endpoints", "nodes", "pods", "secrets", "namespaces"]
  }
  rule {
    verbs      = ["list", "watch"]
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
  }
  rule {
    verbs      = ["get"]
    api_groups = [""]
    resources  = ["nodes"]
  }
  rule {
    verbs      = ["get", "list", "watch"]
    api_groups = [""]
    resources  = ["services"]
  }
  rule {
    verbs      = ["get", "list", "watch"]
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
  }
  rule {
    verbs      = ["create", "patch"]
    api_groups = [""]
    resources  = ["events"]
  }
  rule {
    verbs      = ["update"]
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses/status"]
  }
  rule {
    verbs      = ["get", "list", "watch"]
    api_groups = ["networking.k8s.io"]
    resources  = ["ingressclasses"]
  }
  rule {
    verbs      = ["list", "watch", "get"]
    api_groups = ["discovery.k8s.io"]
    resources  = ["endpointslices"]
  }
}
resource "kubernetes_cluster_role" "ingress_nginx_admission" {
  metadata {
    name = "ingress-nginx-admission"
    labels = {
      "app.kubernetes.io/component" = "admission-webhook"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
    }
  }
  rule {
    verbs      = ["get", "update"]
    api_groups = ["admissionregistration.k8s.io"]
    resources  = ["validatingwebhookconfigurations"]
  }
}
resource "kubernetes_role_binding" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx"
    namespace = "ingress-nginx"
    labels = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
    }
  }
  subject {
    kind      = "ServiceAccount"
    name      = "ingress-nginx"
    namespace = "ingress-nginx"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = "ingress-nginx"
  }
}
resource "kubernetes_role_binding" "ingress_nginx_admission" {
  metadata {
    name      = "ingress-nginx-admission"
    namespace = "ingress-nginx"
    labels = {
      "app.kubernetes.io/component" = "admission-webhook"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
    }
  }
  subject {
    kind      = "ServiceAccount"
    name      = "ingress-nginx-admission"
    namespace = "ingress-nginx"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = "ingress-nginx-admission"
  }
}
resource "kubernetes_cluster_role_binding" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
    labels = {
      "app.kubernetes.io/instance" = "ingress-nginx"
      "app.kubernetes.io/name"     = "ingress-nginx"
      "app.kubernetes.io/part-of"  = "ingress-nginx"
      "app.kubernetes.io/version"  = "1.13.1"
    }
  }
  subject {
    kind      = "ServiceAccount"
    name      = "ingress-nginx"
    namespace = "ingress-nginx"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "ingress-nginx"
  }
}
resource "kubernetes_cluster_role_binding" "ingress_nginx_admission" {
  metadata {
    name = "ingress-nginx-admission"
    labels = {
      "app.kubernetes.io/component" = "admission-webhook"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
    }
  }
  subject {
    kind      = "ServiceAccount"
    name      = "ingress-nginx-admission"
    namespace = "ingress-nginx"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "ingress-nginx-admission"
  }
}
resource "kubernetes_config_map" "ingress_nginx_controller" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
    labels = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
    }
  }
  data = {
    use-forwarded-headers        = "true"
    compute-full-forwarded-for   = "true"
    enable-real-ip               = "true"
    allow-snippet-annotations    = true
    limit-req-status-code        = 429
    limit-conn-status-code       = 429
    enable-modsecurity           = true
    enable-owasp-modsecurity-crs = false
    modsecurity-snippet : <<-EOT
        SecRuleEngine On
        ${var.honeypotapikey != null ? format("%s %s", "SecHttpBlKey", var.honeypotapikey) : ""}
        SecAction "id:900500,\
        phase:1,\
        nolog,\
        pass,\
        t:none,\
        setvar:tx.block_search_ip=0,\
        setvar:tx.block_suspicious_ip=1,\
        setvar:tx.block_harvester_ip=1,\
        setvar:tx.block_spammer_ip=1"
        EOT
    plugins = "crowdsec"
    # plugins          = ""
    lua-shared-dicts = "crowdsec_cache: 50m"
    http-snippet : <<-EOT
      proxy_cache_path /tmp/nginx-cache levels=1:2 keys_zone=static-cache:2m max_size=100m inactive=7d use_temp_path=off;
      proxy_cache_key $scheme$proxy_host$request_uri;
      proxy_cache_lock on;
      proxy_cache_use_stale updating;
    EOT
    server-snippet : <<-EOT
    lua_ssl_trusted_certificate "/etc/ssl/certs/ca-certificates.crt"; # Captcha
    #resolver local=on ipv6=off valid=600s;
    EOT
    # first own works
    # log-format-upstream : <<-EOT
    # $remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" "$http_cf_connecting_ip" "$http_cf_ray" "$http_x_forwarded_for" "$host";
    # EOT

    # ketpt do debug why it's invalid syntax lol
    # log-format-upstream : <<-EOT 
    # $remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" "$http_cf_connecting_ip" "$http_cf_ray" "$http_x_forwarded_for" "$host";
    # EOT
  }
}

resource "kubernetes_config_map" "udp_services" {
  metadata {
    name      = "udp-services"
    namespace = "ingress-nginx"
  }
  data = {
    53 : "technitium/technitium-dns:53"
    # 8554 : "frigate/frigate:8554"
  }
}
resource "kubernetes_config_map" "tcp_services" {
  metadata {
    name      = "tcp-services"
    namespace = "ingress-nginx"
  }
  data = {
    # 9443 : "wireguard/xray:7443" // reality
    # 8554 : "frigate/frigate:8554"
  }
}
resource "kubernetes_service" "ingress_nginx_controller" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
    labels = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
    }
  }
  spec {
    port {
      name        = "http"
      protocol    = "TCP"
      port        = 80
      target_port = "http"
    }
    port {
      name        = "https"
      protocol    = "TCP"
      port        = 443
      target_port = "https"
    }
    port {
      name        = "dns"
      protocol    = "UDP"
      port        = 53
      target_port = "dns"
    }
    # port {
    #   name     = "frigate-rtsptcp"
    #   port     = 8554
    #   protocol = "TCP"
    # }
    # port {
    #   name     = "frigate-rtspudp"
    #   port     = 8554
    #   protocol = "UDP"
    # }
    # port {
    #   name        = "xray-reality"
    #   protocol    = "TCP"
    #   port        = 9443 # expose tcp port here
    #   target_port = "9443"
    # }
    selector = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
    }
    type                    = "LoadBalancer"
    external_traffic_policy = "Local" // see https://metallb.universe.tf/usage/
    # ip_families = ["IPv4"]
  }
}
resource "kubernetes_service" "ingress_nginx_controller_admission" {
  metadata {
    name      = "ingress-nginx-controller-admission"
    namespace = "ingress-nginx"
    labels = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
    }
  }
  spec {
    port {
      name        = "https-webhook"
      port        = 443
      target_port = "webhook"
    }
    selector = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
    }
    type = "ClusterIP"
  }
}
resource "kubernetes_deployment" "ingress_nginx_controller" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
    labels = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
      tier                          = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 3

    selector {
      match_labels = {
        "app.kubernetes.io/component" = "controller"
        "app.kubernetes.io/instance"  = "ingress-nginx"
        "app.kubernetes.io/name"      = "ingress-nginx"
      }
    }
    template {
      metadata {
        labels = {
          "app.kubernetes.io/component" = "controller"
          "app.kubernetes.io/instance"  = "ingress-nginx"
          "app.kubernetes.io/name"      = "ingress-nginx"
          "app.kubernetes.io/part-of"   = "ingress-nginx"
          "app.kubernetes.io/version"   = "1.13.1"
          "app"                         = "ingress-nginx"
        }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = 10254

          "diun.enable"       = "true"
          "diun.include_tags" = "^v\\d+(?:\\.\\d+)?(?:\\.\\d+)?.*$"
        }
      }
      spec {
        volume {
          name = "webhook-cert"
          secret {
            secret_name = "ingress-nginx-admission"
          }
        }
        # volume {
        #   name = "modsecurity"
        #   config_map {
        #     name = "modsecurity"
        #   }
        # }

        ## Crowdsec
        init_container {
          name  = "init-clone-crowdsec-bouncer"
          image = "crowdsecurity/lua-bouncer-plugin"
          env {
            name  = "API_URL"
            value = "http://crowdsec-service.crowdsec.svc.cluster.local:8080"
          }
          env {
            // if you can't connect with bouncer not found, regenerate api key with:
            // "cscli bouncers add nginx" on the lapi
            name  = "API_KEY"
            value = var.crowdsec_api_key
          }
          env {
            name  = "MODE"
            value = "stream"
          }
          env {
            name  = "CAPTCHA_PROVIDER"
            value = "hcaptcha"
          }
          env {
            name  = "BOUNCING_ON_TYPE"
            value = "all"
            # value = "ban"
          }
          env {
            name  = "SECRET_KEY"
            value = var.crowdsec_captcha_secret_key
          }
          env {
            name  = "SITE_KEY"
            value = var.crowdsec_captcha_site_key
          }

          # env {
          #   name  = "DISABLE_RUN"
          #   value = "true"
          # }
          env {
            name  = "BAN_TEMPLATE_PATH"
            value = "/etc/nginx/lua/plugins/crowdsec/templates/ban.html"
          }
          env {
            name  = "CAPTCHA_TEMPLATE_PATH"
            value = "/etc/nginx/lua/plugins/crowdsec/templates/captcha.html"
          }
          env {
            name  = "BOUNCER_CONFIG"
            value = "/crowdsec/crowdsec-bouncer.conf"
          }
          # command = ["sh", "-c", "sh /docker_start.sh; mkdir -p /lua_plugins/crowdsec/; cp -r /crowdsec /lua_plugins/; chown -R 101:101 /lua_plugins/"]
          command = ["sh", "-c", "sh /docker_start.sh; mkdir -p /lua_plugins/crowdsec/; cp -R /crowdsec/* /lua_plugins/crowdsec/"]

          volume_mount {
            name       = "crowdsec"
            mount_path = "/lua_plugins"
          }
        }
        # Share bouncer config
        volume {
          name = "crowdsec"
          empty_dir {
          }
        }
        container {
          name = "controller"
          # https://github.com/kubernetes/ingress-nginx
          image = "registry.k8s.io/ingress-nginx/controller:v1.11.8"
          args  = ["/nginx-ingress-controller", "--election-id=ingress-nginx-leader", "--controller-class=k8s.io/ingress-nginx", "--ingress-class=nginx", "--configmap=$(POD_NAMESPACE)/ingress-nginx-controller", "--validating-webhook=:8443", "--validating-webhook-certificate=/usr/local/certificates/cert", "--validating-webhook-key=/usr/local/certificates/key", "--udp-services-configmap", "ingress-nginx/udp-services", "--tcp-services-configmap", "ingress-nginx/tcp-services"]
          volume_mount {
            name       = "crowdsec"
            mount_path = "/etc/nginx/lua/plugins/crowdsec"
            sub_path   = "crowdsec"
          }
          port {
            name           = "http"
            container_port = 80
            protocol       = "TCP"
          }
          port {
            name           = "https"
            container_port = 443
            protocol       = "TCP"
          }
          port {
            name           = "dns"
            container_port = 53
            protocol       = "UDP"
          }
          # port {
          #   name           = "xray-reality"
          #   container_port = 9443 # expose port here
          #   protocol       = "TCP"
          # }
          port {
            name           = "webhook"
            container_port = 8443
            protocol       = "TCP"
          }
          # port {
          #   name           = "frigate-rtsptcp"
          #   container_port = 8554
          #   protocol       = "TCP"
          # }
          # port {
          #   name           = "frigate-rtspudp"
          #   container_port = 8554
          #   protocol       = "UDP"
          # }
          port {
            name           = "metrics"
            container_port = 10254
            protocol       = "TCP"
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
            name = "POD_NAMESPACE"
            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }
          env {
            name  = "LD_PRELOAD"
            value = "/usr/local/lib/libmimalloc.so"
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "90Mi"
            }
          }
          volume_mount {
            name       = "webhook-cert"
            read_only  = true
            mount_path = "/usr/local/certificates/"
          }
          # Not used atm
          #   volume_mount {
          #     name       = "modsecurity"
          #     read_only  = true
          #     mount_path = "/etc/nginx/modsecurity"
          #     # sub_path   = "modsecurity.conf"
          #   }
          liveness_probe {
            http_get {
              path   = "/healthz"
              port   = "10254"
              scheme = "HTTP"
            }
            initial_delay_seconds = 10
            timeout_seconds       = 1
            period_seconds        = 10
            success_threshold     = 1
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path   = "/healthz"
              port   = "10254"
              scheme = "HTTP"
            }
            initial_delay_seconds = 10
            timeout_seconds       = 1
            period_seconds        = 10
            success_threshold     = 1
            failure_threshold     = 3
          }
          lifecycle {
            pre_stop {
              exec {
                command = ["/wait-shutdown"]
              }
            }
          }
          image_pull_policy = "IfNotPresent"
          security_context {
            capabilities {
              add  = ["NET_BIND_SERVICE"]
              drop = ["ALL"]
            }
            run_as_user                = 101
            allow_privilege_escalation = true
          }
        }
        termination_grace_period_seconds = 300
        dns_policy                       = "ClusterFirst"
        node_selector = {
          "kubernetes.io/os" = "linux"
        }
        service_account_name = "ingress-nginx"
      }
    }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "1"
        max_surge       = "2"
      }
    }

    revision_history_limit = 10
  }
}
resource "kubernetes_job" "ingress_nginx_admission_create" {
  metadata {
    name      = "ingress-nginx-admission-create"
    namespace = "ingress-nginx"
    labels = {
      "app.kubernetes.io/component" = "admission-webhook"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.8.2"
    }
  }
  spec {
    template {
      metadata {
        name = "ingress-nginx-admission-create"
        labels = {
          "app.kubernetes.io/component" = "admission-webhook"
          "app.kubernetes.io/instance"  = "ingress-nginx"
          "app.kubernetes.io/name"      = "ingress-nginx"
          "app.kubernetes.io/part-of"   = "ingress-nginx"
          "app.kubernetes.io/version"   = "1.8.2"
        }
      }
      spec {
        container {
          name  = "create"
          image = "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v20230407@sha256:543c40fd093964bc9ab509d3e791f9989963021f1e9e4c9c7b6700b02bfb227b"
          args  = ["create", "--host=ingress-nginx-controller-admission,ingress-nginx-controller-admission.$(POD_NAMESPACE).svc", "--namespace=$(POD_NAMESPACE)", "--secret-name=ingress-nginx-admission"]
          env {
            name = "POD_NAMESPACE"
            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }
          image_pull_policy = "IfNotPresent"
        }
        restart_policy = "OnFailure"
        node_selector = {
          "kubernetes.io/os" = "linux"
        }
        service_account_name = "ingress-nginx-admission"
        security_context {
          run_as_user     = 2000
          run_as_non_root = true
          fs_group        = 2000
        }
      }
    }
  }
}

# Jobs create a cert and modify this secret. This is problematic as TF recreates it every time
# Instead, on each fresh install, uncomment this, get nginx working and comment it.
# Also rm from state: tf state rm module.kubernetes_cluster.module.nginx-ingress.kubernetes_job.ingress_nginx_admission_patch
# resource "kubernetes_job" "ingress_nginx_admission_patch" {
#   metadata {
#     name      = "ingress-nginx-admission-patch"
#     namespace = "ingress-nginx"
#     labels = {
#       "app.kubernetes.io/component" = "admission-webhook"
#       "app.kubernetes.io/instance"  = "ingress-nginx"
#       "app.kubernetes.io/name"      = "ingress-nginx"
#       "app.kubernetes.io/part-of"   = "ingress-nginx"
#       "app.kubernetes.io/version"   = "1.13.1"
#     }
#   }
#   spec {
#     template {
#       metadata {
#         name = "ingress-nginx-admission-patch"
#         labels = {
#           "app.kubernetes.io/component" = "admission-webhook"
#           "app.kubernetes.io/instance"  = "ingress-nginx"
#           "app.kubernetes.io/name"      = "ingress-nginx"
#           "app.kubernetes.io/part-of"   = "ingress-nginx"
#           "app.kubernetes.io/version"   = "1.13.1"
#         }
#       }
#       spec {
#         container {
#           name  = "patch"
#           image = "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v20230407@sha256:543c40fd093964bc9ab509d3e791f9989963021f1e9e4c9c7b6700b02bfb227b"
#           args  = ["patch", "--webhook-name=ingress-nginx-admission", "--namespace=$(POD_NAMESPACE)", "--patch-mutating=false", "--secret-name=ingress-nginx-admission", "--patch-failure-policy=Fail"]
#           env {
#             name = "POD_NAMESPACE"
#             value_from {
#               field_ref {
#                 field_path = "metadata.namespace"
#               }
#             }
#           }
#           image_pull_policy = "IfNotPresent"
#         }
#         restart_policy = "OnFailure"
#         node_selector = {
#           "kubernetes.io/os" = "linux"
#         }
#         service_account_name = "ingress-nginx-admission"
#         security_context {
#           run_as_user     = 2000
#           run_as_non_root = true
#           fs_group        = 2000
#         }
#       }
#     }
#   }
# }
resource "kubernetes_ingress_class" "nginx" {
  metadata {
    name = "nginx"
    labels = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/part-of"   = "ingress-nginx"
      "app.kubernetes.io/version"   = "1.13.1"
    }
  }
  spec {
    controller = "k8s.io/ingress-nginx"
  }
}

# Jobs create a cert and modify this secret. This is problematic as TF recreates it every time
# Instead, on each fresh install, uncomment this, get nginx working and comment it.
# Also rm from state: tf state rm module.kubernetes_cluster.module.nginx-ingress.kubernetes_service_account.ingress_nginx_admission
# resource "kubernetes_validating_webhook_configuration" "ingress_nginx_admission" {
#   metadata {
#     name = "ingress-nginx-admission"
#     labels = {
#       "app.kubernetes.io/component" = "admission-webhook"
#       "app.kubernetes.io/instance"  = "ingress-nginx"
#       "app.kubernetes.io/name"      = "ingress-nginx"
#       "app.kubernetes.io/part-of"   = "ingress-nginx"
#       "app.kubernetes.io/version"   = "1.13.1"
#     }
#   }
#   webhook {
#     name = "validate.nginx.ingress.kubernetes.io"
#     client_config {
#       service {
#         namespace = "ingress-nginx"
#         name      = "ingress-nginx-controller-admission"
#         path      = "/networking/v1/ingresses"
#       }
#     }
#     rule {
#       api_versions = ["v1"]
#       api_groups   = ["networking.k8s.io"]
#       resources    = ["ingresses"]
#       operations   = ["CREATE", "UPDATE"]
#     }
#     failure_policy            = "Fail"
#     match_policy              = "Equivalent"
#     side_effects              = "None"
#     admission_review_versions = ["v1"]
#   }
# }

resource "kubernetes_config_map" "modsecurity" {
  metadata {
    name      = "modsecurity"
    namespace = "ingress-nginx"
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "modsecurity.conf" = file("${path.module}/modsecurity.conf")
  }
}
