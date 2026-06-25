# Thin CNPG operand image: the stock PostGIS-16 operand + pgvector.
#
# WHY this exists (see docs/runbooks/promote-pgvector-cnpg.md):
#   The shared pg-cluster runs `ghcr.io/cloudnative-pg/postgis:16`, which bundles
#   PostGIS but NOT pgvector. claude-memory's hybrid-recall upgrade needs the
#   `vector` extension (halfvec(1024) + HNSW). The CNPG `standard` operand flavor
#   bundles pgvector but DROPS PostGIS — unsafe if any pg-cluster tenant uses the
#   PostGIS extension. This thin image keeps PostGIS (same operand base, same
#   bookworm OS → no collation jump) and adds pgvector via the Debian package, so
#   it is a safe drop-in regardless of the PostGIS pre-check outcome.
#
#   If the PostGIS pre-check (runbook step 1) confirms NO tenant uses PostGIS,
#   prefer the pull-only `ghcr.io/cloudnative-pg/postgresql:16-standard-bookworm`
#   instead and skip this build entirely.
#
# BUILD: off-cluster via GitHub Actions → ghcr (infra ADR-0002 — no in-cluster
#   builds). Tag with a content hash, e.g.
#   `ghcr.io/viktorbarzin/cnpg-postgis-pgvector:16-<shortsha>`, then point the
#   pg_cluster `imageName` + `triggers.image` at the immutable tag.
#
# CONSTRAINTS this image must satisfy:
#   * CNPG operand contract: keep the base operand's entrypoint/UID/layout — only
#     add the extension's .so + control/SQL files. Do NOT override CMD or add a
#     `shared_preload_libraries` (pgvector needs none, unlike the dead pgvecto-rs
#     image in this same dir).
#   * pgvector >= 0.7.0 is REQUIRED (halfvec type + HNSW on halfvec). Debian
#     trixie/bookworm `postgresql-16-pgvector` ships >= 0.7.0; the build VERIFIES
#     it below and fails loudly otherwise so a too-old package can never ship.

FROM ghcr.io/cloudnative-pg/postgis:16

# Root only for the package install; the base image restores the postgres UID via
# its own entrypoint. APT lists are removed to keep the layer slim.
USER root

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-16-pgvector; \
    rm -rf /var/lib/apt/lists/*; \
    # Fail the build if the packaged pgvector is older than 0.7.0 (halfvec+HNSW).
    ctrl="$(find /usr/share/postgresql -name 'vector.control' | head -n1)"; \
    test -n "$ctrl"; \
    ver="$(sed -n "s/^default_version[[:space:]]*=[[:space:]]*'\\([0-9.]*\\)'.*/\\1/p" "$ctrl")"; \
    echo "packaged pgvector default_version=$ver"; \
    major="${ver%%.*}"; rest="${ver#*.}"; minor="${rest%%.*}"; \
    if [ "$major" -lt 1 ] && { [ "$major" -ne 0 ] || [ "$minor" -lt 7 ]; }; then \
      echo "ERROR: pgvector $ver < 0.7.0 — halfvec/HNSW unsupported; aborting build" >&2; \
      exit 1; \
    fi

# Restore the non-root operand UID the base image runs as (postgres = 26 on the
# CNPG operand images). The base entrypoint/CMD are inherited unchanged.
USER 26
