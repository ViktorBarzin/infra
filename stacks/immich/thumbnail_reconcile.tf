# Thumbnail reconciler — self-heals photos that the job pipeline dropped.
#
# WHY THIS EXISTS (2026-09-01)
#
# Immich builds a thumbnail by chaining metadataExtraction -> thumbnailGeneration
# through BullMQ on Redis. That chain is durable for the ordinary failures: Redis
# runs appendonly=yes on a PVC, so a restart replays the queue (verified: peak
# 372 MiB against a 640 MiB cap, zero evictions, through a 527k-job backlog), and
# BullMQ re-queues a job whose worker died mid-flight. Two cases are NOT covered,
# and both are permanent:
#
#   1. A job that exhausts its retries lands in the `failed` set. Nothing ever
#      looks at it again.
#   2. The server dies between writing the asset row and enqueuing its job, so no
#      job ever existed and there is nothing to retry.
#
# Either way the photo keeps its original bytes and never gets a tile, and the
# only repair is a person noticing a grey square and clicking a button. On
# 2026-08-31, 248 assets were in that state and the oldest dated to the NFS
# migration, because nothing had ever looked.
#
# Both cases leave the same fingerprint: a visible asset, older than the grace
# window, with a decodable original and no thumbnail row. This job looks for
# exactly that once a night and re-enqueues the repair.
#
# WHY AN AGE FILTER RATHER THAN A QUEUE CHECK
#
# The reconciler must not pile work onto a backlog that is already draining —
# that is how the shared sdc spindle gets into an IO storm (see
# docs/post-mortems/2026-05-25-immich-anca-elements-io-storm.md). Reading queue
# depth from /api/jobs to decide would mean parsing nested JSON in a shell with
# no jq. STUCK_AFTER does the same job more simply and more honestly: a healthy
# upload gets its thumbnail in about 2 seconds (measured 2026-09-01), and even
# the whole-library sweep of 2026-08-31 drained in about 7 hours, so anything
# still bare after 24h was dropped rather than queued. Nothing in flight is ever
# touched.
#
# WHY NOT THE BUILT-IN "MISSING" BUTTON
#
# `PUT /api/jobs/thumbnailGeneration {command:start, force:false}` would cover
# every owner in one admin call, but its missing-scope query
# (streamForThumbnailJob) ORs in "has no fullsize derivative AND is a
# web-unsupported format" whenever image.fullsize.enabled is true. It is, and
# only 2,571 of 60,195 visible HEIC/RAW assets have a fullsize file, so "Missing"
# matches 57,629 assets rather than the ~110 that actually lack a thumbnail. At a
# measured 1,146 KiB per fullsize file that is ~63 GB against 38 GB free on the
# thumbs volume, so the button that reads as the safe one would fill the disk.
# Per-asset regenerate-thumbnail sidesteps the whole question: it rebuilds
# thumbnail+preview straight from the original and skips the metadata gate.
#
# The cost of that choice is that POST /api/assets/jobs checks asset.update per
# asset, which admin does not inherit across users, so each owner needs their own
# key. Viktor and Anca have one in Vault secret/immich; anything stuck under
# another owner is counted in immich_thumbnail_repair_unowned and alerted rather
# than silently skipped.

