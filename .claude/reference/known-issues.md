# Known Issues (suppress in all agents)

## Permanent
- ha-london Uptime Kuma monitor down — external HA on Raspberry Pi, not in this cluster
- PVFillingUp for navidrome-music — Synology NAS volume, threshold is 95%, expected

## Intermittent
- CrowdSec Helm release stuck in pending-upgrade — known issue, workaround: helm rollback
- Resource usage >80% on nodes — WARN only, overcommit is by design (2x LimitRange ratio)

## How agents consume this file
Each agent definition includes: "Before reporting issues, read `.claude/reference/known-issues.md` and suppress any matches."
