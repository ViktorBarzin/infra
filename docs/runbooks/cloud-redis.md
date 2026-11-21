# cloud-redis runbook

`cloud-redis` (namespace `cloud-redis`, Service `cloud-redis.cloud-redis.svc.cluster.local:6379`, StatefulSet `cloud-redis`, stack `stacks/cloud-redis`) holds Cloud's Key Values (cloud backlog B27, option b of `decision-b27-redis.md`). It is apart from the homelab's shared Redis (`stacks/redis`, [redis-acl.md](redis-acl.md)) so that a tenant's busy script, Lua OOM or client buffers restart only this pod.

## Pieces

| Piece | Where | What it does |
|---|---|---|
| Redis | StatefulSet `cloud-redis`, `redis:8.10.3-alpine` pinned by digest, `redis-server /etc/redis/redis.conf`, no modules | `maxmemory 512mb` in a 1Gi pod (request = limit), volatile-lru, AOF everysec, PVC 5Gi `proxmox-lvm-encrypted-sas` |
| Client limits | ConfigMap `cloud-redis-conf` | `proto-max-bulk-len 32mb` < `client-query-buffer-limit 64mb` < `maxmemory-clients 128mb`; `client-output-buffer-limit normal 64mb 16mb 60` and `pubsub 64mb 16mb 60` (the hard limit holds one reply of the largest value: 32mb cut off the GET of a legal 32 MiB value); `busy-reply-threshold 5000`. Redis does not check that they nest; `tests/cloud-redis.test.sh` does |
| Users | `acl_users.json`, passwords in Vault `secret/cloud-redis/users` | `default` is off from the first file. `acl-admin` (the sync), `exporter`, `backup`, `probe` (the probes). The apply writes the passwords (`random_password`) and Secrets `cloud-redis-infra-users` and `cloud-redis-acl-seed` |
| Sync | CronJob `cloud-redis-acl-sync`, every minute | The shared `stacks/redis/modules/redis/acl_sync.py` with `DEFAULT_USER=off` and the tenant section on. Vault role `cloud-redis-acl-sync` reads `secret/cloud-redis/users` and `secret/cloud-redis/cloud-tenants`. Pushgateway job `cloud-redis-acl-sync`, groups `-kv` and `-kv-usage` |
| Tenant route token | `random_password.cloud_tenants_token` | Vault `secret/cloud-redis/cloud-tenants` (the sync) and `secret/cloud/redis-tenants` (Cloud, ExternalSecret `cloud-reconciler-redis-tenants` in `stacks/cloud`) |
| Backup | CronJob `cloud-redis-backup`, suspended; the Proxmox host's nightly-chain starts it on Sundays | BGSAVE, then `redis-cli --user backup --rdb` to NFS `/srv/nfs/cloud-redis-backup`, keeping 28 days |
| Metrics | `redis_exporter v1.97.0` sidecar on 9121, scraped through the pod annotations | `redis_*{namespace="cloud-redis"}`, plus the sync's pushed series |
| Network | NetworkPolicies `default-deny`, `cloud-redis-ingress`, `<job>-egress` | 6379 from namespaces labelled `cloud.viktorbarzin.me/managed=true`, Cloud's reconciler pods, and the sync and backup pods; 9121 from monitoring and the kubelet. The sync reaches DNS, Redis, the reconciler's 9091, Vault and the Pushgateway; the backup DNS, Redis and the Pushgateway |

## First apply

1. `stacks/vault`, applied by an admin by hand (CI does not apply vault): policy `ci` may write `secret/cloud-redis/*` and `secret/cloud/redis-tenants`; policy and role `cloud-redis-acl-sync`.
2. On the NFS host, as for other backups, then record it in `secrets/nfs_directories.txt` from the main checkout: `mkdir -p /srv/nfs/cloud-redis-backup && chown root:www-data /srv/nfs/cloud-redis-backup && chmod 2777 /srv/nfs/cloud-redis-backup`.
3. `stacks/cloud-redis`: CI applies it on the push. The apply writes `secret/cloud-redis/users` and both token paths itself; nobody writes them by hand.
4. `stacks/cloud` (the egress floor's Pass and the reconciler's NetworkPolicy point at cloud-redis), then the Cloud release whose defaults name `cloud-redis.cloud-redis.svc.cluster.local`.

Check: `kubectl -n cloud-redis get pods` (Ready), the newest `cloud-redis-acl-sync` Job's log ends `ok`, `cloud_kv_tenants_fetch_ok{job="cloud-redis-acl-sync"}` is 1.

## Cloud Key Value tenants

