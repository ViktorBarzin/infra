#!/usr/bin/env bash
# One-shot migration of orphan images that have no CI pipeline producing them.
#
# Some images on registry.viktorbarzin.me:5050 were built ad-hoc and there's
# no Dockerfile or pipeline to reproduce them — fire-planner (until this
# session added one), wealthfolio-sync. This script pulls each orphan from
# registry.viktorbarzin.me, retags for Forgejo, and pushes — preserving the
# blob bytes verbatim so the cluster can flip image= without a rebuild.
#
# Run from any host with docker + network reach to BOTH registries. Auth
# from `docker login` (~/.docker/config.json) — make sure both registries
# are logged in:
#   docker login registry.viktorbarzin.me -u viktorbarzin
#   docker login forgejo.viktorbarzin.me -u ci-pusher
#
# After the script, the new image lives at
#   forgejo.viktorbarzin.me/viktor/<name>:<tag>
# Phase 3 of the consolidation flips infra/stacks/<svc>/main.tf image=
# to that path.

set -euo pipefail

OLD_REG=registry.viktorbarzin.me
NEW_REG=forgejo.viktorbarzin.me/viktor

# Image list: <name>:<tag>. Add new entries as orphans surface.
IMAGES=(
  "wealthfolio-sync:latest"
  "fire-planner:latest"
  "chrome-service-novnc:v4"
)

for img in "${IMAGES[@]}"; do
  echo "=== $img ==="
  src="$OLD_REG/$img"
  dst="$NEW_REG/$img"

  echo "  pull $src"
  docker pull "$src"

  echo "  tag → $dst"
  docker tag "$src" "$dst"

  echo "  push $dst"
  docker push "$dst"

  echo "  cleanup local copy"
  docker rmi "$src" "$dst" || true
done

echo ""
echo "Done. Verify in Forgejo Web UI: https://forgejo.viktorbarzin.me/viktor/-/packages?type=container"
echo "Phase 3 of the plan flips infra/stacks/{wealthfolio,fire-planner}/main.tf image= references."
