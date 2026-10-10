variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "nfs_server" { type = string }

variable "beadboard_image_tag" {
  type    = string
  default = "17a38e43"
}

# Tracks claude-agent-service `:latest` (stacks/claude-agent-service/main.tf uses
# image_tag "latest" + CI_SETS_IMAGE). Reused here because the dispatcher +
# reaper CronJobs only need bd, curl, and jq, which that image already ships.
# Was pinned to SHA "2fd7670d", which Forgejo retention pruned → ImagePullBackOff
# (fixed 2026-06-12); ":latest" stays in sync automatically and can't go stale.
variable "claude_agent_service_image_tag" {
  type    = string
  default = "latest"
}

# Kill switch for auto-dispatch. When false, both CronJobs are suspended. The
# manual BeadBoard Dispatch button keeps working either way.
#
# OFF since 2026-08-16 (Viktor). Auto-dispatch was polling and finding nothing:
# every run logged "no eligible beads (assignee=agent, status=open, has
# acceptance_criteria)" because no bead is assigned to `agent` at all, and none
# had been for as long as Loki retains. The dispatcher fired every 2 minutes and
# the reaper every 10, so the pair cost ~864 pod creations/day to do nothing.
#
# That is not free on this host: each pod create/destroy writes containerd
# overlay layers, a kubelet pod dir, /var/log/pods and a systemd transient
# scope, plus the ext4 journal metadata for all of it — small random writes,
# which is precisely what the shared sdc spindle is short of. The dispatcher
# also runs the claude-agent-service image, much heavier than the alpine jobs
# around it, so a cold node pays an image pull on top.
#
# Flip back to true to restore auto-dispatch; nothing else needs changing, and
# manual dispatch from BeadBoard is unaffected meanwhile.
variable "beads_dispatcher_enabled" {
  type    = bool
  default = false
}