Cloud has no Redis right. Its reconciler publishes the Key Values it wants at a read-only route, `GET http://cloud-reconciler.cloud.svc.cluster.local:9091/internal/redis-tenants`, with the bearer token above; only the sync's pods reach port 9091. Each tenant is a user `p_<project>_<service>_<hash>` confined to keys and channels `p:<project>:<service>:*`. Cloud's reconciler logs in once as a new tenant (`AUTH` and `PING`) before Apps get `REDIS_URL`, when `max(push_time_seconds{job="cloud-redis-acl-sync-kv"})` is at least 60 s newer than the hash it recorded and `cloud_kv_ready` is 1.

Each run of the sync:

1. reads the route and checks every field: user `^p_[a-z0-9_]+$`, a 64-hex hash, prefix `^p:[a-z0-9-]+:[a-z0-9-]+:$` equal to `p:<project>:<service>:`, a positive Size, no name or prefix twice. One bad field rejects the whole answer;
2. when the route fails or the answer is bad, keeps the tenant users cloud-redis already holds, unchanged, and pushes `cloud_kv_tenants_fetch_ok 0`. A Cloud outage drops no tenant, and new, resized or deleted Key Values wait;
3. writes each tenant from the fixed template (cloud repo, `checklist-and-backlog.md`, "Cloud tenants"), never from Cloud's input. Redis prints it as `user <name> on sanitize-payload #<sha256> ~<prefix>* resetchannels &<prefix>* -@all +@read +@write +@keyspace +@hash +@list +@set +@sortedset +@stream +@string +@pubsub +@transaction +@scripting +@connection -@dangerous -select -scan -randomkey -function -script|flush -move -copy -script|kill -dbsize -pubsub|channels -pubsub|shardchannels -pubsub|numsub -pubsub|shardnumsub -pubsub|numpat -script|debug -client|tracking -himport|prepare -himport|discard -himport|discardall -lolwut`. `KEYS`, `SELECT`, `FLUSHALL`, `SCAN`, `CONFIG`, `INFO`, `MOVE`, `COPY` (which can name another db), `SWAPDB`, `RESTORE`, `MIGRATE`, `SCRIPT KILL`, `SCRIPT DEBUG` (with `EVAL` it blocks the whole server), `CLIENT TRACKING` (`BCAST` sends the name of every key anyone writes), `DBSIZE`, the PUBSUB introspection subcommands, the keyless `HIMPORT` session subcommands, `LOLWUT`, and every key or channel outside the prefix answer `NOPERM` (tested against `redis:8.10.3-alpine`). `SCRIPT LOAD` stays, because ioredis needs it; `RedisScriptCacheHigh` watches the memory loaded scripts hold, which Redis never evicts. cloud-redis loads no module; if one is ever loaded, the sync (from `ACL CAT`) and the init step (from the config) add `-@search` and `-ts.mget -ts.mrange -ts.mrevrange -ts.queryindex -ts.querylabels`. `acl_sync_test.py` walks `COMMAND`, subcommands included, with `ACL DRYRUN` for both rule sets, with and without the modules, and fails on any keyless command a tenant may run that its reviewed allowlist (`KEYLESS_ALLOWED`, one reason per entry) does not name;
4. after the infra users are applied and checked, so a fault here never fails them, a measuring run (every 5 min, when the UTC minute divides by 5) makes two `SCAN MATCH p:* COUNT 1000` passes over db 0. The first counts each tenant's keys exactly and deletes purged prefixes. The second goes on from where the last run stopped and sends `MEMORY USAGE <key> SAMPLES 0` (every element of a list, set, hash or sorted set, so a few small elements cannot hide a big key) for every tenant key it meets, up to 100,000 calls a run plus the rest of one SCAN page. The cursor and each tenant's running total live in Redis, in key `redis-acl-sync:kv-measure` (`acl-admin` holds `~redis-acl-sync:*` with `GET` and `SET`; no tenant can reach it; no TTL, so never evicted). A missing or broken value starts a new cycle. A tenant's bytes are its running total plus every key not sized yet in the cycle counted at the largest key sized for it. Keys a complete cycle has sized are never undercounted; a key written during a cycle that is bigger than any sized so far counts low until the cycle reaches it, at most one cycle later. When every tenant key in all fits in one run (100,000 keys) each run is a complete cycle and the figure is exact. A cycle over K tenant keys takes ceil(K / 100,000) measuring runs. A tenant with more than 100,000 keys is treated as over its Size. Cost at 10,000 tenant keys: about 32 SCAN calls and 10 batches, about 10 ms of Redis CPU for small strings. A fault during the measurement is logged ("Key Value measurement failed") and leaves the run ok;
5. a tenant over its Size gets the read-and-delete rule set `-@all +@read +@connection +del +unlink +multi +exec +discard +watch +unwatch -@dangerous -select -scan -randomkey -move -copy -script|kill -dbsize -pubsub|channels -pubsub|shardchannels -pubsub|numsub -pubsub|shardnumsub -pubsub|numpat -script|debug -client|tracking -himport|prepare -himport|discard -himport|discardall -lolwut` (plus the module part) on the same prefix, in a second `MULTI` right after the measurement: GET and DEL work, writes, scripts and PUBLISH answer `NOPERM`. It goes back to the full template at the first measurement under its Size. Between measurements the mode stays as ACL LIST shows it; the ACL is the only state kept between runs.

