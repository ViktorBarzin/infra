# Nextcloud Files External bootstrap — mount-per-archive + applicable_users model.
# Creates two admin-only root browser mounts (PVE NFS Pool, PVE NFS-SSD Pool)
# pointing at the NFS roots mounted at /mnt/pve-nfs and /mnt/pve-nfs-ssd inside
# the Nextcloud container, plus per-archive mounts visible only to the named
# users. Safe to re-run — the bootstrap Job is idempotent.
#
# ACL model (verified via context7 + NC docs):
#   Mount visibility is controlled by `occ files_external:applicable`.
#   A mount with no applicable users/groups is visible to ALL users — so we
#   always set at least one applicable group (admin) or user list.
#
# occ commands used (syntax verified via context7):
#   files_external:create <mountPoint> local null::null --config "datadir=<dir>"
#   files_external:list --output=json   → array; each entry has numeric .mount_id,
#                                          .applicable_users [], .applicable_groups []
#   files_external:applicable <mountId> --add-user=<user>
#   files_external:applicable <mountId> --remove-user=<user>
#   files_external:applicable <mountId> --add-group=<group>
#   files_external:applicable <mountId> --remove-group=<group>
#
# Note: `files_external:applicable` has NO --output=json flag (write-only command).
# Current applicable state is read from files_external:list --output=json instead.
#
# NO Files Access Control. Drop the workflow-engine machinery entirely.

# ── External storage manifest (JSON) ────────────────────────────────────────

