# Runbook: Synology NAS storage — navigate, assess, clean

**Target:** Synology DS218 (`NAS_Barzini`), `192.168.1.13`, `/volume1`
(5.3 TiB btrfs). This is the **offsite backup target** (Copy 3 of the
3-2-1 strategy) **and a shared family volume** — homelab data is only
under `Backup/Viki/`; `Anca/`, `Emo/`, `Common/`, `music`, `video`,
`photo` etc. are family data.

Related: [storage architecture](../architecture/storage.md) ·
[backup & DR](../architecture/backup-dr.md)

## Access

- SSH: `ssh Administrator@192.168.1.13` (capital `A`; key-auth works
  from devvm and the PVE host). `Administrator` can `sudo`.
- sudo password: Vault `secret/viktor` → `synology_admin_password`
  (`VAULT_ADDR=https://vault.viktorbarzin.me`). DSM Web API has 2FA, so
  **SSH+sudo is the only unattended path** (`read -r PW; printf '%s\n'
  "$PW" | sudo -S -p '' <cmd>` to keep the secret out of `argv`).

## ⚠️ NEVER run `du` / `find` / `ncdu` on this NAS

Recursive walks over the multi-TB `Backup` share take 10+ min (often
never finish) and burn disk/IO on the NAS. Use Synology's own
pre-indexed data instead:

| Need | Instant, non-walking source |
|---|---|
| Volume fill | `df -h /volume1` |
| btrfs real usage | `btrfs filesystem df /volume1` |
| Per-subvolume | `sudo btrfs qgroup show -prce --raw /volume1` |
| **Per-share / per-owner / per-type / largest / oldest / dupes** | **Storage Analyzer weekly report** (below) |

### Storage Analyzer weekly report

Storage Analyzer is installed and writes a report every **Monday
~00:00** to:

```
/volume1/Backup/Viki/synoreport/weekly storage report/<YYYY-MM-DD_..>/
```

Data is up to ~7 days stale. The useful files are zipped CSVs in
`csv/` — **content is UTF-16, and there is no `unzip` on the box**, so
read them with Python:

```python
import zipfile, os
R=".../<date>/csv"
def readcsv(n):
    z=zipfile.ZipFile(os.path.join(R,n)); raw=z.read(z.namelist()[0])
    for enc in ("utf-16","utf-8-sig","utf-8"):
        try: return raw.decode(enc)
        except Exception: pass
```

Key CSVs: `volume_usage`, `share_list` (per-share, incl/excl recycle),
`quota_usage.share` (**per-owner within a share**), `file_group`
(per-file-type), `large_file`, `least_modify` (oldest), `duplicate_file`.
The `*.db` files (`folder.db` etc.) are a **custom Synology format —
NOT sqlite**; `report.html` does not embed clean folder totals.

## btrfs space-reclaim is ASYNCHRONOUS — and snapshot-pinned

- Deleting files/snapshots returns instantly but `df` lags minutes
  while the btrfs cleaner reclaims extents (~30 GB/min on the DS218).
- Data deleted from the live share **stays on disk until the share
  snapshots that still reference it also rotate out.** The `Backup`
  share retains 7 days (`GMT-*-21.00.02`, +1 for the same-tick daily),
  so **expect up to ~7-8 days of lag** before a delete fully frees space.
- **Ordering matters: delete SNAPSHOTS FIRST, then purge data.** Deleting
  snapshot-pinned data frees nothing, and if a later sync rewrites that
  data it allocates NEW extents while the snapshots still hold the old —
  so purging before clearing snapshots makes usage go *up*.
- Snapshot CLI (sudo, full path): `/usr/syno/sbin/synosharesnapshot
  {list|delete} Backup <snap>...`.
- **Retention lives in `/usr/syno/etc/synoretention/Share#/<share>/policy`**,
  read/written via `/usr/syno/bin/synoretentionconf --get|--set-policy`.
  The `snap_auto_remove_*` keys in `/usr/syno/etc/sharesnap/sharesnap.conf`
  look like the knob but are **INERT** — a 2026-05-24 "7d → 3d" change set
  there silently did nothing for ~10 weeks and caused a repeat 99%-full
  incident on 2026-08-06. Always verify with `synoretentionconf --get`.
