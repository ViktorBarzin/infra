variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }
variable "woodpecker_forgejo_url" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "woodpecker"
}


resource "kubernetes_namespace" "woodpecker" {
  metadata {
    name = "woodpecker"
    labels = {
      "resource-governance/custom-quota" = "true"
      tier                               = local.tiers.edge
    }
  }
}

resource "kubernetes_resource_quota" "woodpecker" {
  metadata {
    name      = "tier-quota"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "16"
      "requests.memory" = "16Gi"
      "limits.memory"   = "32Gi"
      pods              = "60"
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.woodpecker.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_config_map" "git_crypt_key" {
  metadata {
    name      = "git-crypt-key"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }

  data = {
    "key" = filebase64("${path.root}/../../.git/git-crypt/keys/default")
  }
}

# Database init job - creates the woodpecker database and user in PostgreSQL
resource "kubernetes_job" "db_init" {
  metadata {
    name      = "woodpecker-db-init"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  spec {
    template {
      metadata {}
      spec {
        container {
          name  = "db-init"
          image = "postgres:16-alpine"
          command = [
            "sh", "-c",
            <<-EOT
              set -e
              # Create user if not exists
              PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -tc "SELECT 1 FROM pg_roles WHERE rolname='woodpecker'" | grep -q 1 || \
                PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -c "CREATE ROLE woodpecker WITH LOGIN PASSWORD '${data.vault_kv_secret_v2.secrets.data["db_password"]}'"
              # Create database if not exists
              PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -tc "SELECT 1 FROM pg_database WHERE datname='woodpecker'" | grep -q 1 || \
                PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -c "CREATE DATABASE woodpecker OWNER woodpecker"
              echo "Database init complete"
            EOT
          ]
        }
        restart_policy = "Never"
      }
    }
    backoff_limit = 3
  }
  wait_for_completion = true
  timeouts {
    create = "2m"
  }
}

# NFS PV for Woodpecker server data (Helm chart creates PVC via StatefulSet VCT)
resource "kubernetes_persistent_volume" "woodpecker_server_data" {
  metadata {
    name = "woodpecker-server-data"
  }
  spec {
    capacity = {
      storage = "10Gi"
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "nfs-truenas"
    volume_mode                      = "Filesystem"
    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = "woodpecker-server-data"
        volume_attributes = {
          server = var.nfs_server
          share  = "/mnt/main/woodpecker"
        }
      }
    }
    claim_ref {
      name      = "data-woodpecker-server-0"
      namespace = kubernetes_namespace.woodpecker.metadata[0].name
    }
  }
}

# Helm release for Woodpecker CI
resource "helm_release" "woodpecker" {
  name       = "woodpecker"
  namespace  = kubernetes_namespace.woodpecker.metadata[0].name
  repository = "oci://ghcr.io/woodpecker-ci/helm"
  chart      = "woodpecker"
  version    = "3.5.1"

  values = [
    templatefile("${path.module}/values.yaml", {
      github_client_id      = data.vault_kv_secret_v2.secrets.data["github_client_id"]
      github_client_secret  = data.vault_kv_secret_v2.secrets.data["github_client_secret"]
      agent_secret          = data.vault_kv_secret_v2.secrets.data["agent_secret"]
      db_password           = data.vault_kv_secret_v2.secrets.data["db_password"]
      postgresql_host       = var.postgresql_host
      forgejo_client_id     = data.vault_kv_secret_v2.secrets.data["forgejo_client_id"]
      forgejo_client_secret = data.vault_kv_secret_v2.secrets.data["forgejo_client_secret"]
      forgejo_url           = var.woodpecker_forgejo_url
    })
  ]

  timeout    = 600
  depends_on = [kubernetes_job.db_init, kubernetes_persistent_volume.woodpecker_server_data]
}

# ClusterRoleBinding - build pods need cluster-admin to PATCH deployments across namespaces
resource "kubernetes_cluster_role_binding" "woodpecker" {
  metadata {
    name = "woodpecker"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "woodpecker-agent"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  role_ref {
    kind      = "ClusterRole"
    name      = "cluster-admin"
    api_group = "rbac.authorization.k8s.io"
  }
}

# Also bind the default SA (pipeline pods run as default)
resource "kubernetes_cluster_role_binding" "woodpecker_default" {
  metadata {
    name = "woodpecker-default"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  role_ref {
    kind      = "ClusterRole"
    name      = "cluster-admin"
    api_group = "rbac.authorization.k8s.io"
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.woodpecker.metadata[0].name
  name            = "ci"
  service_name    = "woodpecker-server"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Woodpecker CI"
    "gethomepage.dev/description"  = "CI/CD pipelines"
    "gethomepage.dev/icon"         = "woodpecker-ci.png"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
  }
}
