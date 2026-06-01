# Runbook: Immich 4K video stutters on playback/download

## Symptom
High-resolution (4K) videos stutter when streamed in the Immich mobile app or
downloaded — for **both** local-LAN and remote-internet clients.

## Root cause (diagnosed 2026-06-01)
Immich's transcoding was set to `ffmpeg.targetResolution=original` with
`maxBitrate=0` (no cap) and `preset=ultrafast`. The GPU (NVENC) faithfully
re-encoded 4K sources to **4K H.264**, and `ultrafast` is so inefficient it
produced **77–264 Mbps** "optimized" files — often larger than the originals.

The mobile app streams that `encoded-video` copy. A 100 Mbps stream needs
~12.5 MB/s sustained. All Immich video lives on `/srv/nfs/immich/{library,encoded-video}`
→ `pve-nfs-data` LV → the **shared 7200rpm `sdc` thin pool** (same pool as every
VM disk + etcd), reached over inter-VLAN NFS. Measured: a single cold read got
42–54 MB/s, but under 3 concurrent reads it collapsed to 17–24 MB/s each — and
real seeky multi-user playback drops below the needed bitrate → buffer underrun.
Remotely, 100 Mbps simply exceeds typical home **upload** bandwidth.

So the "transcode" was making streaming *worse*, not better.

## Fix
Transcode config is **DB-managed** (`system_metadata` key `system-config`, JSONB —
NOT Terraform). Apply via the system-config API (broadcasts a live reload — no pod
restart). Keep 4K, cap the bitrate, use an efficient preset:

```
ffmpeg.maxBitrate  : "0"        -> "20000k"   # ~20 Mbps cap (2.5 MB/s)
ffmpeg.preset      : "ultrafast"-> "medium"   # ~2-3x more efficient
ffmpeg.transcode   : "required" -> "bitrate"  # transcode anything >maxBitrate or non-h264
ffmpeg.targetResolution        : "original"   # unchanged — 4K preserved
ffmpeg.accel=nvenc, accelDecode=true          # unchanged
```

GET the full config, change only these keys, PUT it back (preserves SMTP/OAuth
secrets). Admin API key works; `me@viktorbarzin.me`'s homepage-widget token in
`immich-secrets.homepage_credentials.immich.token` has admin write.

**Originals are never touched** — only the `encoded-video/` streaming copy changes.

## Apply the new policy to EXISTING videos
Config changes only affect new/missing transcodes. `videoConversion force=false`
("Missing") only fills assets lacking a transcode row; it does NOT re-touch existing
oversized ones. `force=true` ("All") re-does all ~11k (wasteful). To regenerate only
the **non-conforming** subset:

1. Identify offenders: existing `encoded_video` files whose bitrate > 20 Mbps.
   Bitrate = filesize×8 ÷ `asset.duration` (codec/bitrate are NOT in the DB; size is
   on disk, filename = `<assetId>.mp4`). ~3296 offenders / 268 GB on 2026-06-01.
2. Delete their derived rows (regenerable; never originals):
   `DELETE FROM asset_file WHERE type='encoded_video' AND "assetId" = ANY(:offenders);`
   This makes them "missing." The deterministic `<assetId>.mp4` path is overwritten on
   regen (reclaims space).
3. Trigger `PUT /api/jobs/videoConversion {"command":"start","force":false}`.
4. Per-asset API (`POST /api/assets/jobs`) is owner-scoped (admin can't drive other
   users' assets) — hence the delete-then-missing approach via the admin global job.

## Verify
- New output bitrate: `ffprobe -show_entries format=bit_rate` on a freshly-written
  `encoded-video/*.mp4` → should be ≤ ~20 Mbps (was 77–264).
- Progress: `SELECT count(*) FROM asset_file WHERE type='encoded_video';` rises as
  regeneration proceeds.

## Monitor while it runs (concurrency 1, can take 1–3 days)
- `videoConversion` runs at concurrency **1** (Immich default; gentle — do NOT raise,
  protects sdc). Thumbnail/metadata/library are capped to 2 for the same reason.
- Watch sdc (`iostat -x` on 192.168.1.127) and apiserver latency
  (`kubectl get --raw=/healthz`). The risk is sdc saturation → etcd starvation →
  apiserver down (precedent: `post-mortems/2026-05-25-immich-anca-elements-io-storm.md`).
  Healthy baseline during this job: sdc ~70% util, apiserver <100 ms.
- Pause if it suffers: `PUT /api/jobs/videoConversion {"command":"pause"}`; resume with
  `{"command":"resume"}`.

## Real fix for the root contention
This is mitigation. The durable fix is moving Immich video storage (or the VM disks)
off the shared `sdc` 7200rpm pool — tracked in beads `code-oflt` (IO isolation).
