# Mladost 3 router: restore and reinstall

How to bring the Mladost 3 router (`mladost3-openwrt`, TP-Link WDR4300 v1,
OpenWrt 23.05.0 r23497-6637af95aa, kernel 5.15.134) back from its backups. The
router runs from a USB stick (extroot); the settings live in
`docs/architecture/vpn.md`, Mladost 3 section.

## Backups

| Backup | Where | What |
|---|---|---|
| Weekly config | `/mnt/backup/routers/mladost3-openwrt/backup-mladost3-openwrt-<YYYYMMDD>.tar.gz` on the PVE host, 8 kept, copied to `Synology:/Backup/Viki/pve-backup/routers/` | `sysupgrade -k -b`: all settings, keys, passwords, and `etc/backup/installed_packages.txt` (since 2026-11-27). Job: `router-config-backup`, Sunday 04:30, `docs/architecture/backup-dr.md` |
| Full snapshot | `/mnt/backup/routers/mladost3-openwrt/full-20261127/` on the PVE host, same offsite copy | Everything needed to rebuild the router. `README.txt` there lists the files; `SHA256SUMS` checks them |

The full snapshot holds:

- `mladost3-stick-restore.img.gz`: a ready stick. Write it to a USB stick and the router boots from it as before.
- `overlay.tar.gz`: the files on the stick (`etc/` and `upper/`), which the image is built from.
- `mtd0-u-boot.bin`, `mtd1-firmware.bin`, `mtd5-art.bin`: raw copies of the internal flash. `art` is the Wi-Fi calibration of this unit; no download replaces it.
- `firmware-built-in/` and `firmware-with-usb/`: 23.05.0 images with all the router's packages built in, made with the OpenWrt Image Builder (`firmware-image-builder-run.sh`).
- `sysupgrade-config.tar.gz`, `opkg-list-installed.txt`, `system-info.txt`.

Get a file from the PVE host, from the home LAN or the VPN:

```sh
scp root@192.168.1.127:/mnt/backup/routers/mladost3-openwrt/full-20261127/mladost3-stick-restore.img.gz .
```

The archives hold the WireGuard private key and the root password hash. Keep
the copies private and delete them when you are done.

## The stick fails or you replace it

Use this when the router works but the stick drops out, reads errors, or is
gone. Nothing on the router changes.

1. Write `mladost3-stick-restore.img.gz` to a USB stick of 2 GB or more. Use
   balenaEtcher (macOS, Windows or Linux; it reads `.img.gz`), or on Linux
   `zcat mladost3-stick-restore.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync`.
2. Power the router off, remove the old stick, put the new stick in either
   USB port, and power the router on.
3. Wait 2 to 3 minutes. The router waits up to 30 s for the stick at boot.
4. Do the checks below.
5. If a weekly config backup is newer than 2026-11-27, restore it on top:
   `scp -O backup-mladost3-openwrt-<date>.tar.gz root@10.3.2.7:/tmp/`, then on
   the router `sysupgrade -r /tmp/backup-mladost3-openwrt-<date>.tar.gz && reboot`.

The image has one 1 GiB ext4 partition with the old stick's label `extroot` and
UUID `794b3f7c-dd28-4368-9807-55ed25237783`, so both fstabs (on the stick and
on internal flash) still match. Its `etc/.extroot-uuid` matches the installed
firmware. The router uses 27 MB of the 1 GiB. The image was checked with
`e2fsck` and its ext4 features are a subset of the live stick's; it has not
booted on the router yet.

## The router boots its old internal config

If the stick is missing or unreadable at boot, the router falls back to the
config on internal flash, from its Sofia days: LAN `192.168.2.1`, no tunnel, no
monitoring, and SSH keys and passwords that are not the current ones. The
router does not show this remotely; it is simply gone from the tunnel. Fix it
on site: power off, put in a working or restored stick (above), power on.

## Reinstall the firmware

Use this to move the router off the stick onto internal flash, or to start
clean. It has not been done on this router. Do it on site, with a cable to a
LAN port. After any sysupgrade the current stick no longer mounts as extroot
(`block: extroot: UUID mismatch`); keep it only as a copy.

1. Copy `firmware-built-in/openwrt-23.05.0-ath79-generic-tplink_tl-wdr4300-v1-squashfs-sysupgrade.bin`
   (6,619,962 bytes) to the router's `/tmp/`, and check it against `sha256sums`
   in the same folder.
2. Run `sysupgrade -v /tmp/<file>.bin`. It keeps the settings and reboots.
   The image already holds all the packages, so nothing needs installing.
3. On internal flash, about 1.2 to 1.5 MB stays free for settings. The
   settings take 40 KB.
4. If the settings did not carry over, restore the newest weekly backup with
   `sysupgrade -r` as above.

`firmware-with-usb/` is the same image with USB storage and extroot support,
6,947,642 bytes. A stock 23.05.0 image also works: restore the weekly backup,
then `opkg update` and install the packages in
`etc/backup/installed_packages.txt` from that backup.

## The router does not boot at all

The snapshot has the raw `u-boot`, `firmware` and `art` partitions to write
back. Recovery on a WDR4300 needs someone on site with the method on the
OpenWrt device page (https://openwrt.org/toh/tp-link/tl-wdr4300), for example
a serial console. Write back `art` only if it was lost; a normal flash does not
touch it.

## Checks after a restore

```sh
ssh root@10.3.2.7 'grep " /overlay " /proc/mounts; logread -e router-watchdog | tail -2'
```

- `/overlay` is on `/dev/sda1`, `ext4 rw` (after a move to internal flash it is
  `/dev/mtdblock4`, `jffs2`).
- The watchdog logs `started: /overlay on sda1 (794b3f7cdd284368980755ed25237783)`.
- Prometheus `up{job="mladost3-router"}` is 1, and Loki
  `{job="syslog", host="mladost3-openwrt"}` has new lines.

## Refresh the full snapshot

The full snapshot is a one-time copy. Take a new one after you change packages
or replace the stick, and only while the stick is healthy: on a router whose
stick dropped out, reads like these evict the cached files that keep SSH
working. From the devvm, in a new folder with `umask 077`:

```sh
r=root@10.3.2.7
for m in 0:u-boot 1:firmware 5:art; do ssh $r "cat /dev/mtd${m%%:*}ro" > mtd${m%%:*}-${m#*:}.bin; done
ssh $r 'tar -C /overlay -cf - etc upper' | gzip -9 > overlay.tar.gz
ssh $r 'sysupgrade -k -b - 2>/dev/null' > sysupgrade-config.tar.gz
ssh $r 'opkg list-installed' > opkg-list-installed.txt
```

Compare `md5sum /dev/mtdNro` on the router with the local files, and the entry
count of `tar tzf overlay.tar.gz` with `cd /overlay && find etc upper | wc -l`.
Build the stick image with `stick-image-build.sh` from the old snapshot: it
runs in `debian:trixie`, because `mke2fs -d <tarball>` needs e2fsprogs 1.47.1
or later and libarchive. Copy the folder to
`/mnt/backup/routers/mladost3-openwrt/full-<YYYYMMDD>/` (owner root, mode 600),
write `SHA256SUMS`, and append each file's path below `/mnt/backup/` to
`/mnt/backup/.changed-files` under `flock`, so offsite-sync copies it. List
only files that exist: a missing path fails the offsite run.
