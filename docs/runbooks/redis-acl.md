# Redis ACL users runbook

The shared Redis (`redis-v2-0` in namespace `redis`, service `redis-master.redis`) has one named ACL user per consumer. This is phase R1 of the password rollout (cloud repo, `docs/build/render-parity/checklist-and-backlog.md`, "Redis password rollout, B40 design"). In R1 the `default` user keeps `on nopass ~* &* +@all`, so every client works as before and nobody uses the named users yet. R2 moves each consumer to its own user, R3 watches `redis_default_clients_unexpected` (default clients outside rybbit, which can send only a password) stay at 0 for 7 days, and R4 locks `default` with a password.

## Pieces

| Piece | Where | What it does |
|---|---|---|
| Users and their rules | `stacks/redis/modules/redis/acl_users.json` | One user per consumer namespace, plus `acl-admin`, `exporter`, `backup`, `probe`, `verify`. Consumers get `~* &* +@all`, the same as `default`. |
| Passwords | Vault `secret/redis/users`, one key per user, plus `default` (`random_password.redis_default`) | `random_password` in `acl.tf`, 40 letters and digits. The sync job reads them; from R2 each consumer's ExternalSecret names its own key. Vault does not isolate keys: the `eso-reader` and `ci` policies read all of `secret/data/*`, so any infra namespace's ExternalSecret could name any key. The isolation rests on reviewing each ExternalSecret. |
| aclfile | `/data/acl/users.acl` on the Redis PVC (`aclfile` in `redis.conf`) | Holds `#<sha256>` hashes only. Redis writes it on `ACL SAVE`. |
| Redis's own users | Secret `redis-infra-users` (`acl.tf`), keys `probe`, `exporter`, `backup` | A Terraform Secret built from the same `random_password`s, so it exists before the Redis pod needs it. The liveness and readiness probes run `probe.sh` (`redis-cli --user probe PING`, password from `REDIS_PROBE_PASSWORD`), the exporter sidecar sets `REDIS_USER=exporter` and `REDIS_PASSWORD`, and `redis-backup` runs `redis-cli --user backup` with `REDISCLI_AUTH`. The probe and exporter refs are optional, so a missing Secret cannot keep Redis from starting. After a refused `AUTH`, `redis-cli` carries on as `default` and exits 0, so a wrong probe password does not fail the probe (it shows as `user=default` in `CLIENT LIST` and in `redis_acl_access_denied_auth_total`); the backup job checks its login with a `PING` that must print only `PONG`. |
| Seed | Secret `redis-acl-seed`, init container `acl-seed` (`acl_init.sh`) | Redis does not start when its aclfile is missing. The init container writes the seed (`default` unchanged, `acl-admin`) if the file is missing, and otherwise replaces only the `acl-admin` line. |
| Sync | CronJob `redis-acl-sync`, every minute (`acl_sync.py`) | Reads Vault, renders every user, and sends the difference as `acl-admin` in one `MULTI` (`ACL SETUSER`, `ACL DELUSER` for users nobody wants). `EXEC` does not roll back: if Redis refuses one command, the others stay applied, the run fails as a partial change, and the next run retries. Every run ends with `ACL SAVE`, so a lost save is on disk a minute later. Then it checks `ACL LIST` against the render and checks that every user can `AUTH` and `PING`. |
| Counter (R3) | the same job, every minute | `CLIENT LIST` counted by `user=`, pushed as `redis_clients_by_user{user}`, with a 0 for `default` and every user that has no client. It also pushes `redis_default_clients_unexpected`: the `default` clients whose address is not a pod of `local.redis_default_user_namespaces` (`rybbit`, see "Rybbit stays on default"). The pod IPs come from the Kubernetes API through the Role `redis-acl-sync-pods` (list pods) in each of those namespaces. When that lookup fails, every `default` client counts as unexpected, so the gate stays red. For each unexpected client the job prints one stderr line, `unexpected default client: addr=... name=... age=... idle=... cmd=... lib-name=... lib-ver=...`, so the latest `redis-acl-sync` Job's log names it; find the pod that held the address at that time in the Kubernetes audit log. `cmd` is the command name only; CLIENT LIST never prints arguments. |
| Vault access | `stacks/vault/main.tf`: role and policy `redis-acl-sync` (read `secret/data/redis/users`); policy `ci` writes that path | |
| Alerts | `stacks/monitoring` group "Critical Services": `RedisAclSyncStale` (no success for 10 min), `RedisAclSyncNeverSucceeded` (15 min), `RedisMemoryHigh` (over 70% of maxmemory for 15 min) | warning |
| Tests | `tests/redis-acl.test.sh` | pytest against a real `redis:8.10.3-alpine`, and promtool for the alerts |

