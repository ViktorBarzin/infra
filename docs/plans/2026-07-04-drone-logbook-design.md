# Drone Logbook (Open DroneLog) — Design

**Date:** 2026-07-04
**Status:** Approved (Viktor, 2026-07-04)
**Owner request:** "I have a DJI Mini 4 Pro. I'm interested in github.com/ViktorBarzin/drone-logbook" → self-host it in the cluster.

## Goal

Self-host [Open DroneLog](https://github.com/arpanghosh8453/open-dronelog) (upstream of the
`ViktorBarzin/drone-logbook` fork) at **https://dronelog.viktorbarzin.me** so Viktor can import
DJI Fly flight logs from his DJI Mini 4 Pro and analyze them privately: telemetry charts, 3D map
replay, per-flight and lifetime stats. All data stays in the cluster (single DuckDB database).

## Decisions (interview, 2026-07-04)

| Question | Decision |
|---|---|
| Deployment form | Self-hosted Docker web app in k8s (not desktop app, not hosted webapp) |
| Exposure | Public `dronelog.viktorbarzin.me`, **Authentik forward-auth** (`auth = "required"`) |
| Log ingestion | **Both** manual web upload *and* a server-side auto-import drop folder from day one |
| Image source | **Upstream** `ghcr.io/arpanghosh8453/open-dronelog:latest` — NOT the fork |
| Fork disposition | Fork is 0 ahead / 372 behind, adds nothing; delete or park it. Only revive (sync + ADR-0002 GHA build) if Viktor starts modifying the code |

## Architecture

New Tier-1 stack `stacks/drone-logbook/`, modeled line-by-line on `stacks/freshrss/`
(the closest existing shape: single upstream-image app, own data volume, Keel-updated):

- **Namespace** `drone-logbook`, tier `4-aux`, label `keel.sh/enrolled=true` → Kyverno injects
  Keel poll annotations → auto-upgrades as upstream releases (project is actively maintained).
- **Deployment** (1 replica, `Recreate` — DuckDB is single-writer/embedded):
  - image `ghcr.io/arpanghosh8453/open-dronelog:latest` (nginx frontend + Axum REST backend, port 80)
  - memory request=limit **512Mi** (DuckDB import/analytics spikes), cpu request 25m, no cpu limit
  - standard `KYVERNO_LIFECYCLE_V1` / `KEEL_IGNORE_IMAGE` / `KEEL_LIFECYCLE_V1` lifecycle ignores
- **App data** `/data/drone-logbook` (DuckDB db, cached DJI decryption keys, uploaded originals):
  **`proxmox-lvm-encrypted` block PVC** `drone-logbook-data-encrypted`, 2Gi, topolvm autoresize →
  10Gi ceiling. Encrypted class because flight logs are GPS traces of home/travel — sensitive data
  defaults to `proxmox-lvm-encrypted` per the storage decision rule (`.claude/CLAUDE.md`).
  Embedded DBs stay off NFS (same rationale documented in the freshrss stack: NFS only for static files).
- **Backup CronJob** `drone-logbook-backup` (mandatory for every proxmox-lvm app): daily 01:30
  file copy of the data volume → NFS `/srv/nfs/drone-logbook-backup` (dated dirs, 30-day retention,
  Pushgateway metrics), pod-affinity co-scheduled with the app pod (RWO volume). 01:30 sits outside
  the 00:00/08:00/16:00 sync-import windows so the DuckDB file is quiescent; retained upload
  originals make even a torn copy recoverable by re-import. `nfs-mirror` (02:00) ships it to sda →
  Synology offsite. Vaultwarden pattern.
- **Sync drop folder**: static NFS volume (`modules/kubernetes/nfs_volume`)
  `192.168.1.127:/srv/nfs/drone-logbook/sync-logs`, mounted **read-only** at `/sync-logs`;
  `SYNC_LOGS_PATH=/sync-logs`, `SYNC_INTERVAL="0 0 */8 * * *"` (every 8 h).
  Any producer (Nextcloud sync, scp, a future phone pipeline) drops `.txt` logs there; the app
  imports them automatically. `KEEP_UPLOADED_FILES=true` keeps re-importable originals in the PVC.
- **Ingress** via `ingress_factory`: `name = "dronelog"`, `auth = "required"` (Authentik
  forward-auth), `dns_type = "proxied"`. External Uptime Kuma HTTPS monitor comes automatically
  with the ingress annotation. Homepage tile (group "Media & Entertainment", icon `mdi-quadcopter`).
- **Secrets**: Vault KV `secret/drone-logbook` (`profile_creation_pass`) → ExternalSecret
  (`vault-kv` ClusterSecretStore) → k8s secret `drone-logbook-secrets` → env
  `PROFILE_CREATION_PASS`. Gates profile create/delete even for other Authentik-logged-in users.
  No plan-time secret reads needed (no `data "kubernetes_secret"`).
  No `DJI_API_KEY` — bundled default is fine at personal import volume; add later if rate-limited.

## Operational notes

- **DJI egress dependency**: importing a *new* log file requires the pod to reach DJI's servers
  once (flight-log decryption key fetch; keys are then cached in the data dir). Remember this when
  egress enforcement lands (Security wave 1, beads `code-8ywc`).
- The web UI is desktop-first; mobile is functional but basic.
- NFS host prerequisite: `/srv/nfs/drone-logbook/sync-logs` (root:www-data, 2775 — same shape as
  sibling dirs) and `/srv/nfs/drone-logbook-backup` created on 192.168.1.127 and recorded in
  `secrets/nfs_directories.txt`. `/srv/nfs` is exported whole-tree, so no `/etc/exports`
  (`scripts/pve-nfs-exports`) change.
- Backup story = the daily app-level backup CronJob (above) + the host `daily-backup` LVM-snapshot
  leg + original log files retained both in the drop folder and in the data volume
  (`KEEP_UPLOADED_FILES=true`).

## Alternatives considered

- **Build from the fork** (`ghcr.io/viktorbarzin/...` via GHA, ADR-0002): rejected for now — fork
  has zero custom commits; a build chain adds maintenance for no benefit. Revisit if code changes
  are wanted.
- **`auth = "app"` + app profile passwords** (would enable the `opendronelog-sync` native uploader
  from anywhere): rejected — a single app password guarding GPS traces of home/travel on the open
  internet is weaker than Authentik; the sync drop folder covers automated ingestion instead.
- **Internal-only (.lan + VPN)**: rejected — Authentik-gated public matches the rest of the
  homelab and works without VPN while traveling.
- **NFS for the DuckDB data**: rejected — embedded-DB-on-NFS locking risk; freshrss precedent
  keeps app DB data on proxmox-lvm.

## Implementation

See `2026-07-04-drone-logbook-plan.md`.