resource "kubernetes_config_map_v1" "nextcloud_external_storage_manifest" {
  metadata {
    name      = "nextcloud-external-storage-manifest"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  data = {
    "manifest.json" = jsonencode({
      # enableSharing: lets users right-click a folder inside the mount and
      # share it with another NC user/group/public link. NC defaults to false
      # for local-backend mounts; we opt-in per-mount. Currently true on the
      # admin pool browsers (admin uses them as a "share-from picker"); false
      # on /anca-elements (anca manages her own re-sharing inside her view).
      rootMounts = [
        {
          mountPoint      = "/PVE NFS Pool"
          dataDir         = "/mnt/pve-nfs"
          applicableGroup = "admin"
          enableSharing   = true
        },
        {
          mountPoint      = "/PVE NFS-SSD Pool"
          dataDir         = "/mnt/pve-nfs-ssd"
          applicableGroup = "admin"
          enableSharing   = true
        },
      ]
      archiveMounts = [
        {
          mountPoint       = "/anca-elements"
          dataDir          = "/mnt/pve-nfs/anca-elements"
          # NC usernames (not display names): admin is Viktor, anca is Anca.
          applicableUsers  = ["anca", "admin"]
          applicableGroups = []
          enableSharing    = false
        },
      ]
    })
  }
}

# ── RBAC for the bootstrap Job ───────────────────────────────────────────────

resource "kubernetes_service_account" "nextcloud_external_storage_bootstrap" {
  metadata {
    name      = "nextcloud-external-storage-bootstrap"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
}

resource "kubernetes_role" "nextcloud_external_storage_bootstrap" {
  metadata {
    name      = "nextcloud-external-storage-bootstrap"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list", "get", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "nextcloud_external_storage_bootstrap" {
  metadata {
    name      = "nextcloud-external-storage-bootstrap"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.nextcloud_external_storage_bootstrap.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.nextcloud_external_storage_bootstrap.metadata[0].name
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
}

# ── Bootstrap Job ────────────────────────────────────────────────────────────

resource "kubernetes_job_v1" "nextcloud_external_storage_bootstrap" {
  # The bootstrap script (below) waits up to 10m for the NC pod to be Ready.
  # kubernetes_job_v1's default create timeout is only 1m, which spuriously
  # fails the apply whenever the NC pod takes >1m to come up — e.g. now that
  # Keel auto-upgrades nextcloud, a bump mid-apply runs `occ upgrade` in the
  # entrypoint and delays readiness past 1m (observed 2026-06-01). Match the
  # script's 10m wait plus margin.
  timeouts {
    create = "12m"
  }

  metadata {
    name      = "nextcloud-external-storage-bootstrap"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit              = 5
    ttl_seconds_after_finished = 600

    template {
      metadata {}
      spec {
        restart_policy       = "OnFailure"
        service_account_name = kubernetes_service_account.nextcloud_external_storage_bootstrap.metadata[0].name

        container {
          name  = "bootstrap"
          image = "bitnami/kubectl:latest"

          # bitnami/kubectl (debian-12 base) ships jq — no apt-get needed.
          # HCL heredoc: only $${...} needs escaping; bare $VAR and $(...)
          # are passed through unchanged by HCL. No nested heredocs used.
          command = ["/bin/bash", "-c", <<-EOF
            set -euo pipefail
            trap 'echo "[bootstrap] FAIL at line $LINENO — exit $?"' ERR

            MANIFEST=/manifest/manifest.json
            NC_NS=nextcloud
            NC_LABEL="app.kubernetes.io/name=nextcloud"

            # ── 1. Wait for NC pod to be Ready ──────────────────────────────
            echo "[bootstrap] Waiting for NC pod Ready (timeout 10m)..."
            kubectl wait -n "$NC_NS" pod \
              -l "$NC_LABEL" \
              --for=condition=Ready \
              --timeout=600s
            echo "[bootstrap] Pod is Ready."

            # ── 2. Resolve pod name ─────────────────────────────────────────
            NC_POD=$(kubectl get pods -n "$NC_NS" -l "$NC_LABEL" \
              -o jsonpath='{.items[0].metadata.name}')
            echo "[bootstrap] Target pod: $NC_POD"

            # ── 3. occ helper — must run as www-data ────────────────────────
            nc_occ() {
              kubectl exec -n "$NC_NS" "$NC_POD" -c nextcloud -- \
                runuser -u www-data -- php /var/www/html/occ "$@"
            }

            # ── 4. Enable files_external (idempotent) ───────────────────────
            nc_occ app:enable files_external || true
            # NO files_accesscontrol — that app is not used in this model.

            # ── 5. Helpers ──────────────────────────────────────────────────

            # get_mount_id <mountPoint>
            # Reads files_external:list --output=json (array of mount objects).
            # Each object has a numeric "mount_id" and a string "mount_point".
            get_mount_id() {
              local MP="$1"
              nc_occ files_external:list --output=json 2>/dev/null \
                | jq -r --arg mp "$MP" \
                    '.[] | select(.mount_point == $mp) | .mount_id' \
                | head -1
            }

            # ensure_mount <mountPoint> <dataDir> → echoes the numeric mount id
            ensure_mount() {
              local MP="$1" DIR="$2"
              local MID
              MID=$(get_mount_id "$MP")
              if [ -z "$MID" ]; then
                echo "[bootstrap] Creating mount '$MP' -> $DIR" >&2
                nc_occ files_external:create "$MP" local null::null \
                  --config "datadir=$DIR"
                MID=$(get_mount_id "$MP")
              else
                echo "[bootstrap] Mount '$MP' already exists (id=$MID)" >&2
              fi
              echo "$MID"
            }

            # sync_applicable <mountId> <desiredUsersJSON> <desiredGroupsJSON>
            # Reads current applicable state from files_external:list --output=json
            # (fields: applicable_users [], applicable_groups []).
            # Diffs against desired sets; adds missing, removes extras.
            # When no applicable users + no groups are set, NC treats the mount
            # as visible to ALL — so desired sets must always be non-empty.
            #
            # Process substitution `< <(jq ...)` feeds the loops directly: when
            # jq emits no rows (already-synced state), the body never runs and
            # the loop returns 0 — avoiding a set -e exit on a no-op re-run.
            sync_applicable() {
              local MID="$1" DESIRED_USERS_JSON="$2" DESIRED_GROUPS_JSON="$3"

              # Read current state from files_external:list --output=json
              local MOUNT_JSON
              MOUNT_JSON=$(nc_occ files_external:list --output=json 2>/dev/null \
                | jq -c --argjson mid "$MID" '.[] | select(.mount_id == $mid)')

              local CURRENT_USERS_JSON CURRENT_GROUPS_JSON
              CURRENT_USERS_JSON=$(echo "$MOUNT_JSON" \
                | jq -c '.applicable_users // []')
              CURRENT_GROUPS_JSON=$(echo "$MOUNT_JSON" \
                | jq -c '.applicable_groups // []')

              while IFS= read -r U; do
                nc_occ files_external:applicable "$MID" --add-user="$U"
              done < <(jq -rn \
                --argjson d "$DESIRED_USERS_JSON" \
                --argjson c "$CURRENT_USERS_JSON" \
                '($d - $c)[]')

              while IFS= read -r U; do
                nc_occ files_external:applicable "$MID" --remove-user="$U"
              done < <(jq -rn \
                --argjson d "$DESIRED_USERS_JSON" \
                --argjson c "$CURRENT_USERS_JSON" \
                '($c - $d)[]')

              while IFS= read -r G; do
                nc_occ files_external:applicable "$MID" --add-group="$G"
              done < <(jq -rn \
                --argjson d "$DESIRED_GROUPS_JSON" \
                --argjson c "$CURRENT_GROUPS_JSON" \
                '($d - $c)[]')

              while IFS= read -r G; do
                nc_occ files_external:applicable "$MID" --remove-group="$G"
              done < <(jq -rn \
                --argjson d "$DESIRED_GROUPS_JSON" \
                --argjson c "$CURRENT_GROUPS_JSON" \
                '($c - $d)[]')
            }

            # sync_option <mountId> <key> <value>
            # Reconciles a single mount option. occ files_external:option is
            # idempotent (no error on setting same value), so we always write.
            sync_option() {
              nc_occ files_external:option "$1" "$2" "$3" >/dev/null
            }

            # ── 6. Process root mounts (admin group only) ───────────────────
            ROOT_COUNT=$(jq '.rootMounts | length' "$MANIFEST")
            for i in $(seq 0 $((ROOT_COUNT - 1))); do
              MP=$(jq -r ".rootMounts[$i].mountPoint" "$MANIFEST")
              DIR=$(jq -r ".rootMounts[$i].dataDir" "$MANIFEST")
              GROUP=$(jq -r ".rootMounts[$i].applicableGroup" "$MANIFEST")
              ENABLE_SHARING=$(jq -r ".rootMounts[$i].enableSharing // false" "$MANIFEST")
              MID=$(ensure_mount "$MP" "$DIR")
              sync_applicable "$MID" '[]' "[\"$GROUP\"]"
              sync_option "$MID" enable_sharing "$ENABLE_SHARING"
            done

            # ── 7. Process archive mounts (per-user / per-group) ───────────
            ARCH_COUNT=$(jq '.archiveMounts | length' "$MANIFEST")
            for i in $(seq 0 $((ARCH_COUNT - 1))); do
              MP=$(jq -r ".archiveMounts[$i].mountPoint" "$MANIFEST")
              DIR=$(jq -r ".archiveMounts[$i].dataDir" "$MANIFEST")
              USERS_JSON=$(jq -c ".archiveMounts[$i].applicableUsers // []" "$MANIFEST")
              GROUPS_JSON=$(jq -c ".archiveMounts[$i].applicableGroups // []" "$MANIFEST")
              ENABLE_SHARING=$(jq -r ".archiveMounts[$i].enableSharing // false" "$MANIFEST")
              MID=$(ensure_mount "$MP" "$DIR")
              sync_applicable "$MID" "$USERS_JSON" "$GROUPS_JSON"
              sync_option "$MID" enable_sharing "$ENABLE_SHARING"
            done

            echo "[bootstrap] Bootstrap complete."
          EOF
          ]

          volume_mount {
            name       = "manifest"
            mount_path = "/manifest"
          }
        }

        volume {
          name = "manifest"
          config_map {
            name = kubernetes_config_map_v1.nextcloud_external_storage_manifest.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [helm_release.nextcloud]

  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}