**Why the sync works over the network.** The data PVC is ReadWriteOnce. A second pod could mount it only on redis-v2-0's node, tied to it by pod affinity, with write access to the AOF and RDB files. `ACL SAVE` makes Redis write the aclfile itself, through a temporary file and a rename. `ACL SETUSER` and `ACL LOAD` do not disconnect the clients of a user that still exists; `ACL DELUSER` does (measured on 8.10.3).

**Fail closed.** The sync changes nothing and exits non-zero when Vault is unreachable, when a Vault key is missing or extra, when a password or name is malformed, or when the render lacks the `default` line or an infra user. When Redis refuses part of a change, the run fails and reports a partial change (see Sync above). The pushgateway then keeps the last `redis_acl_sync_last_success_timestamp_seconds`, and `RedisAclSyncStale` fires after 10 minutes. No client loses access because of a failed run.

## Metrics

Pushgateway job `redis-acl-sync`:

| Metric | Meaning |
|---|---|
| `redis_acl_sync_last_success_timestamp_seconds` | last run that applied and checked every user |
| `redis_acl_sync_last_run_timestamp_seconds`, `redis_acl_sync_last_run_ok` | last run, and whether it succeeded |
| `redis_acl_sync_changes`, `redis_acl_sync_users` | commands the last successful run sent, users it manages including `default` |
| `redis_acl_user_auth_ok{user}` | 1 when that user's `AUTH` and `PING` worked in the last run |
| `redis_clients_by_user{user}` | connected clients per user, 0 for `default` and every user without a client. `default` stays above 0 while rybbit is connected |
| `redis_default_clients_unexpected` | `default` clients outside the namespaces allowed on `default` (rybbit); the R3 gate is this at 0 for 7 days. Start the 7 days only after the `redis` stack's own move has landed ("redis: probes, exporter and backup log in as their own ACL users"): until then the kubelet probes and the exporter connect as `default` from Redis's own pod |

The same counts are in `redis_clients_by_user{user="p_..."}` above. The `project` and `service` labels are Cloud's own names; the pushgateway scrape keeps them (`honor_labels: true`).

Redis's own `redis_acl_access_denied_auth_total` (and its key, channel and command siblings) comes from redis_exporter.

## Check it

```sh
cd ~/code/infra
scripts/verify/run redis      # runs stacks/redis/verify.sh as a Job in namespace verify
kubectl --context kubernetes-admin@kubernetes -n redis exec redis-v2-0 -c redis -- redis-cli ACL LIST
kubectl --context kubernetes-admin@kubernetes -n redis get cronjob redis-acl-sync
kubectl --context kubernetes-admin@kubernetes -n redis get jobs --sort-by=.metadata.creationTimestamp -o name \
  | grep redis-acl-sync | tail -1 | xargs kubectl --context kubernetes-admin@kubernetes -n redis logs
homelab metrics query 'redis_clients_by_user'
```

`verify.sh` holds one Redis password, the `verify` user's (`REDIS_VERIFY_PASSWORD` in `verify-app-creds`, `stacks/verify`), and writes its db 15 scratch key as that user. It reads `ACL LIST` as `default` (until R4), the user list from the `redis-acl-sync` ConfigMap, and the sync's own `AUTH` results from Prometheus.

Clients per namespace, read-only. Match ` addr=`, with the space: `laddr=` is Redis's own address and would count every client as `redis`.

```sh
kubectl --context kubernetes-admin@kubernetes -n redis exec redis-v2-0 -c redis -- redis-cli CLIENT LIST \
  | grep -oE ' addr=[0-9.]+' | cut -d= -f2 | sort | uniq -c > /tmp/redis-ips.txt
kubectl --context kubernetes-admin@kubernetes get pods -A --field-selector=status.phase=Running -o json \
  | jq -r '.items[] | select(.spec.hostNetwork != true) | "\(.status.podIP) \(.metadata.namespace)"' > /tmp/pod-ips.txt
awk 'NR==FNR{ns[$1]=$2; next} {n=ns[$2]; if(n=="") n="other:"$2; c[n]+=$1} END{for(k in c) print c[k], k}' \
  /tmp/pod-ips.txt /tmp/redis-ips.txt | sort -rn
```

## The sync is stale

Read the last failed Job's log; it names the reason on one line (`FAILED, nothing more changed: ...`).

| Reason | Fix |
|---|---|
| `Vault unreachable or refused` | Vault sealed or down, or the role `redis-acl-sync` missing: `stacks/vault` must be applied before `stacks/redis`. |
| `has no key for` / `does not name` | `acl_users.json` and Vault disagree. A Terraform apply writes both; one failed run in the middle of an apply is normal. Otherwise apply `stacks/redis`. |
| `WRONGPASS` on acl-admin | acl-admin's password changed and Redis still has the old hash. See "Rotate a password". |
| `NOPERM` | `acl-admin` lost a command it needs (`+acl +client|list +multi +exec +ping`). Fix `acl_users.json`; `tests/redis-acl.test.sh` catches this. |
| `ACL LIST differs from the render` | Redis normalised a rule differently from `acl_users.json`. Write the rule the way `ACL LIST` prints it (for example `resetchannels` when a user has no channels). |