# The classifier is a real file rather than an inline heredoc so it can be linted,
# diffed and tested on its own. See the header comment in the .js for why it
# decodes each candidate instead of guessing from file shape.
resource "kubernetes_config_map_v1" "immich_thumbnail_reconcile" {
  metadata {
    name      = "immich-thumbnail-reconcile"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  data = {
    "classify.js" = file("${path.module}/thumbnail_reconcile_classify.js")
  }
}

resource "kubernetes_cron_job_v1" "immich_thumbnail_reconcile" {
  metadata {
    name      = "immich-thumbnail-reconcile"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    # 04:40 — after postgresql-backup (00:00) and clear of the frame syncs.
    schedule                  = "40 4 * * *"
    starting_deadline_seconds = 300
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 1800
        ttl_seconds_after_finished = 3600
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            volume {
              name = "shared"
              empty_dir {}
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map_v1.immich_thumbnail_reconcile.metadata[0].name
              }
            }
            volume {
              name = "library"
              persistent_volume_claim {
                claim_name = module.nfs_library_host.claim_name
                read_only  = true
              }
            }
            volume {
              name = "upload"
              persistent_volume_claim {
                claim_name = module.nfs_upload_host.claim_name
                read_only  = true
              }
            }

            # 1. Which assets are stuck. psql only — the postgres image is the one
            #    that has it, and it has no business touching the photo volumes.
            init_container {
              name  = "scan"
              image = "ghcr.io/immich-app/postgres:15-vectorchord0.4.3-pgvectors0.2.0"
              command = ["/bin/bash", "-c", <<-EOT
                set -uo pipefail
                : > /shared/stuck.tsv
                success=1

                if ! psql -v ON_ERROR_STOP=1 -tA -F$'\t' -c "
                      SELECT a.id, a.\"ownerId\", a.type, a.\"originalPath\"
                      FROM asset a
                      WHERE a.\"deletedAt\" IS NULL
                        AND a.visibility <> 'hidden'
                        AND a.\"createdAt\" < now() - interval '$STUCK_AFTER'
                        AND NOT EXISTS (
                          SELECT 1 FROM asset_file f
                          WHERE f.\"assetId\" = a.id AND f.type = 'thumbnail')
                      ORDER BY a.\"createdAt\" DESC
                    " > /shared/stuck.tsv 2>/tmp/err; then
                  success=0
                  cat /tmp/err >&2
                fi

                stuck=$(wc -l < /shared/stuck.tsv | tr -d ' ')
                {
                  echo "# HELP immich_thumbnail_stuck_assets Visible assets older than the grace window with no thumbnail file."
                  echo "# TYPE immich_thumbnail_stuck_assets gauge"
                  echo "immich_thumbnail_stuck_assets $stuck"
                  echo "# HELP immich_thumbnail_reconcile_scan_success 1 if the scan query succeeded."
                  echo "# TYPE immich_thumbnail_reconcile_scan_success gauge"
                  echo "immich_thumbnail_reconcile_scan_success $success"
                } > /shared/metrics.prom

                echo "stuck=$stuck success=$success"
                exit 0
              EOT
              ]
              env {
                name  = "PGHOST"
                value = "immich-postgresql.immich.svc.cluster.local"
              }
              env {
                name  = "PGUSER"
                value = "immich"
              }
              env {
                name  = "PGDATABASE"
                value = "immich"
              }
              env {
                name  = "PGCONNECT_TIMEOUT"
                value = "10"
              }
              env {
                name = "PGPASSWORD"
                value_from {
                  secret_key_ref {
                    name = "immich-secrets"
                    key  = "db_password"
                  }
                }
              }
              # Grace window. Long enough that a legitimate whole-library sweep
              # finishes inside it, so in-flight work is never duplicated.
              env {
                name  = "STUCK_AFTER"
                value = "24 hours"
              }
              volume_mount {
                name       = "shared"
                mount_path = "/shared"
              }
              resources {
                requests = { cpu = "50m", memory = "64Mi" }
                limits   = { memory = "192Mi" }
              }
            }

            # 2. Can each one still be decoded? Runs on the immich image because
            #    that is where sharp/libvips and ffprobe live — the same decoders
            #    thumbnail generation itself uses, so the answer is the real one.
            init_container {
              name    = "classify"
              image   = "ghcr.io/immich-app/immich-server:${var.immich_version}"
              command = ["node", "/script/classify.js"]
              env {
                name  = "VIKTOR_OWNER"
                value = local.immich_owner_viktor
              }
              env {
                name  = "ANCA_OWNER"
                value = local.immich_owner_anca
              }
              # Ceiling on full decodes per run so a pathological backlog cannot
              # turn one night's reconcile into a library-wide read.
              env {
                name  = "CLASSIFY_LIMIT"
                value = "1000"
              }
              volume_mount {
                name       = "shared"
                mount_path = "/shared"
              }
              volume_mount {
                name       = "script"
                mount_path = "/script"
                read_only  = true
              }
              volume_mount {
                name       = "library"
                mount_path = "/usr/src/app/upload/library"
                read_only  = true
              }
              volume_mount {
                name       = "upload"
                mount_path = "/usr/src/app/upload/upload"
                read_only  = true
              }
              resources {
                requests = { cpu = "100m", memory = "256Mi" }
                limits   = { memory = "1Gi" }
              }
            }

            # 3. Re-enqueue the survivors, batched, routed to each owner's key.
            init_container {
              name  = "repair"
              image = "docker.io/curlimages/curl:8.11.1"
              command = ["/bin/sh", "-c", <<-EOT
                set -u
                queued=0
                for pair in "$VIKTOR_OWNER:$VIKTOR_KEY" "$ANCA_OWNER:$ANCA_KEY"; do
                  owner=$${pair%%:*}
                  key=$${pair#*:}
                  awk -F'\t' -v o="$owner" '$1 == o { print $2 }' /shared/repair.tsv \
                    | head -n "$MAX_REPAIR" > /shared/batch.txt
                  n=$(wc -l < /shared/batch.txt | tr -d ' ')
                  [ "$n" -gt 0 ] || continue
                  # 50 ids per request keeps the body small and bounds how much
                  # lands on the HDD at once.
                  rm -f /shared/chunk.*
                  split -l 50 /shared/batch.txt /shared/chunk.
                  for f in /shared/chunk.*; do
                    [ -f "$f" ] || continue
                    awk 'BEGIN { printf "{\"assetIds\":[" }
                         { printf "%s\"%s\"", sep, $1; sep = "," }
                         END { printf "],\"name\":\"regenerate-thumbnail\"}" }' "$f" > /shared/body.json
                    code=$(curl -s -o /dev/null -w '%%{http_code}' -m 60 \
                           -X POST -H "x-api-key: $key" -H 'Content-Type: application/json' \
                           --data-binary @/shared/body.json "$IMMICH_URL/api/assets/jobs")
                    if [ "$code" = "204" ] || [ "$code" = "200" ]; then
                      queued=$((queued + $(wc -l < "$f" | tr -d ' ')))
                    else
                      echo "owner $owner batch failed: HTTP $code" >&2
                    fi
                    rm -f "$f"
                    sleep 2
                  done
                done
                {
                  echo "# HELP immich_thumbnail_repair_queued Assets re-enqueued for thumbnail generation on this run."
                  echo "# TYPE immich_thumbnail_repair_queued gauge"
                  echo "immich_thumbnail_repair_queued $queued"
                  echo "# HELP immich_thumbnail_reconcile_last_run_timestamp Unix time of the last reconcile run."
                  echo "# TYPE immich_thumbnail_reconcile_last_run_timestamp gauge"
                  echo "immich_thumbnail_reconcile_last_run_timestamp $(date +%s)"
                } >> /shared/metrics.prom
                echo "queued=$queued"
                exit 0
              EOT
              ]
              env {
                name  = "IMMICH_URL"
                value = "http://immich-server.immich.svc.cluster.local:2283"
              }
              # Ceiling per owner per night. Steady state is single digits; a
              # number near this cap means something upstream broke, which is what
              # ImmichThumbnailRepairNotTaking is for.
              env {
                name  = "MAX_REPAIR"
                value = "500"
              }
              env {
                name  = "VIKTOR_OWNER"
                value = local.immich_owner_viktor
              }
              env {
                name  = "ANCA_OWNER"
                value = local.immich_owner_anca
              }
              env {
                name = "VIKTOR_KEY"
                value_from {
                  secret_key_ref {
                    name = "immich-secrets"
                    key  = "viktor_api_key"
                  }
                }
              }
              env {
                name = "ANCA_KEY"
                value_from {
                  secret_key_ref {
                    name = "immich-secrets"
                    key  = "anca_api_key"
                  }
                }
              }
              volume_mount {
                name       = "shared"
                mount_path = "/shared"
              }
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "64Mi" }
              }
            }

            container {
              name  = "push"
              image = "docker.io/curlimages/curl:8.11.1"
              command = [
                "curl", "-sf", "-m", "20", "--data-binary", "@/shared/metrics.prom",
                "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/immich-thumbnail-reconcile",
              ]
              volume_mount {
                name       = "shared"
                mount_path = "/shared"
              }
              resources {
                requests = { cpu = "10m", memory = "16Mi" }
                limits   = { memory = "32Mi" }
              }
            }
          }
        }
      }
    }
  }
}