- Credential: **Vaultwarden**, not HashiCorp Vault —
  `homelab vault get e993c4e1-6e22-4fe8-a52d-2a5214d9d0c0 --field password`
  (item `nas.viktorbarzin.me`, `username=Administrator`; a second item of the
  same name is Anca's). Pass it on ssh **stdin**:
  `printf '%s\n' "$PW" | ssh Administrator@192.168.1.13 'sudo -S -p "" <cmd>'` —
  `ssh host "echo '$PW' | sudo -S ..."` fails and leaks into remote argv.
- Sizing: use `df` / `btrfs qgroup show`. A `du` over `/volume1` does **not**
  finish on this DS218 (killed at 900 s and 2400 s, 2026-08-06).

## Capacity alert

> **⚠️ The alert described here NEVER WORKED. Corrected 2026-08-06.**
> This section used to claim the Synology surfaced to Prometheus as a PVE host
> NFS mount `/mnt/synology-backup` (`job="proxmox-host"`, `fstype=nfs4`), caught by
> the global `NodeFilesystemFull` rule. **That mount does not exist** — the
> directory is there but nothing is mounted on it (the offsite script mounts
> on demand), and the PVE `node_exporter` exports **no nfs4 filesystem at all**.
> `NodeFilesystemFull` could never match, so the offsite destination was
> effectively unmonitored. It reached 99% / 103 GiB free on 2026-08-06 —
> roughly one day from stopping Copy 3 — and surfaced only by accident, because
> an unrelated `navidrome-music` PVC happens to live on the same `/volume1` and
> is scraped via `kubelet_volume_stats`.

**Real signal (2026-08-06):** `offsite-sync-backup` SSHes to the Synology every
run anyway, so it now reads `df -kP /volume1` and pushes
`offsite_dest_available_bytes` + `offsite_dest_size_bytes` to Pushgateway job
`offsite-backup-sync`, alongside the existing freshness metric. Best-effort — a
df failure warns but never fails the backup.

Alerts (in `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl`,
3-2-1 group):

| Alert | Fires | Notice at ~100 GiB/day |
|---|---|---|
| `OffsiteDestinationFillingUp` (warning) | <6% free, 30m | ~3 days |
| `OffsiteDestinationAlmostFull` (critical) | <4% free, 15m | ~2 days |
| `OffsiteDestinationCapacityUnknown` (warning) | metric absent 48h | dead-man |

Thresholds are deliberately loose — a backup target legitimately runs hot (same
reasoning that moved `NodeFilesystemFull` 90% → 95% on 2026-06-05).

**Revisited 2026-09-04**, as that note asked. The warning moved
**10% → 6% free**; the 4% critical is unchanged. 10% was a placeholder chosen
before any post-fix steady state existed, and it falls inside this disk's normal
operating band — 95% used is where `/volume1` lives and needs no action (see
`a7fd8211`), so a warning at 10% free reports the baseline rather than a
problem. 6% sits below the band and still fires ahead of the critical.

Range actually observed since the gauge started on 2026-08-06: **20.5% free at
the high, 4.8% at the low** (the low is 2026-09-04, during an active fill that
took it from 11.1% on 08-31 to 4.8% in four days). Nothing in that history
crossed 10% until 2026-09-02.

`BackupDiskFull` (the sda `/mnt/backup` disk) is a separate alert, still 85%.

## Current assessment — 2026-06-05

`/volume1` at **94% (5.0 TiB used / 5.3 TiB, 324 GiB free)**, down from
98% on 2026-05-24. The **`Backup` share is 4.42 TiB (86%)**:
Administrator/homelab **3.92 TiB**, Emo/family **504 GiB**. By type:
Other 1.76 TiB, Videos 1.33 TiB, Pictures 631 GiB, Zipped 495 GiB,
DiskImage 77 GiB. The ~1.9 TiB of media is mostly the **Immich offsite
backup** (`Viki/nfs/immich` + `nfs-ssd/immich`), which **grows daily —
the structural capacity driver now that one-off cleanups are spent.**

### Already reclaimed (verified gone)

`Anca/Elements` (770 GiB — dir now empty), `prometheus-backup` (63 GiB),
`ollama`/`llamacpp`/`audiblez`/`ebook2audiobook` — removed in the
2026-06-01 cleanup; nfs-mirror now excludes the regenerable services.

### Cleanup candidates — homelab (`Backup/Viki/`, Administrator-owned)

| Target | Size | Notes |
|---|---|---|
| `Photos/gphotos-1/` | **208 GiB** zips (+ extracted) | 2023 Google Takeout, **already imported to Immich** (`immich-go.exe` beside them; dupes confirmed). Redundant. |
| `laptop/` | ~167 GiB | old VM images (Kali/windows vdis, metasploitable, soton-rpi.img) |
| `All-in-one/` | ~95 GiB | 2015–2018 archives |
| `#recycle/` (Backup) | ~16 GiB | recycle bin (HA backup rotation) |
| loose `*.asc`/`*.mov` in `Viki/` root | ~8 GiB | old encrypted archives, phone videos |
| `sgs7/` | ~3.5 GiB | 2021 Galaxy S7 backup |

**~500 GiB** reclaimable without touching live backups or family data.

### Cleanup candidates — family (flag to Emo, do not delete)

- `Emo/D/` Windows 7 vmdks — **3 identical 39.5 GiB copies** (one live +
  two under `_SYNCAPP/Versioning/`) → 79 GiB dedup.
- Emo-shared recycle bin: 12.6 GiB.

### Do NOT touch

`Viki/pve-backup/` (live structured backup), `Viki/nfs/immich` +
`nfs-ssd/immich` (irreplaceable), `HomeAssistant/` + `ha_backup_vermont/`
(~7 GiB, healthy 3-copy retention).