## Cloud Key Value tenants

Cloud's Key Values live on their own Redis, cloud-redis (cloud B27 option b): [cloud-redis.md](cloud-redis.md). This Redis runs the same `acl_sync.py` with the tenant section off (no `CLOUD_TENANTS_URL`): it wants no tenant, and any user it did not make, a `p_*` one included, is removed on the next run. The `acl-seed` init step still rewrites `p_*` lines to the modules this `redis-server` loads (`acl_init.sh`), which keeps an aclfile from blocking a start, and `proto-max-bulk-len 128mb` caps one write here. **A change to `redis.conf` or the init step restarts Redis**: land it in a planned window after `presence claim redis:redis-v2`.

## Add a user

A new consumer namespace: add `"<namespace>": "~* &* +@all"` to `acl_users.json` and add the namespace to `local.redis_client_namespaces` in `main.tf`. The push applies `stacks/redis`; Vault gets the password and the sync creates the user within a minute. The consumer's ExternalSecret reads `secret/redis/users`, property `<namespace>`.

## Move a consumer to its user

From R2 each consumer namespace logs in as its own user. The pattern:

- One ExternalSecret in the namespace, `vault-kv`, `remoteRef = { key = "redis/users", property = "<namespace>" }`, and no other key of that path. When the app wants a URL, build it in the ESO template: `redis://<namespace>:{{ .password }}@redis-master.redis.svc.cluster.local:6379/<db>`. Keep the db the app uses today, so no key moves.
- Read it with a `secret_key_ref` that is not optional, or a Secret volume. A pod that starts before ESO has written the key then waits, instead of starting with the app's password-less default.
- Send the username with the password. While `default` is `nopass`, Redis answers a one-argument `AUTH <password>` with an error. Clients differ: a raw `AUTH` gets the error, `redis-cli -a` prints it and carries on as `default`, go-redis v9 sends `HELLO 3 AUTH default <password>`, which works, and ioredis logs the error as a warning and stays connected. A client that cannot send a username stays on `default` with `default`'s password (see "Rybbit stays on default").
- Restart on rotation: Reloader (`reloader.stakater.com/auto`, a `secret.reloader.stakater.com/reload` list, or `reloader.stakater.com/match` on the Secret for `search` mode).
- Keep the password out of logs: check that the app does not log its Redis URL.
- `redis-cli` exits 0 on an error reply (`NOAUTH`, `WRONGPASS`, `NOPERM`), and after a refused `AUTH` it carries on as `default`. A script checks the reply text, not the exit code: a login check is a `PING` whose whole output, stderr included, is `PONG`.
- While `default` is open, a wrong password does not break every client: `redis-cli` carries on as `default`, and the R2 review found the same for rspamd and Dawarich, so the app stays healthy. The gate for each stack is therefore `CLIENT LIST` showing its clients as `user=<namespace>` after real traffic has reached them, not the app's health alone.

## Rotate a password

```sh
cd ~/code/infra && scripts/tg apply stacks/redis -replace='module.redis.random_password.redis_acl["<user>"]'
```

The sync applies the new hash within a minute, and the old password stops working for new connections at once. From R2, force-sync that consumer's ExternalSecret right after and let Reloader restart it.

**probe and exporter** live in the Redis pod's env, which keeps the old password until the pod restarts. After a rotation the probes still pass (see Pieces), but every probe adds to `redis_acl_access_denied_auth_total` and the exporter reports `redis_up` 0 until the next Redis restart. Rotate them only in a Redis restart window. `backup` is read when each backup Job starts.

**acl-admin** is different: the sync logs in with the new password, which Redis does not know yet. The next Redis restart fixes it (the init container writes the new `acl-admin` line). Without a restart, and while `default` is still open (R1 to R3), set the new hash as `default`; the password stays out of argv and logs:

```sh
vault kv get -field=acl-admin secret/redis/users | sha256sum | cut -d' ' -f1 \
  | kubectl --context kubernetes-admin@kubernetes -n redis exec -i redis-v2-0 -c redis -- sh -c \
    'h=$(cat); redis-cli ACL SETUSER acl-admin reset on "#$h" resetchannels -@all +ping +acl +client\|list +multi +exec'
```

## Roll back R1

