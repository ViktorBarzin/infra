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
  snapshots that still reference it also rotate out.** There are 4
  daily `Backup` share snapshots (`GMT-*-21.00.02`), so **expect up to
  ~4 days of lag** before a delete fully frees space.
- Snapshot CLI (sudo, full path): `/usr/syno/sbin/synosharesnapshot
  {list|delete} Backup <snap>...`. Retention:
  `/usr/syno/etc/sharesnap/sharesnap.conf`.

## Capacity alert

The Synology mount surfaces to Prometheus as the PVE host NFS mount
`/mnt/synology-backup` (`job="proxmox-host"`, `fstype=nfs4`), caught by
the **global `NodeFilesystemFull`** rule in
`stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl`.

- **2026-06-05:** threshold changed **90% → 95%** (`* 100 < 5`) at
  user request — a backup target legitimately runs hot, so 90% was
  noisy. NOTE: this rule is **global**, so the looser 95% now applies to
  all node/system disks too. `BackupDiskFull` (the sda `/mnt/backup`
  disk, separate alert) stays at 85%.

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
