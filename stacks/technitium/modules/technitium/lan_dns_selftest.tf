# Temporary: proves external-dns creates and then deletes a .lan record.
# Removed in the next commit.
resource "kubernetes_ingress_v1" "lan_dns_selftest" {
  metadata {
    name      = "lan-dns-selftest"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    ingress_class_name = "traefik"
    rule {
      host = "lan-dns-selftest.viktorbarzin.lan"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "technitium-web"
              port {
                number = 5380
              }
            }
          }
        }
      }
    }
  }
}
