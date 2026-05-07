#!/usr/bin/env bash
# One-shot migration of every private image on registry.viktorbarzin.me to
# Forgejo. Used as a stop-gap when the dual-push CI pipelines aren't
# producing Forgejo images on their own (Forgejo-Woodpecker forge driver
# context-deadline-exceeded issue, see bd code-d3y / 2026-05-07).
#
# Pulls each image from registry.viktorbarzin.me, retags, pushes to
# forgejo.viktorbarzin.me/viktor/<name>:<tag> — preserving the blob bytes
# verbatim so the cluster can flip image= without a rebuild.
#
# Run from any host with docker + network reach to BOTH registries. Auth
# from `docker login` (~/.docker/config.json) — make sure both registries
# are logged in:
#   docker login registry.viktorbarzin.me -u viktorbarzin
#   docker login forgejo.viktorbarzin.me -u viktor   # use viktor PAT, not ci-pusher
#
# (ci-pusher CANNOT push to viktor/<image> — Forgejo container packages
# are scoped to the pushing user. Only viktor's PAT can write to viktor/*.)
#
# After the script, the new image lives at
#   forgejo.viktorbarzin.me/viktor/<name>:<tag>
# Phase 3 of the consolidation flips infra/stacks/<svc>/main.tf image=
# to that path.

set -euo pipefail

OLD_REG=registry.viktorbarzin.me
NEW_REG=forgejo.viktorbarzin.me/viktor

# Image list: <name>:<tag>. Generated 2026-05-07 from `grep -rEn 'image\s*=\s*
# "registry\.viktorbarzin\.me'` across infra/stacks/.
#
# Excluded:
# - wealthfolio-sync: registry repo exists but has 0 tags (CronJob has been
#   broken for 36+ days, separate decision needed). User to triage before
#   migration.
# - fire-planner: registry repo exists but has 0 tags. Dockerfile + CI added
#   in this session (commit 8b53d99e); rebuild via Woodpecker before flipping.
IMAGES=(
  "chrome-service-novnc:v4"
  "chrome-service-novnc:latest"
  "payslip-ingest:latest"
  "job-hunter:latest"
  "claude-agent-service:latest"
  "freedify:latest"
  "beadboard:latest"
  "infra-ci:latest"
)

for img in "${IMAGES[@]}"; do
  echo "=== $img ==="
  src="$OLD_REG/$img"
  dst="$NEW_REG/$img"

  if ! docker pull "$src" 2>&1 | tee /tmp/pull-$$ | grep -q 'Status: '; then
    if grep -q 'not found' /tmp/pull-$$; then
      echo "  SKIP — image not present in source registry"
      rm -f /tmp/pull-$$
      continue
    fi
  fi
  rm -f /tmp/pull-$$

  echo "  tag → $dst"
  docker tag "$src" "$dst"

  echo "  push $dst"
  docker push "$dst" 2>&1 | tail -2

  echo "  cleanup local copy"
  docker rmi "$src" "$dst" 2>&1 | tail -1 || true
done

echo ""
echo "Done. Verify in Forgejo Web UI: https://forgejo.viktorbarzin.me/viktor/-/packages?type=container"
echo "Phase 3 of the plan flips infra/stacks/{wealthfolio,fire-planner}/main.tf image= references."
