# ImmichSmartSearchSlow fires on probe wall clock, not on search latency

- Date: 2026-09-03
- Bead: code-9hb8
- Status: cause identified, fix proposed, nothing changed yet

## Summary

`immich_smart_search_db_seconds` is the wall-clock time of a `psql` process
running inside a per-run CronJob pod. The ANN query it names is roughly
0.1-0.6 s of that. Measured server-side over 102 samples spanning 30 minutes,
the query never took more than 0.60 s, while the probe reported values up to
15.5 s in the same 24 hours.

So `ImmichSmartSearchSlow` and cluster-health check 46 are mostly reacting to
something outside the query. The three DB-side hypotheses in the bead - index
bloat, a REINDEX being due, a VACUUM being due - are each ruled out below with
numbers. One database effect is real but minor: when `clip_index` falls out of
`shared_buffers` the query does slow down, and that accounts for 20 of the 202
runs over 1.5 s in the last week.

## What was measured

The probe query, run inside `immich-postgresql` with `EXPLAIN (ANALYZE, BUFFERS)`:

| sample set | n | min | p50 | p90 | p95 | max |
|---|---|---|---|---|---|---|
| 60 back-to-back runs | 60 | 85 ms | 116 ms | 174 ms | 232 ms | 573 ms |
| 1 run per 10 s over 25 min | 42 | 92 ms | 142 ms | 321 ms | 329 ms | 600 ms |

The probe's own reported number over the same 24 hours, read from its pod logs:

| day | runs | p50 | p90 | p95 | max | over 1.5 s |
|---|---|---|---|---|---|---|
| 2026-08-27 | 133 | 0.47 | 1.43 | 2.01 | 11.01 | 9.8% |
| 2026-08-28 | 288 | 0.19 | 0.60 | 1.14 | 8.73 | 3.1% |
| 2026-08-29 | 288 | 0.19 | 0.62 | 1.64 | 19.52 | 5.6% |
| 2026-08-30 | 288 | 0.21 | 0.46 | 1.15 | 14.65 | 3.5% |
| 2026-08-31 | 289 | 0.49 | 4.02 | 6.84 | 13.92 | 27.0% |
| 2026-09-01 | 290 | 0.21 | 0.81 | 1.27 | 10.17 | 3.4% |
| 2026-09-02 | 276 | 0.57 | 3.58 | 6.00 | 34.04 | 19.6% |
| 2026-09-03 (to 12:35) | 156 | 0.28 | 1.02 | 2.62 | 11.87 | 7.7% |

Two things follow. The tail is older than the alert: 08-29 and 08-30 both
carried maxima above 14 s on days when nothing fired. And the alert-day
signature is a shifted median (0.19-0.21 becomes 0.49-0.57) plus a much fatter
p90, on 08-31 and 09-02 specifically.

The floor is informative too. The lowest probe value seen in 24 h is 0.168 s,
while the lowest server-side query time is 0.085 s. About 0.08 s of every probe
reading is `psql` startup, DNS and TCP connect before any query runs.

## What was ruled out

**Index bloat.** `clip_index` was 738 MB at 176,245 rows when the bead was
filed and is 742 MB at 177,300 rows now: 4,392 then, 4,388 bytes per row now.
Growth is proportional to rows, so a REINDEX would recover nothing.

**Index type.** The hypothesis in the bead is about HNSW. This index is not
HNSW:

```
CREATE INDEX clip_index ON public.smart_search
  USING vchordrq (embedding vector_cosine_ops)
  WITH (options='residual_quantization = false
        [build.internal]
        lists = [256]
        spherical_centroids = true ...')
```

VectorChord IVF plus RaBitQ, 256 lists, and `vchordrq.probes = 1` at runtime,
so a scan probes one list of 256. The `vectors.hnsw_ef_search = 100` setting
visible in `pg_settings` belongs to the older pgvecto.rs extension and does not
govern this index.

**Vacuum.** `smart_search` has 3,033 dead tuples against 177,300 live ones. The
autovacuum threshold for this table is around 35,510, so no vacuum is due and
none has ever run. `last_autoanalyze` is 2026-08-31 15:07.

**The prewarm tick.** Splitting the 276 runs in 24 h by whether the run also did
`pg_prewarm` (the `:00` and `:30` ticks): those runs have p50 0.536 s and mean
1.565 s, the others p50 0.442 s and mean 1.045 s. Slower, but 31 of the 42
slow runs fall on non-prewarm ticks, so the prewarm is at most a contributor.

**Node CPU and disk.** node5 hosts 260 of 289 probe pods. Its disk was at 0.0%
average and 0.4% peak on 08-31, the worst day (27.0% over threshold), and at
0.7% average with a 95.2% peak on 08-30, a good day (3.5%). CPU averaged
15-30% across the week with no step. Neither tracks the probe.

**DNS and connect, from a warm pod.** 200 consecutive `psql` connections to
`immich-postgresql.immich.svc.cluster.local` from inside the cluster took 54-107 ms
with no outlier. `options ndots:2` in the pod resolv.conf means the 4-dot FQDN
is tried absolute first, so there is no search-domain amplification.

## What correlates, and how much of the tail it accounts for

**Buffer residency, for about a tenth of the slow runs.** Each probe line
carries the `clip_index` residency it measured, so latency and residency can be
paired run by run. Over 2,008 runs from 08-27 to 09-03:

| clip_index resident | runs | p50 | p90 | max | over 1.5 s |
|---|---|---|---|---|---|
| under 50% | 10 | 1.59 | 3.04 | 3.04 | 50.0% |
| 50-90% | 59 | 0.60 | 3.26 | 6.17 | 25.4% |
| 90-99% | 27 | 0.25 | 1.01 | 1.48 | 0.0% |
| 99-100% | 1,912 | 0.24 | 1.43 | 34.04 | 9.5% |

A cold index is genuinely slower, and the effect is large where it happens. It
is also rare: 96 of 2,008 runs saw residency below 99%, and only 20 of the 202
runs over 1.5 s did. The other 182 slow runs had the index fully resident,
which is the state in which the query was measured at 0.085-0.600 s.

Daily minima do track the two bad days - residency bottomed at 2.7% on 08-31 and
11.6% on 09-02, against 100% on 08-30 - but the paired per-run data above is the
better evidence, and it says residency accounts for roughly a tenth of the
slow runs rather than most of them.

**immich-worker bursts, for part of the rest.** On 2026-09-02 at 20:00 the
probe's hourly p50 was 7.81 s and only 5 of the expected 12 runs completed,
against 14,189 worker log lines that hour. Other high-worker hours were
unaffected (09-03 06:00, 1,045 lines, p50 0.65 s).

## What is not established

Where the remaining seconds go inside the probe pod. The `measure` container's
non-`psql` time - bash startup, the prewarm, the `pg_buffercache` residency
query, the file write - ranged 0.95-20.27 s across the 8 containers cAdvisor
happened to catch, while that residency query takes 246-321 ms server-side. So
the pod environment does add seconds of variable latency around the timed
window. Whether the same variability lands inside it is a reasonable reading of
the evidence, not something this pass measured. Settling it needs timing
instrumentation inside the CronJob, which is a change to
`stacks/immich/main.tf` rather than an observation.

## Proposal

Have Postgres report its own elapsed time, so the metric matches its name. This
form was run against the live database and returns the server-side milliseconds:

```sql
SELECT round(extract(epoch from clock_timestamp() - t0) * 1000)
FROM (
  SELECT clock_timestamp() AS t0,
         (SELECT count(*) FROM (
            SELECT "assetId" FROM smart_search
            ORDER BY embedding <=> (SELECT embedding FROM smart_search ORDER BY random() LIMIT 1)
            LIMIT 100
          ) s) AS c
) q;
```

With that, the 1.5 s threshold in `cluster_healthcheck.sh` check 46 stays as it
is and is generous: measured p95 is 0.33 s and the maximum seen is 0.60 s.

If the end-to-end number is worth keeping, it deserves its own series and its
own threshold, set from its own distribution rather than from the query's. Across
the eight days in the table above its p90 ranges 0.46-4.02 s and its p95
1.14-6.84 s, with daily maxima of 8.73-34.04 s. A wall-clock threshold that
clears the worst day's p95 sits around 7 s, and even then the daily maxima
still cross it, so this series will page occasionally whatever number is
chosen. That is a reason to alert on the query time and keep the wall clock as
context, rather than to keep tuning one threshold against two different things.

## A separate observation about the prewarm

`shared_buffers` is 2,048 MB. The vector relations and their TOAST come to about
2,758 MB, so they cannot all be resident:

| relation | size | resident | pct |
|---|---|---|---|
| clip_index | 742 MB | 742 MB | 100.0 |
| smart_search TOAST (`pg_toast_17438`) | 705 MB | 585 MB | 83.0 |
| face_search TOAST (`pg_toast_17260`) | 630 MB | 329 MB | 52.2 |
| face_index | 668 MB | 31 MB | 4.6 |
| face_search | 17 MB | 17 MB | 100.0 |
| smart_search | 13 MB | 13 MB | 100.0 |

The table above is one instant. Residency moves: `clip_index` bottomed at 2.7%
on 08-31, 11.6% on 09-02 and 47.1% on 08-29, so the pool is under real pressure
on some days.

`smart_search` is `vector(768)`, so its embeddings live in the TOAST table, not
in the 13 MB main fork. The prewarm step runs `pg_prewarm('smart_search')`,
which warms the main fork only. `immich_clip_index_cached_pct` watches
`clip_index` and does catch the deep drops, which is how the correlation above
was measurable at all; nothing watches the TOAST that holds the vectors.

Prewarming the TOAST as well is possible:

```sql
SELECT pg_prewarm(reltoastrelid) FROM pg_class WHERE relname = 'smart_search';
```

That is a trade rather than a clear win: `clip_index` plus that TOAST is
1,447 MB of the 2,048 MB pool, and whatever is evicted to make room pays for it.
Worth measuring before adopting, and worth measuring only after the metric
reports query time, since today's metric could not show the difference.

## How to reproduce these numbers

Server-side timing, from inside the database pod:

```
kubectl -n immich exec immich-postgresql-<pod> -- psql -U postgres -d immich \
  -c "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT count(*) FROM (
        SELECT \"assetId\" FROM smart_search
        ORDER BY embedding <=> (SELECT embedding FROM smart_search ORDER BY random() LIMIT 1)
        LIMIT 100) s"
```

Per-run probe history, which is what the daily table above is built from:

```
homelab logs query '{namespace="immich"} |= "probe dur="' --since 24h --limit 300
```

Note that reading the same thing out of Prometheus gives different daily
percentages, because the Pushgateway gauge holds its last value between pushes
and every scrape re-counts it. The Loki lines are one per run and are the ones
to trust for run-count questions.