Before any consumer uses its user (R2): revert the commit "redis: named ACL users kept by redis-acl-sync, default unchanged" (`git log --grep "kept by redis-acl-sync"`) and push. The same commit holds the `RedisAclSync*` alerts, so the revert removes them too. CI applies `stacks/monitoring` and `stacks/redis`: `redis.conf` loses `aclfile` (one Redis restart, seconds), and the init container, seed Secret, CronJob and Vault `secret/redis/users` go. Deleting the Vault secret needs `delete` on `secret/data/redis/users` and `secret/metadata/redis/users`, which the `ci` policy has (`stacks/vault`). Redis then runs with only the built-in `default` user again. `/data/acl/users.acl` stays on the PVC unused. Keep the `stacks/vault` grants; they cost nothing and the next attempt needs them.

## Break glass

When the ACL locks a client out (R4 and later):

1. Suspend the sync, or it puts back its own `default` rule within a minute. In `stacks/redis/main.tf` set `acl_sync_suspended = true` and commit it. Push it (CI applies `stacks/redis`), or, faster, apply that commit from the main checkout and push it in the same session:

```sh
cd ~/code/infra/stacks/redis && ../../scripts/tg apply -target=module.redis.kubernetes_cron_job_v1.redis_acl_sync
```

2. Open `default` as `acl-admin`, with the password kept out of argv:

```sh
vault kv get -field=acl-admin secret/redis/users \
  | kubectl --context kubernetes-admin@kubernetes -n redis exec -i redis-v2-0 -c redis -- sh -c \
    'export REDISCLI_AUTH="$(cat)"; redis-cli --no-auth-warning --user acl-admin ACL SETUSER default on nopass "~*" "&*" +@all; redis-cli --no-auth-warning --user acl-admin ACL SAVE'
```

3. Revert the commit that caused the lockout, set `acl_sync_suspended = false` again, and push.

## Rybbit stays on default

Rybbit v2.9.3 (`src/db/redis/redis.ts`, ioredis 5.8.2) reads `REDIS_HOST`, `REDIS_PORT` and `REDIS_PASSWORD` and no username, so it cannot log in as a named user. It sends `REDIS_PASSWORD`, which `stacks/rybbit` reads from the `default` key of `secret/redis/users`. While `default` is `nopass`, Redis answers that one-argument `AUTH` with an error, and ioredis 5.8.2 logs it as a warning and stays connected (`built/redis/event_handler.js`, measured on `redis:8.10.3` on 2026-11-18). After R4, the same password is `default`'s.

Rybbit's keys, from its source at v2.9.3: `bot:*`, `session:*`, `rl:*`, `sticky:*`, `feature-flags:*` and `fastify-rate-limit-*` (the `@fastify/rate-limit` store), all in db 0, no pub/sub.

Upstream change that would let `default` go off: a `REDIS_USERNAME` env read into ioredis's `username` option in `createRedisClient` (`src/db/redis/redis.ts`). With it, rybbit moves to its own user like the others, `local.redis_default_user_namespaces` empties, and R4 can set `user default off`.

## R4: locking default

These change together, in one commit: the `default` line in the seed (`kubernetes_secret.redis_acl_seed` in `acl.tf`), `DEFAULT_USER_ARGS` and `DEFAULT_USER_LINE` in `acl_sync.py`, and `_acl_default_open` and the `ACL LIST` login in `stacks/redis/verify.sh` (as the `verify` user from then on). Keep an explicit `default` line: a file without one leaves `default` on, nopass, `+@all`. The lock does not show that no client uses `default`; the R3 count does. Lock only after `redis_default_clients_unexpected` has been 0 for 7 days, and land `RedisAuthDenied` (branch `wizard/b40-r4-auth-denied`) with it.

Before R4, every consumer has moved. yt-highlights (`stacks/ytdlp`, parked at 0 replicas) moves last: its image `viktorbarzin/yt-highlights` is built by hand with no CI, and its current tag logs the whole `REDIS_URL` at start. Branch `wizard/b40-r2-ytdlp-log` stops that; an image built from it has to run before `wizard/b40-r2-ytdlp` puts the password in the URL. A Sablier wake-up of the old image after R4 would fail to log in, so this is an R4 prerequisite. The unmounted `redis.conf` key in the `mailserver.config` ConfigMap is removed in R5.

While rybbit is in `local.redis_default_user_namespaces`, R4 does not turn `default` off. It sets `default`'s Vault password as its hash: `user default on #<sha256 of the default key> ~* &* +@all`, rendered by the sync like any other user. The rule can narrow to rybbit's keys (`~bot:* ~session:* ~rl:* ~sticky:* ~feature-flags:* ~fastify-rate-limit-*`), but a Rybbit upgrade that adds a key prefix would then fail its writes with `NOPERM`, so `~*` is the safer choice until upstream reads a username.