resource "kubernetes_namespace" "beads" {
  metadata {
    name = "beads-server"
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_persistent_volume_claim" "dolt_data" {
  wait_until_bound = false
  metadata {
    name      = "dolt-data"
    namespace = kubernetes_namespace.beads.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "10Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = { storage = "2Gi" }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_config_map" "dolt_init" {
  metadata {
    name      = "dolt-init"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  data = {
    "01-create-beads-user.sql"     = <<-EOT
      CREATE USER IF NOT EXISTS 'beads'@'%' IDENTIFIED BY '';
      GRANT ALL PRIVILEGES ON *.* TO 'beads'@'%' WITH GRANT OPTION;
    EOT
    "02-create-presence-table.sql" = <<-EOT
      CREATE DATABASE IF NOT EXISTS beads;
      USE beads;
      CREATE TABLE IF NOT EXISTS presence_claims (
        session_id      VARCHAR(128)  NOT NULL,
        resource_label  VARCHAR(255)  NOT NULL,
        purpose         TEXT          NOT NULL,
        claimed_at      DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        expires_at      DATETIME(3)   NOT NULL,
        host            VARCHAR(128)  NOT NULL,
        user            VARCHAR(64)   NOT NULL,
        agent_name      VARCHAR(64)   DEFAULT 'claude-code',
        PRIMARY KEY (session_id, resource_label),
        INDEX idx_resource (resource_label),
        INDEX idx_expires  (expires_at)
      );
    EOT
  }
}

resource "kubernetes_deployment" "dolt" {
  metadata {
    name      = "dolt"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app  = "dolt"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "dolt"
      }
    }
    template {
      metadata {
        labels = {
          app = "dolt"
        }
      }
      spec {
        container {
          name = "dolt"
          # Exact pin, owned by Terraform (the image is no longer in
          # lifecycle.ignore_changes, so changing this tag rolls the pod).
          # Strategy is Recreate, so only one Dolt process opens the store.
          # Take a tarball of /var/lib/dolt before bumping: the daily
          # dolt-backup CronJob below keeps current rows but not commit history.
          image = "dolthub/dolt-sql-server:2.4.2"

          port {
            name           = "mysql"
            container_port = 3306
          }

          env {
            name  = "DOLT_ROOT_HOST"
            value = "%"
          }

          volume_mount {
            name       = "dolt-data"
            mount_path = "/var/lib/dolt"
          }
          volume_mount {
            name       = "init-scripts"
            mount_path = "/docker-entrypoint-initdb.d"
            read_only  = true
          }

          startup_probe {
            tcp_socket {
              port = 3306
            }
            failure_threshold = 30
            period_seconds    = 2
          }
          liveness_probe {
            tcp_socket {
              port = 3306
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          readiness_probe {
            tcp_socket {
              port = 3306
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "dolt-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.dolt_data.metadata[0].name
          }
        }
        volume {
          name = "init-scripts"
          config_map {
            name = kubernetes_config_map.dolt_init.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      # The image is deliberately NOT ignored: Terraform owns the tag and
      # Renovate proposes bumps.
    ]
  }
}

# One-shot Job to apply the presence_claims schema to the running Dolt server.
# The dolt_init ConfigMap only fires on fresh PVCs; since Dolt already exists
# with persistent state, this Job is the only path to update the live schema.
# The job name is hashed off the SQL content so a new Job runs whenever the
# schema changes; the SQL itself is idempotent (CREATE ... IF NOT EXISTS).
resource "kubernetes_job" "presence_schema_migrate" {
  metadata {
    name      = "presence-schema-${substr(sha256(kubernetes_config_map.dolt_init.data["02-create-presence-table.sql"]), 0, 8)}"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  spec {
    backoff_limit = 3
    template {
      metadata {}
      spec {
        restart_policy = "OnFailure"
        container {
          name    = "migrate"
          image   = "mysql:8.4"
          command = ["sh", "-c"]
          args = [
            "mysql -h dolt.beads-server.svc.cluster.local -P 3306 -u root < /sql/02-create-presence-table.sql"
          ]
          volume_mount {
            name       = "sql"
            mount_path = "/sql"
          }
        }
        volume {
          name = "sql"
          config_map {
            name = kubernetes_config_map.dolt_init.metadata[0].name
          }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts {
    create = "5m"
  }
  depends_on = [kubernetes_deployment.dolt]
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "dolt" {
  metadata {
    name      = "dolt"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app = "dolt"
    }
    annotations = {
      "metallb.universe.tf/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip"          = "shared"
    }
  }
  lifecycle {
    # METALLB_LIFECYCLE_V1: MetalLB's controller writes this annotation on the
    # live object after it allocates an IP. Without the ignore, every apply
    # plans to strip it and MetalLB re-adds it — permanent drift.
    ignore_changes = [metadata[0].annotations["metallb.io/ip-allocated-from-pool"]]
  }
  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "dolt"
    }
    port {
      name        = "mysql"
      port        = 3306
      target_port = 3306
    }
  }
}

# ── Dolt backup ──
#
# Daily logical backup of every Dolt database to the PVE NFS share
# (192.168.1.127:/srv/nfs/dolt-backup). Software-currency groundwork
# (docs/plans/2026-10-09-software-currency-design.md): the pre-upgrade
# snapshot step needs a backup to run before a Dolt bump.
#
# Two containers share an emptyDir:
#   - dump (init, mysql client): mysqldump of each user database. Dolt 2.4.2
#     has no remote `dolt dump`, and rejects mysqldump's --single-transaction
#     (SAVEPOINT), so the dump runs without it. Views are skipped by
#     mysqldump (Dolt's information_schema.views is empty, so it would only
#     write placeholders) and appended from dolt_schemas instead.
#   - verify (dolt image matching the server): restores the dump into a
#     scratch Dolt directory, checks every table and view came back, then
#     gzips it to /backup/<UTC yyyymmdd-hhmm>/ and pushes the metrics.
#
# What it does not keep: Dolt commit history. A restore gives the current
# rows of every table, including uncommitted working-set changes (the beads
# database's presence_claims is never committed), as one new commit. Users
# and grants come from the dolt-init ConfigMap, not from the dump.
# 14-day retention. Restore: docs/runbooks/restore-dolt.md.
module "nfs_dolt_backup" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "beads-dolt-backup-host"
  namespace          = kubernetes_namespace.beads.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/dolt-backup"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_cron_job_v1" "dolt_backup" {
  metadata {
    name      = "dolt-backup"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    schedule                      = "25 1 * * *"
    starting_deadline_seconds     = 600
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            init_container {
              name  = "dump"
              image = "mysql:8.4.8"
              env {
                name  = "DOLT_HOST"
                value = "${kubernetes_service.dolt.metadata[0].name}.${kubernetes_namespace.beads.metadata[0].name}.svc.cluster.local"
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -eu
                # Runs in mysql client image. Writes a logical dump of every user database
                # into /work (emptyDir); the verify container restores it before it reaches NFS.
                q() { mysql -h "$DOLT_HOST" -P 3306 -u root -N -B "$@"; }
                date -u +%s > /work/start
                q -e "SELECT dolt_version()" > /work/VERSION
                q -e "SHOW DATABASES" | grep -v -x -E 'information_schema|mysql|performance_schema|sys' > /work/databases
                : > /work/counts.tsv
                : > /work/views.tsv
                while read -r db; do
                  ignore=""
                  q -e "SHOW FULL TABLES FROM \`$db\`" > /work/tables.$db
                  while IFS="$(printf '\t')" read -r t kind; do
                    if [ "$kind" = "VIEW" ]; then
                      ignore="$ignore --ignore-table=$db.$t"
                      printf '%s\t%s\n' "$db" "$t" >> /work/views.tsv
                    else
                      printf '%s\t%s\t%s\n' "$db" "$t" "$(q -e "SELECT COUNT(*) FROM \`$db\`.\`$t\`")" >> /work/counts.tsv
                    fi
                  done < /work/tables.$db
                  rm -f /work/tables.$db
                  # No --single-transaction: Dolt rejects mysqldump's SAVEPOINT handling.
                  # Views are excluded here because mysqldump only writes placeholder views
                  # for Dolt (its information_schema.views is empty); their real definitions
                  # come from dolt_schemas below.
                  mysqldump -h "$DOLT_HOST" -P 3306 -u root --skip-lock-tables --no-tablespaces \
                    --set-gtid-purged=OFF --column-statistics=0 --routines --triggers \
                    --databases "$db" $ignore > "/work/$db.sql"
                  if grep -q "^$db	" /work/views.tsv; then
                    printf '\nUSE `%s`;\n' "$db" >> "/work/$db.sql"
                    q --raw -e "SELECT CONCAT(fragment, ';') FROM \`$db\`.dolt_schemas WHERE type = 'view' ORDER BY name" >> "/work/$db.sql"
                  fi
                done < /work/databases
                echo "dump done:"; ls -l /work; cat /work/counts.tsv /work/views.tsv
              EOT
              ]
              resources {
                requests = {
                  cpu    = "50m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "256Mi"
                }
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
            }
            container {
              name  = "verify"
              image = "dolthub/dolt-sql-server:2.4.2"
              env {
                name  = "PUSHGATEWAY"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091"
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -eu
                # Runs in the dolt image that matches the server. Restores the dump into a
                # scratch Dolt directory, checks every table and view came back, then gzips
                # the dump onto NFS, rotates, and pushes metrics.
                export HOME=/tmp
                dolt config --global --add user.name backup >/dev/null
                dolt config --global --add user.email backup@beads-server >/dev/null
                TS=$(date -u +%Y%m%d-%H%M)
                mkdir -p /tmp/restore && cd /tmp/restore
                while read -r db; do
                  dolt sql < "/work/$db.sql"
                done < /work/databases
                fail=0
                while IFS="$(printf '\t')" read -r db t n; do
                  got=$(dolt sql -r csv -q "SELECT COUNT(*) FROM \`$db\`.\`$t\`" | tail -n 1) || got=missing
                  echo "table $db.$t source=$n restored=$got"
                  if [ "$got" = missing ] || { [ "$n" -gt 0 ] && [ "$got" -eq 0 ]; }; then fail=1; fi
                done < /work/counts.tsv
                while IFS="$(printf '\t')" read -r db v; do
                  if dolt sql -r csv -q "SELECT COUNT(*) FROM \`$db\`.\`$v\`" > /dev/null; then echo "view $db.$v ok"; else echo "view $db.$v FAILED"; fail=1; fi
                done < /work/views.tsv
                [ "$fail" -eq 0 ] || { echo "restore check failed, not writing the backup"; exit 1; }

                out=/backup/$TS
                mkdir -p "$out.partial"
                while read -r db; do gzip -9 -c "/work/$db.sql" > "$out.partial/$db.sql.gz"; done < /work/databases
                cp /work/counts.tsv /work/views.tsv /work/VERSION /work/databases "$out.partial/"
                (cd "$out.partial" && sha256sum * > SHA256SUMS)
                mv "$out.partial" "$out"
                find /backup -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +14 -exec rm -rf {} +
                find /backup -mindepth 1 -maxdepth 1 -type d -name '*.partial' -mtime +1 -exec rm -rf {} +

                t0=$(cat /work/start)
                dur=$(( $(date -u +%s) - t0 ))
                bytes=$(du -sb "$out" | cut -f1)
                echo "backup written: $out ($bytes bytes, $dur s)"; ls -l "$out"
                cat <<METRICS | curl -sf --data-binary @- "$PUSHGATEWAY/metrics/job/dolt-backup" || echo "pushgateway push failed"
                backup_duration_seconds $dur
                backup_output_bytes $bytes
                backup_last_success_timestamp $(date -u +%s)
                METRICS
              EOT
              ]
              resources {
                requests = {
                  cpu    = "50m"
                  memory = "128Mi"
                }
                limits = {
                  memory = "512Mi"
                }
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
            }
            volume {
              name = "work"
              empty_dir {}
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_dolt_backup.claim_name
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# ── Dolt Workbench (web UI) ──

resource "kubernetes_config_map" "workbench_store" {
  metadata {
    name      = "workbench-store"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  data = {
    "store.json" = jsonencode([{
      name             = "beads"
      connectionUrl    = "mysql://beads@dolt.beads-server.svc.cluster.local:3306/code"
      hideDoltFeatures = false
      useSSL           = false
      type             = "Mysql"
    }])
  }
}

resource "kubernetes_deployment" "workbench" {
  metadata {
    name      = "dolt-workbench"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app  = "dolt-workbench"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "dolt-workbench"
      }
    }
    template {
      metadata {
        labels = {
          app = "dolt-workbench"
        }
      }
      spec {
        init_container {
          name = "seed-config"
          # Pinned 2026-05-26: Keel rolled :latest → :0.1.0 on 2026-05-17,
          # which speaks an old GraphQL schema (missing `type` arg on
          # addDatabaseConnection) → seed-config fails, UI can't add the
          # connection. :0.3.73 was the last Keel-resolved good tag.
          image = "dolthub/dolt-workbench:0.3.73"
          command = ["sh", "-c", <<-EOT
            # Seed connection store
            cp /config/store.json /store/store.json
            # Copy static JS to writable volume and patch GraphQL URL
            cp -r /app/web/.next/static/* /static/
            for f in /static/chunks/pages/_app-*.js; do
              sed -i 's|http://localhost:9002/graphql|/graphql|g' "$f"
            done
            echo "Patched GraphQL URL and store path"
          EOT
          ]
          volume_mount {
            name       = "store-config"
            mount_path = "/config"
            read_only  = true
          }
          volume_mount {
            name       = "store"
            mount_path = "/store"
          }
          volume_mount {
            name       = "static-patched"
            mount_path = "/static"
          }
        }

        container {
          name = "workbench"
          # Pinned 2026-05-26: Keel rolled :latest → :0.1.0 on 2026-05-17,
          # which speaks an old GraphQL schema (missing `type` arg on
          # addDatabaseConnection) → seed-config fails, UI can't add the
          # connection. :0.3.73 was the last Keel-resolved good tag; Keel then
          # rolled this container to :0.3.75, which is what runs at the Renovate
          # cutover (2026-10-10). Renovate proposes bumps from here.
          image = "dolthub/dolt-workbench:0.3.75"
          command = ["sh", "-c", <<-EOT
            # Patch GraphQL server to listen on 0.0.0.0 (IPv4) — Node 18+ defaults to IPv6
            sed -i 's|app.listen(9002)|app.listen(9002,"0.0.0.0")|g' /app/graphql-server/dist/main.js
            # Start PM2, then auto-connect to Dolt after GraphQL is ready
            pm2-runtime /app/process.yml &
            PM2_PID=$!
            # Wait for GraphQL server to be ready, then auto-connect
            for i in $(seq 1 30); do
              if node -e "fetch('http://127.0.0.1:9002/graphql',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({query:'{storedConnections{name}}'})}).then(r=>{if(r.ok)process.exit(0);process.exit(1)}).catch(()=>process.exit(1))" 2>/dev/null; then
                node -e "fetch('http://127.0.0.1:9002/graphql',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({query:'mutation{addDatabaseConnection(connectionUrl:\"mysql://beads@dolt.beads-server.svc.cluster.local:3306/code\",name:\"beads\",hideDoltFeatures:false,useSSL:false,type:Mysql){currentDatabase}}'})}).then(r=>r.text()).then(t=>{console.log('Auto-connect:',t);process.exit(0)}).catch(e=>{console.error(e);process.exit(1)})" 2>&1
                break
              fi
              sleep 1
            done &
            wait $PM2_PID
          EOT
          ]

          port {
            name           = "http"
            container_port = 3000
          }
          port {
            name           = "graphql"
            container_port = 9002
          }

          env {
            name  = "NODE_OPTIONS"
            value = "--dns-result-order=ipv4first"
          }
          env {
            name  = "GRAPHQLAPI_URL"
            value = "http://localhost:9002/graphql"
          }

          volume_mount {
            name       = "store"
            mount_path = "/app/graphql-server/store"
          }
          volume_mount {
            name       = "static-patched"
            mount_path = "/app/web/.next/static"
          }

          startup_probe {
            http_get {
              path = "/"
              port = 3000
            }
            failure_threshold = 30
            period_seconds    = 2
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = {
              memory = "128Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "store-config"
          config_map {
            name = kubernetes_config_map.workbench_store.metadata[0].name
          }
        }
        volume {
          name = "store"
          empty_dir {}
        }
        volume {
          name = "static-patched"
          empty_dir {}
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # LEGACY_TEMPLATE_ANNOTATIONS
    ]
  }
}

resource "kubernetes_service" "workbench" {
  metadata {
    name      = "dolt-workbench"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app = "dolt-workbench"
    }
  }
  spec {
    selector = {
      app = "dolt-workbench"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
    port {
      name        = "graphql"
      port        = 9002
      target_port = 9002
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.beads.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.beads.metadata[0].name
  name            = "dolt-workbench"
  tls_secret_name = var.tls_secret_name
  # auth = "none": Dolt Workbench is client-side encrypted task database; no backend user auth required; Anubis PoW fronts ingress.
  auth = "none"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Dolt Workbench"
    "gethomepage.dev/description"  = "Beads task database UI"
    "gethomepage.dev/icon"         = "mdi-database"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}

# GraphQL API ingress — the frontend JS hardcodes localhost:9002/graphql,
# but we rewrite the browser request to hit the same hostname on /graphql
# routed to port 9002.
resource "kubernetes_ingress_v1" "graphql" {
  metadata {
    name      = "dolt-workbench-graphql"
    namespace = kubernetes_namespace.beads.metadata[0].name
    annotations = {
      # No Authentik — browser fetch() can't follow 302 redirects on POST.
      # Main page (/) is still protected. GraphQL has no sensitive data beyond task list.
    }
  }
  spec {
    ingress_class_name = "traefik"
    tls {
      hosts       = ["dolt-workbench.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "dolt-workbench.viktorbarzin.me"
      http {
        path {
          path      = "/graphql"
          path_type = "Exact"
          backend {
            service {
              name = kubernetes_service.workbench.metadata[0].name
              port {
                number = 9002
              }
            }
          }
        }
      }
    }
  }
}

# ── BeadBoard (task visualization dashboard) ──

resource "kubernetes_config_map" "beadboard_config" {
  metadata {
    name      = "beadboard-beads-config"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  data = {
    "metadata.json" = jsonencode({
      database         = "dolt"
      backend          = "dolt"
      dolt_mode        = "server"
      dolt_server_host = "dolt.beads-server.svc.cluster.local"
      dolt_server_port = 3306
      dolt_server_user = "root"
      dolt_database    = "code"
      project_id       = "a8f8bae7-ce65-4145-a5db-a13d11d297da"
    })
    "dolt-server.port" = "3306"
  }
}

# Pulls the claude-agent-service bearer token from Vault so BeadBoard can
# dispatch agent jobs via the in-cluster HTTP API.
resource "kubernetes_manifest" "beadboard_agent_service_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "beadboard-agent-service"
      namespace = kubernetes_namespace.beads.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "beadboard-agent-service"
      }
      data = [
        {
          secretKey = "api_bearer_token"
          remoteRef = {
            key      = "claude-agent-service"
            property = "api_bearer_token"
          }
        },
      ]
    }
  }
}

resource "kubernetes_deployment" "beadboard" {
  metadata {
    name      = "beadboard"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app  = "beadboard"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "beadboard"
      }
    }
    template {
      metadata {
        labels = {
          app = "beadboard"
        }
      }
      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }

        init_container {
          name    = "seed-beads-config"
          image   = "busybox:1.36.1"
          command = ["sh", "-c", "cp /config/* /beads/ && mkdir -p /beads/templates /beads/archetypes"]
          volume_mount {
            name       = "beads-config"
            mount_path = "/config"
            read_only  = true
          }
          volume_mount {
            name       = "beads-writable"
            mount_path = "/beads"
          }
        }

        container {
          name = "beadboard"
          # Phase 3 cutover 2026-05-07 — Forgejo registry consolidation.
          image = "ghcr.io/viktorbarzin/beadboard:${var.beadboard_image_tag}"

          port {
            name           = "http"
            container_port = 3000
          }

          env {
            name  = "CLAUDE_AGENT_SERVICE_URL"
            value = "http://claude-agent-service.claude-agent.svc.cluster.local:8080"
          }

          env {
            name = "CLAUDE_AGENT_BEARER_TOKEN"
            value_from {
              secret_key_ref {
                name = "beadboard-agent-service"
                key  = "api_bearer_token"
              }
            }
          }

          volume_mount {
            name       = "beads-writable"
            mount_path = "/app/.beads"
          }

          startup_probe {
            http_get {
              path = "/"
              port = 3000
            }
            failure_threshold = 30
            period_seconds    = 2
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "beads-config"
          config_map {
            name = kubernetes_config_map.beadboard_config.metadata[0].name
          }
        }
        volume {
          name = "beads-writable"
          empty_dir {}
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],                      # LEGACY_TEMPLATE_ANNOTATIONS
      spec[0].template[0].spec[0].container[0].image,                                          # CI_SETS_IMAGE: first-party image, deployed by its own CI
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "beadboard" {
  metadata {
    name      = "beadboard"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app = "beadboard"
    }
  }
  spec {
    selector = {
      app = "beadboard"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

module "beadboard_ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.beads.metadata[0].name
  name            = "beadboard"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "BeadBoard"
    "gethomepage.dev/description"  = "Agent task visualization dashboard"
    "gethomepage.dev/icon"         = "mdi-chart-gantt"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}

# ── Beads auto-dispatch (dispatcher + reaper CronJobs) ──
#
# Flow:
#   user: bd assign <id> agent
#     └──> CronJob: beads-dispatcher (every 2 min)
#            1. GET BeadBoard /api/agent-status — skip if claude-agent-service busy
#            2. bd query 'assignee=agent AND status=open' — pick highest priority
#            3. bd update -s in_progress  (claim; next tick won't re-pick)
#            4. POST BeadBoard /api/agent-dispatch — reuses prompt-build + bearer flow
#            5. bd note "dispatched: job=<id>"  (or rollback + note on failure)
#
#   CronJob: beads-reaper (every 10 min)
#     └── for bead (assignee=agent, status=in_progress, updated_at > 30m):
#           bd update -s blocked + bd note  (recover from pod crashes mid-run)
#
# The claude-agent-service image ships bd + jq + curl — no separate image built.

resource "kubernetes_config_map" "beads_metadata" {
  metadata {
    name      = "beads-metadata"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  data = {
    "metadata.json" = jsonencode({
      database         = "dolt"
      backend          = "dolt"
      dolt_mode        = "server"
      dolt_server_host = "${kubernetes_service.dolt.metadata[0].name}.${kubernetes_namespace.beads.metadata[0].name}.svc.cluster.local"
      dolt_server_port = 3306
      dolt_server_user = "beads"
      dolt_database    = "code"
      project_id       = "a8f8bae7-ce65-4145-a5db-a13d11d297da"
    })
  }
}

locals {
  # Phase 3 cutover 2026-05-07 — Forgejo registry consolidation.
  claude_agent_service_image = "ghcr.io/viktorbarzin/claude-agent-service:${var.claude_agent_service_image_tag}"
  beadboard_internal_url     = "http://${kubernetes_service.beadboard.metadata[0].name}.${kubernetes_namespace.beads.metadata[0].name}.svc.cluster.local"

  beads_script_prelude = <<-EOT
    set -euo pipefail
    # bd with Dolt server mode needs metadata.json in a directory it can walk.
    # ConfigMap mounts are read-only — copy to a writable location before use.
    mkdir -p /tmp/.beads
    cp /etc/beads-metadata/metadata.json /tmp/.beads/metadata.json
  EOT
}

resource "kubernetes_cron_job_v1" "beads_dispatcher" {
  metadata {
    name      = "beads-dispatcher"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  spec {
    schedule                      = "*/2 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 60
    suspend                       = !var.beads_dispatcher_enabled
    job_template {
      metadata {}
      spec {
        backoff_limit              = 0
        ttl_seconds_after_finished = 600
        template {
          metadata {
            labels = {
              app = "beads-dispatcher"
            }
          }
          spec {
            restart_policy = "Never"
            image_pull_secrets {
              name = "registry-credentials"
            }
            container {
              name  = "dispatcher"
              image = local.claude_agent_service_image
              command = ["/bin/sh", "-c", <<-EOT
                ${local.beads_script_prelude}

                BUSY=$(curl -sf "$${BEADBOARD_URL}/api/agent-status" | jq -r '.busy // false')
                if [ "$BUSY" != "false" ]; then
                  echo "claude-agent-service is busy — skipping tick"
                  exit 0
                fi

                BEAD=$(bd --db /tmp/.beads query 'assignee=agent AND status=open' --json \
                  | jq -r '[.[] | select(.acceptance_criteria and (.acceptance_criteria | length) > 0)]
                           | sort_by(.priority, .updated_at)[0].id // empty')

                if [ -z "$BEAD" ]; then
                  echo "no eligible beads (assignee=agent, status=open, has acceptance_criteria)"
                  exit 0
                fi

                echo "picked bead: $BEAD"

                bd --db /tmp/.beads update "$BEAD" -s in_progress
                bd --db /tmp/.beads note   "$BEAD" "auto-dispatcher claimed at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

                RESP=$(curl -sS -w '\n%%{http_code}' -X POST \
                  -H 'Content-Type: application/json' \
                  -d "{\"taskId\":\"$BEAD\"}" \
                  "$${BEADBOARD_URL}/api/agent-dispatch")
                CODE=$(printf '%s' "$RESP" | tail -n1)
                BODY=$(printf '%s' "$RESP" | sed '$d')

                if [ "$CODE" = "200" ]; then
                  JOB_ID=$(printf '%s' "$BODY" | jq -r '.job_id // "unknown"')
                  bd --db /tmp/.beads note "$BEAD" "dispatched: job=$JOB_ID"
                  echo "dispatched $BEAD as job $JOB_ID"
                else
                  # Roll the claim back so the next tick can retry.
                  bd --db /tmp/.beads update "$BEAD" -s open
                  bd --db /tmp/.beads note   "$BEAD" "dispatch failed HTTP $CODE: $BODY"
                  echo "dispatch FAILED for $BEAD: HTTP $CODE — $BODY" >&2
                  exit 1
                fi
              EOT
              ]
              env {
                name  = "BEADBOARD_URL"
                value = local.beadboard_internal_url
              }
              env {
                name = "API_BEARER_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "beadboard-agent-service"
                    key  = "api_bearer_token"
                  }
                }
              }
              env {
                name  = "BEADS_ACTOR"
                value = "beads-dispatcher"
              }
              env {
                name  = "HOME"
                value = "/tmp"
              }
              volume_mount {
                name       = "beads-metadata"
                mount_path = "/etc/beads-metadata"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "50m"
                  memory = "128Mi"
                }
                limits = {
                  memory = "256Mi"
                }
              }
            }
            volume {
              name = "beads-metadata"
              config_map {
                name = kubernetes_config_map.beads_metadata.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_cron_job_v1" "beads_reaper" {
  metadata {
    name      = "beads-reaper"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  spec {
    schedule                      = "*/10 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 60
    suspend                       = !var.beads_dispatcher_enabled
    job_template {
      metadata {}
      spec {
        backoff_limit              = 0
        ttl_seconds_after_finished = 600
        template {
          metadata {
            labels = {
              app = "beads-reaper"
            }
          }
          spec {
            restart_policy = "Never"
            image_pull_secrets {
              name = "registry-credentials"
            }
            container {
              name  = "reaper"
              image = local.claude_agent_service_image
              command = ["/bin/sh", "-c", <<-EOT
                ${local.beads_script_prelude}

                THRESHOLD_MIN=30
                NOW=$(date -u +%s)

                bd --db /tmp/.beads query 'assignee=agent AND status=in_progress' --json \
                  | jq -c '.[]' \
                  | while read -r BEAD_JSON; do
                      ID=$(printf '%s' "$BEAD_JSON" | jq -r '.id')
                      LAST_UPDATE=$(printf '%s' "$BEAD_JSON" | jq -r '.updated_at')
                      # Alpine's busybox date lacks GNU -d; parse ISO-8601 with python3.
                      LAST_TS=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$LAST_UPDATE'.replace('Z','+00:00')).timestamp()))")
                      AGE_MIN=$(( (NOW - LAST_TS) / 60 ))
                      if [ "$AGE_MIN" -gt "$THRESHOLD_MIN" ]; then
                        bd --db /tmp/.beads note   "$ID" "reaper: no progress for $${AGE_MIN}m (threshold $${THRESHOLD_MIN}m) — blocking"
                        bd --db /tmp/.beads update "$ID" -s blocked
                        echo "REAPED $ID (stale $${AGE_MIN}m)"
                      else
                        echo "keeping $ID (age $${AGE_MIN}m < $${THRESHOLD_MIN}m)"
                      fi
                    done
              EOT
              ]
              env {
                name  = "BEADS_ACTOR"
                value = "beads-reaper"
              }
              env {
                name  = "HOME"
                value = "/tmp"
              }
              volume_mount {
                name       = "beads-metadata"
                mount_path = "/etc/beads-metadata"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "50m"
                  memory = "128Mi"
                }
                limits = {
                  memory = "256Mi"
                }
              }
            }
            volume {
              name = "beads-metadata"
              config_map {
                name = kubernetes_config_map.beads_metadata.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
