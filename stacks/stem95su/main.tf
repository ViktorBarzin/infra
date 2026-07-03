# stem95su moved OFF-INFRA to Cloudflare Pages (ADR-0018 cutover, 2026-07-03) —
# registry entry `stem95su` in stacks/valia-sites; runbook
# docs/runbooks/valia-sites.md. This stack intentionally declares NOTHING:
# the apply that landed this file destroyed the old in-cluster serving
# (nginx + NFS content PVC + ingress + per-site gdrive-sync CronJob +
# namespace). Directory kept only so the destroy could run through CI —
# safe to delete the dir + its PG state schema in a later cleanup.
# Harmless leftovers (manual cleanup if ever wanted): /srv/nfs/stem-site on
# the PVE host, and Vault secret/stem95su (superseded by secret/valia-sites).
