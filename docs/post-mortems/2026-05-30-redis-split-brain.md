# Post-mortem: Redis split-brain wedged BullMQ/Celery queues (2026-05-30)

**Severity:** SEV2 (degraded — no data loss in Redis; queue processing stalled
cluster-wide). **Status:** Resolved.

## Summary

The 3-node Sentinel HA Redis (`redis-v2`) split-brained: two pods both held
`role:master`. HAProxy — which routes to any backend reporting `role:master` —
round-robined client connections across **both** masters. Immich enqueued
BullMQ jobs on one master while its workers blocked-popped on the other, so
every queue stalled. User-visible symptom: **newly uploaded Immich photos
returned HTTP 404 for their thumbnails** (the generation job never ran). Celery
apps (real-estate-crawler, trading-bot, paperless) and other queue users were
affected the same way.

## Impact

- Immich: thumbnail/preview/face/ML jobs not processing. `facialRecognition`
  backlog reached ~30k waiting; new uploads showed broken images in the web UI.
- All ~15 shared-Redis consumers had inconsistent reads/writes (connections
  split across two diverging masters).
- No Redis data lost — the larger dataset (`redis-v2-0`, ~30k keys) was
  preserved through the fix.

## Timeline (UTC+1 local)

- **~2026-05-26/27**: `redis-v2` pods recreated (node2 unclean reboot era).
  `redis-v2-0` came up partitioned; its Sentinel saw 0 peers and it declared
  itself master via the init script's deterministic "pod-0 = bootstrap master"
  fallback. Sentinels on `-1`/`-2` independently elected `redis-v2-2`.
  Split-brain formed and persisted (~3-4 days) as the network healed but the
  topology never reconciled.
- **2026-05-30 ~16:58**: investigating "Immich images with no thumbnails."
  Found thumbnail jobs failing on missing/zeroed originals (separate pre-existing
  data-loss issue) AND a stuck job queue.
- **2026-05-30 ~17:00**: user manually restarted immich-server; namespace
  `tier-quota` (24Gi) briefly blocked the replacement pod → ~1 min Immich
  outage. Recovered. (Red herring — not the root cause.)
- **2026-05-30 ~17:1x**: identified two `role:master` redis pods
  (`redis-v2-0` dbsize 30320, isolated, 0 connected slaves; `redis-v2-2` dbsize
  442, quorum master). HAProxy fan-out across both = wedged queues. Ruled out
  IPv6 (cluster is single-stack IPv4) and eviction (`evicted_keys=0`).
- **2026-05-30 ~17:30**: reverted `redis-v2` to a single standalone instance.
  Queues drained immediately; newest Immich assets served HTTP 200.

## Root cause

`redis-v2`'s init container (`generate-sentinel-conf`) falls through to
"Priority 3: pod-0 is always the bootstrap master" when it cannot reach peer
Sentinels/Redis. During a network partition, `redis-v2-0` hit that fallback and
became a second master. HAProxy's health check (`tcp-check expect rstring
role:master`) matches **any** master, so with two masters it placed both in
rotation and round-robined writes/reads across diverging datasets. BullMQ's
enqueue (LPUSH) and worker consume (BRPOPLPUSH) landed on different instances →
jobs never consumed.

This is the **third** Sentinel-class incident (after 2026-04-19 PM quorum drift
and 2026-04-22 flap cascade). The 3-sentinel design was built to *prevent*
split-brain, but the bootstrap fallback re-introduced it.

## Resolution

Reverted `redis-v2` to a **single standalone instance** (`replicas=1`, Sentinel
+ HAProxy removed), collapsing onto `redis-v2-0`'s dataset (preserved Immich's
queued jobs). Eviction policy changed `allkeys-lru` → **`volatile-lru`** so the
shared cache+queue workload is served correctly by one instance (evict only
TTL'd cache keys; never TTL-less queue keys). `redis-master` service name/DNS
unchanged → no consumer edits. Decision rationale: a homelab cache/broker does
not need HA; a few-seconds restart blip beats chasing Sentinel correctness.
Mirrors the 2026-04-16 MySQL InnoDB-Cluster → standalone reversion.

## Follow-ups

- [ ] Re-upload the ~99 Immich images + 12 timeline videos whose **originals**
      are missing/zero-filled on disk (pre-existing data loss, unrelated to the
      split-brain — re-running jobs can't regenerate them). Owner: Viktor.
- [ ] `requirepass` auth on Redis + creds rollout to all consumers (carried over
      from the 2026-04-19 rework; still open).
- [ ] Consider whether any queue user (Immich/Celery) warrants its own dedicated
      Redis if the shared instance's memory ever becomes contended (currently
      ~30MB / 640MB — not a concern).

## Lessons

- HA that re-introduces its own failure class is worse than no HA. For a
  single-node-tolerant homelab, prefer a standalone instance + a small accepted
  downtime window.
- `allkeys-lru` on a shared cache+queue Redis silently drops queue jobs under
  pressure; `volatile-lru` is the correct single-instance policy (Immich even
  logs `IMPORTANT! Eviction policy ... should be "noeviction"`).
- A "bootstrap master" fallback that fires under partition is a split-brain
  generator — avoid deterministic self-promotion when peers are unreachable.