`acl-admin` holds `~p:* ~redis-acl-sync:* +scan +memory|usage +unlink +get +set` for the measurement, its state key and the purge, and nothing else on keys.

`acl-admin` holds `~p:* ~redis-acl-sync:* +scan +memory|usage +unlink +get +set` for the measurement, its state key and the purge.

Between two measurements a tenant can keep writing, each write at most 32 MiB (`proto-max-bulk-len`), until the read-and-delete rule set lands; past `maxmemory` volatile-lru evicts Key Value keys with a TTL and then refuses writes. Only Key Values share that risk.

### Purge

A Key Value's keys go only when Cloud lists its prefix under `purge` (the Key Value was removed from a Project File, or its Project was purged, in the last 30 days). On a measuring run the sync `UNLINK`s the keys under a purge prefix only when the answer was good this run, no tenant in the answer has that prefix, and no tenant user in Redis holds it at the start of the run: the user goes first, the keys at a later measurement. A tenant that vanishes from the answer without a purge entry loses its user and keeps its keys, so a Cloud bug or a bad answer never deletes data. Leftover keys of a vanished tenant stay until Cloud lists them for purge.

### Foreign users

`RedisForeignUser` fires when a run found a user that is neither in `acl_users.json`, nor a tenant from the route, nor shaped exactly like the tenant template. The run deleted it (`ACL DELUSER`), and the CronJob log names it (`foreign ACL user (removed this run): <name>`). Only `acl-admin` can make users on cloud-redis, so treat it as a leaked `acl-admin` password: rotate it (`-replace` of `random_password.users["acl-admin"]` in a stacks/cloud-redis apply) and read `ACL LOG` through break glass.

### When Cloud's route fails

`CloudKeyValueTenantsFetchFailing`: the log says why. `unreachable` means the reconciler pod is down or its port 9091 is not served (the reconciler serves it only when its `REDIS_TENANTS_TOKEN_FILE` holds a token). `answered 401` means the two token copies differ: ESO refreshes Cloud's copy every 2 minutes and Reloader restarts the reconciler; `kubectl -n cloud get externalsecret cloud-reconciler-redis-tenants`. `bad answer` names the field; that is a Cloud bug, file it on the cloud repo.


## Alerts

| Alert | Pages | First step |
|---|---|---|
| `CloudRedisDown` | yes | `kubectl -n cloud-redis describe pod cloud-redis-0`; the redis container's log |
| `CloudRedisBusy` | no | a script past 5 s or a restart: `SLOWLOG GET` through break glass, `kubectl -n cloud-redis logs cloud-redis-0 -c redis --previous` |
| `CloudRedisMemoryPressure`, `CloudRedisEvictions`, `CloudKeyValueTotalHigh` | no | `topk(5, cloud_kv_bytes)`; raise `maxmemory` and the pod limit together |
| `CloudRedisBackupStale`, `CloudRedisBackupNeverSucceeded` | yes | the newest `cloud-redis-backup` Job's log; the NFS directory |
| `CloudRedisAclSyncStale`, `CloudRedisAclSyncNeverSucceeded`, `CloudKeyValueTenantsFetchFailing` | no | the newest `cloud-redis-acl-sync` Job's log |
| `RedisForeignUser` | yes | "Foreign users" above |
| `RedisScriptCacheHigh` | no | find the client, then flush through break glass |

## Break glass

cloud-redis has no `+@all` user. To run an admin command (`SLOWLOG`, `SCRIPT FLUSH ASYNC`, `ACL LOG`), suspend the sync first or it removes the user within a minute and `RedisForeignUser` pages: set `suspend` on CronJob `cloud-redis-acl-sync` through Terraform, then as `acl-admin` (password in Vault `secret/cloud-redis/users`, over stdin) run `ACL SETUSER breakglass on >... ~* &* +@all`, do the work, `ACL DELUSER breakglass`, and unsuspend.
