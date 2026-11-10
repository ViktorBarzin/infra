# Block volumes: which databases can move to the shared clusters

Research note, 2026-11-09. Read-only: nothing was applied, scaled, restarted or
moved. Inputs are the database-file scan of every running pod's block mount
(`/var/tmp/claude-1000/scan/out.txt`, one line per PVC), `kubectl get`/`exec`
with `ls`, `cat` and `find -maxdepth 2`, the stacks in this repo, and upstream
docs and source. It builds on
`docs/research/2026-11-09-block-storage-without-slot-cap.md`, which looked at
removing the slot cap itself.

Every claim carries one of three labels:

- **[measured]** read on the live cluster today.
- **[source]** read in upstream docs or code, or in this repo, with a URL or a
  file and line.
- **[inferred]** reasoning from the above, not observed or tested.

## Summary

1. There are 83 block PVCs because the 2026-04-04 wave moved every SQLite app off NFS after corruption, the storage rule then made block the default for every new app, and several apps keep one PVC per concern; 60 were attached at scan time and 59 now, with 21 on k8s-node4 [measured].
2. Few of the 60 are a database that could live elsewhere: 19 hold an embedded DB with no supported external option or a sensitive remainder, 18 are DB servers or core state, and 13 belong to apps that already use the shared Postgres or MySQL and keep the volume only for files [measured, source].
3. **17 slots** can be freed for S or M effort without breaking the sensitive-data rule, 23 with the low-value moves; only 4 of them go to NFS, because most remainders are sensitive and `/srv/nfs` is not encrypted [inferred].
4. Top 5 by slots per effort: Vault audit to stdout (3, S); uptime-kuma, learning, aiostreams and ntfy to no volume (4, S); roundcube html to emptyDir and enigma keys into MySQL (2, S); glitchtip and health uploads, both empty, to no volume (2, S); meshcentral files merged into data (1, S).
5. Folding separate DB servers in is poor value: immich-postgresql needs VectorChord and 3 GB of buffers the shared pool does not have, and merging the two ClickHouse instances frees 1 slot for M effort; the shared Postgres is at 127 of 200 connections, about 7 more apps at 10 connections each, while MySQL is at 13 of 80 [measured, inferred].

## Progress

- 2026-11-09, **aiostreams**: `/app/data` moved to NFS (`aiostreams-data-host`,
  `/srv/nfs/aiostreams`), 169 MB copied so caches and `instance-id` carried over.
  1 slot freed; the old PV is Released under Retain.
- 2026-11-09, **Vault audit**: deferred by Viktor. The real scope is larger than
  candidate 1 below says: 7 Loki security rules match
  `container="audit-tail"` and need rewriting for the Vault container's own
  log; the `vault-audit-rotate` CronJob, its two Prometheus alerts and
  `docs/runbooks/vault-audit-device-full.md` go; and the StatefulSet's
  volumeClaimTemplates are immutable, so it needs an orphan delete, a Helm
  recreate and a pod-by-pod restart. Loki keeps logs 720h by default, so a
  365-day `retention_stream` for the audit stream was chosen for when it is done.
- 2026-11-09, **uptime-kuma**: its MySQL password was recorded only in
  `db-config.json` on the volume (no `uptime_kuma_db_password` in `secret/viktor`).
  Now Vault static role `mysql-uptimekuma` (Tuesday 10:12, dual password) feeds
  `UPTIME_KUMA_DB_*` env through ExternalSecret `uptime-kuma-db-creds`, and
  `/app/data` is emptyDir. 1 slot freed; the old PV is Released under Retain.

- 2026-11-09, **learning**: SQLite moved to the shared Postgres (database and
  role `learning`, Vault static role `pg-learning` at Tuesday 10:43, ExternalSecret
  `learning-db-creds` builds `DB_CONNECTION_STRING`). 4 events and 4 progress
  rows copied with the app's own models; the volume is gone. 1 slot freed.

- 2026-11-09, **ntfy**: users, access rules and tokens moved to the shared
  Postgres (database and role `ntfy`, Vault static role `pg-ntfy` at Tuesday
  10:44, `NTFY_DATABASE_URL` from ExternalSecret `ntfy-db-creds`). Upstream's
  `tools/pgimport` refused: it expects user-db schema v6 and this one is v11. The
  3 users, 2 access rules and 4 tokens were copied column for column into the v11
  schema ntfy created; token values verified by hash, and an existing token
  authenticates. No volume. 1 slot freed.

- 2026-11-09, **glitchtip and health uploads: keep**, after reading the code.
  health stores every Apple Health export under `UPLOAD_DIR` and never deletes
  it; `reprocess` re-reads the stored file, and an import running in a
  background task needs it across a restart (`~/code/health/backend/app/api/ingestion.py`).
  GlitchTip keeps `FileBlob` rows in Postgres that point at `uploads/file_blobs`
  on disk, plus symbol caches in `uploads/symbolcache` (glitchtip-backend v7.0.0
  `apps/files/models.py:34`, `apps/symbolication/store.py:71-73`); an emptyDir
  would leave rows pointing at missing files after each restart. Both hold
  sensitive data (health records, first-party source in source maps), so NFS is
  out. Candidate 5 below is withdrawn.

- 2026-11-09, **freshrss, qbittorrent, wa-bot to NFS**: each copied with a
  one-off pod, then the claim swapped. freshrss uses `/srv/nfs/freshrss/data-2026-11`
  because `/srv/nfs/freshrss/data` already held a stale pre-April copy, left in
  place; it serves its user with 10,719 articles. qbittorrent restored its
  torrents from `BT_backup`. wa-bot reads `state.json` and is ready. 3 slots freed.
- 2026-11-09, **meshcentral**: the files volume held only empty folders; they
  now sit in `meshcentral-files/` on the data volume, mounted with `subPath`.
  1 slot freed.

- 2026-11-09, **Roundcube, after reading the code** (roundcubemail-docker
  `apache/docker-entrypoint.sh` at 9fcc6e7, roundcubemail 1.7.6):
  - **html volume**: composer re-runs `require` for the 3 plugins on every start
    whatever the storage (entrypoint L123-139), so emptyDir adds no network
    dependency. The one piece of state is `des_key`: generated once into
    `config/config.inc.php` on this volume (L158-170). persistent_login encrypts
    its tokens with it (`persistent_login.php:351,373`), so an emptyDir would
    rotate the key on every restart. Safe only with `ROUNDCUBEMAIL_DES_KEY` set
    from a Secret (L192-193) holding the current key. **Tried and rolled back**
    the same hour: on a fresh tree the entrypoint runs composer before writing
    `config/config.inc.php`, so rcguard's database init fails, composer stops,
    and `persistent_login` is left empty (PHP error on every request). The
    volume stays, re-bound to its retained PV; `des_key` now comes from the
    Terraform Secret `roundcube-des-key`, which logged everyone out once.
  - **enigma volume: keep.** `me@viktorbarzin.me` holds private keys. Turning
    on `enigma_multihost` with an existing keyring and an empty `filestore`
    table makes `db_sync()` delete every local keyring file, and the first-sync
    `db_save` is then skipped because the loop reassigns `$file`
    (`plugins/enigma/lib/enigma_driver_gnupg.php:590-668`). Candidate 3's
    "enigma keys into MySQL" is withdrawn.

- 2026-11-10, **n8n sunset**: unused (a week of traffic was Uptime Kuma and
  bot probes; the one running workflow had failed all 14 runs). Archived a
  `pg_dump` plus the encryption key file to `/srv/nfs/archive/n8n-2026-11-10/`
  (mode 600), destroyed the stack, removed its outage-failover route, Kyverno
  exclude entry, catalog rows and both Uptime Kuma monitors. The `n8n`
  database stays in the shared Postgres by Viktor's choice. 1 slot freed.

- 2026-11-10, **prowlarr**: on the shared Postgres (databases `prowlarr` and
  `prowlarr_log`, both owned by role `prowlarr`; `app_databases` gained an
  optional `owner` for this; Vault role `pg-prowlarr` at Tuesday 10:13), config
  on NFS `/srv/nfs/servarr/prowlarr-config`. The config was exported through the
  API and re-created; the API masks the qBittorrent password and app API keys,
  so those came from the old SQLite file. `forceSave=true` does not skip a
  failing connectivity test: the Lidarr link was dropped because Lidarr no
  longer exists, and 52BT, ArenaBG, BT.etree and EBookBay were re-created
  disabled because they fail their test today. 1337x and Internet Archive are
  enabled; a search returns results. The old SQLite DB is archived at
  `/srv/nfs/archive/prowlarr-sqlite-2026-11-10/`. 1 slot freed.

## Why there are so many

- **The April wave and the default rule.** On 2026-04-04, 12 SQLite apps moved from NFS to `proxmox-lvm` after SQLite-on-NFS corruption hit vaultwarden and the calibre `queue.db`, and the storage rule then made block the default for every new service, encrypted for anything sensitive (`docs/agents/storage-backup.md:7-36`) [source]. Apps that already used the shared databases still got a block PVC for their files.
- **HA replicas each need their own volume.** Vault has 3 data and 3 audit PVCs, Technitium 3, CNPG 2 [measured].
- **One PVC per concern.** Roundcube has 2 in one pod, meshcentral 2 in one pod, trek 2, openclaw 3, vault 2 per pod [measured].
- **Leftovers.** 23 PVCs had no running pod at scan time. They hold no slot now, but CronJob and scale-to-zero users attach and detach on every run, which is the operation that leaks slots (`docs/architecture/storage.md`, "Poisoned LUN slots") [source].

Attached volumes per node, from VolumeAttachments: node1 5, node2 8, node3 9,
node4 21, node5 16; CSINode allocatable is 28 on each [measured].

## All 83 PVCs

Classes: `lvm` = proxmox-lvm, `enc` = proxmox-lvm-encrypted, `sas` =
proxmox-lvm-encrypted-sas, `ssd` = proxmox-lvm-ssd. "Ext DB" is whether the app
officially supports an external PostgreSQL or MySQL, details in the notes and
sources. "Slots" counts attached volumes that the verdict removes. Effort S is
one stack edit and a restart, M is a data migration or a code change, L is a
multi-stack change with a shared-DB restart. All content columns are
[measured] from the scan unless the cell says otherwise.

### Attached at scan time (60)

| # | App | PVC | Class | Content | Ext DB | Remainder after DB moves | Slots | Effort | Risk | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | actualbudget | actualbudget-anca-data-encrypted | enc | SQLite `account.sqlite` + budget SQLite, 88M | No, SQLite only | n/a | 0 | | | Keep |
| 2 | actualbudget | actualbudget-viktor-data-encrypted | enc | Same, 293M | No | n/a | 0 | | | Keep |
| 3 | aiostreams | aiostreams-data-proxmox | lvm | Already on shared PG (`DATABASE_URI=postgres://...postgresql.dbaas`); content unread, the image has no `ls` | Yes, in use | Downloaded anime DB, ID mappings, disk caches, instance ID | 1 | S | Low | emptyDir, see notes |
| 4 | android-emulator | android-emulator-sdk | ssd | Android SDK and AVD, 7.8G, regenerable | n/a | Same | 0 | | | Keep, placed on SSD by design 2026-11-03 |
| 5 | beads-server | dolt-data | lvm | Dolt SQL server data, 211M | Dolt is the server | n/a | 0 | | | Keep; folding into MySQL loses Dolt history |
| 6 | chrome-emo | chrome-emo-profile-encrypted | enc | Chromium profile: LevelDB + SQLite | No | n/a | 0 | | | Keep |
| 7 | chrome-service | chrome-service-profile-encrypted | enc | Chromium profile, 899M | No | n/a | 0 | | | Keep |
| 8 | claude-sessions | claude-sessions-data-encrypted | sas | ClickHouse server, 1.5G | Is a server | n/a | 0 | | | Keep; target if rybbit's ClickHouse merges |
| 9 | dbaas | data-mysql-v26-0 | sas | Shared MySQL, 11G | Is the server | n/a | 0 | | | Keep |
| 10 | dbaas | pg-cluster-v18-1 | sas | Shared CNPG instance, 21G | Is the server | n/a | 0 | | | Keep |
| 11 | dbaas | pg-cluster-v18-2 | sas | Shared CNPG primary, 22G | Is the server | n/a | 0 | | | Keep |
| 12 | ebooks | ebooks-abs-config-proxmox | lvm | Audiobookshelf `absdatabase.sqlite`, 1.4M | No, SQLite only | n/a | 0 | | | Keep |
| 13 | ebooks | ebooks-calibre-config-proxmox | lvm | CWA `app.db`, `cwa.db`, `gdrive.db`, Calibre `metadata.db`, 733M | No, SQLite only | n/a | 0 | | | Keep |
| 14 | forgejo | forgejo-data-encrypted | enc | Already on MySQL (`DB_TYPE = mysql`, `HOST = mysql.dbaas`); `gitea.db` is 0 bytes; git repos, LevelDB queues, bleve issue index, 19.3G | Yes, in use | Git repos, packages, attachments; queue and index can move to Redis and DB | 0 | | | Keep: git repos are sensitive by rule |
| 15 | freshrss | freshrss-data-proxmox | lvm | Already on MySQL (`'host' => 'mysql.dbaas'` in `data/config.php`); config, favicons, cache, `users/viktor`, 18M | Yes, in use | Config PHP files, favicons, cache | 1 | S | Low | NFS |
| 16 | frigate | frigate-config-encrypted | enc | `frigate.db` SQLite + WAL, 384M; holds the sqlite-vec search vectors too | No, SQLite only | n/a | 0 | | | Keep |
| 17 | glitchtip | glitchtip-uploads-encrypted | enc | Already on shared PG; volume holds only `lost+found` | Yes, in use | Nothing today | 1 | S | Low | Drop volume or emptyDir, see notes |
| 18 | headscale | headscale-data-encrypted | enc | `db.sqlite` (backup CronJob runs `sqlite3 /data/db.sqlite .backup`, `stacks/headscale/modules/headscale/main.tf:498`) plus keys | Postgres "highly discouraged", legacy only | Noise and DERP private keys | 0 | | | Keep: upstream steers to SQLite |
| 19 | health | health-uploads-encrypted | enc | First-party; already on shared PG; volume holds only `lost+found` | Yes, in use | Upload staging, empty | 1 | S | Low | emptyDir |
| 20 | immich | immich-postgresql-data-encrypted | sas | Separate Postgres 15 with `vchord 0.4.3`, `vector 0.8.1`, 3.9 GB, `shared_buffers=3072MB` | Existing PG supported, "not officially recommended"; needs VectorChord | n/a | 1 | L | High | Keep separate, see notes |
| 21 | learning | learning-data | enc | First-party; `learn.db` SQLite, 32K; TF sets `sqlite+aiosqlite:////data/learn.db` | Yes, code already supports asyncpg | Nothing | 1 | S | Low | Shared PG, delete PVC |
| 22 | linkwarden | linkwarden-archives-encrypted | enc | Already on shared PG; volume holds only `lost+found` since 2026-08-15 | Yes, in use; archives can go to S3 | Page archives, none written | 0 or 1 | S | Low | Open question: is archiving in use |
| 23 | mailserver | mailserver-data-encrypted | enc | Maildir, 3.0G | n/a | Same | 0 | | | Keep: dovecot locking, mail is sensitive |
| 24 | mailserver | roundcubemail-html-encrypted | enc | Roundcube app tree copied from the image, `vendor/` with composer plugins, `config/`, `logs/`, `temp/`, 37M; DB already on MySQL | Yes, in use | Code, regenerated by the entrypoint | 1 | S | Low | emptyDir, see notes |
| 25 | mailserver | roundcubemail-enigma-encrypted | enc | Enigma PGP homedirs for 2 users, 312K | Yes, `enigma_multihost` keeps keys in the `filestore` table | Local working copy only | 1 | S | Low | Keys to MySQL, homedir emptyDir |
| 26 | matrix | matrix-data-encrypted | enc | Tuwunel RocksDB, media inside it (exec failed, distroless) | No, RocksDB only | n/a | 0 | | | Keep |
| 27 | meshcentral | meshcentral-data-encrypted | enc | NeDB `meshcentral*.db`, CA and server private keys, config, 152M | Yes, MariaDB, MySQL, Postgres | Private keys, agent builds | 0 | | | Keep; target of the merge below |
| 28 | meshcentral | meshcentral-files-encrypted | enc | User file store, 296K | n/a | Files | 1 | S | Low | Merge into meshcentral-data by subPath |
| 29 | monitoring | storage-loki-0 | lvm | Loki chunks and TSDB index, 50Gi (exec failed) | Object store; the filesystem store is unsupported in production and NFS gives "a poor experience" | WAL and index cache need a volume anyway | 0 | | | Keep |
| 30 | monitoring | storage-prometheus-alertmanager-0 | enc | nflog and silences, 540K | n/a | Same | 0 | | | Keep: must survive an NFS outage |
| 31 | monitoring | prometheus-prometheus-pushgateway | enc | `pushgateway.bin`, 220K | n/a | Same | 1 | S | Medium | Optional emptyDir, see notes |
| 32 | monitoring | prometheus-data-proxmox | lvm | Prometheus TSDB, 28.6G | n/a | Same | 0 | | | Keep |
| 33 | n8n | n8n-data-encrypted | enc | Already on shared PG (`DB_TYPE`, `DB_POSTGRESDB_HOST`); `config` file with the encryption key, community `nodes/`, event logs, 57M | Yes, in use | Encryption key, community nodes | 1 | S | Medium | Key into a Secret, rest emptyDir, see notes |
| 34 | navidrome | navidrome-data-proxmox | lvm | `navidrome.db` + 3 older copies, 297M | No; Postgres PR #2821 open, unmerged | n/a | 0 | | | Keep; old copies can go |
| 35 | nextcloud | nextcloud-data-encrypted | enc | Already on MySQL (`dbtype mysql`); user files, app tree; 4 stale SQLite files of 40-51 MB, a 27 MB SQL dump and a 167 MB `nextcloud.log.1`, all from January to April 2026, 13G | Yes, in use | User files | 0 | | | Keep: user files are sensitive |
| 36 | novelapp | novelapp-data-proxmox | lvm | `novelapp.db` SQLite, 27M; third-party Next.js reading tracker `mghee/novelapp:v1.1.6` | No, Prisma SQLite only | n/a | 0 | | | Keep |
| 37 | ntfy | ntfy-data-proxmox | lvm | `user.db` auth SQLite only, 144K; no message cache file | Yes, Postgres via `database-url` since v2.18.0 | Nothing | 1 | S | Low | Shared PG, delete PVC |
| 38 | owntracks | owntracks-data-encrypted | enc | LMDB `ghash/data.mdb` + `lock.mdb`; location history in `rec/` | No; LMDB is always linked | Location history | 0 | | | Keep: LMDB, and location history is sensitive |
| 39 | paperless-ngx | paperless-ngx-data-encrypted | enc | Already on shared PG; `data/documents` (originals, archive, thumbnails), Tantivy index, `celerybeat-schedule.db`, `media.lock`, 26G | Yes, in use; `celerybeat-schedule.db` and the sqlite-vec `llm_index` stay in the data dir | Documents, index, lock files | 0 | | | Keep |
| 40 | plotting-book | plotting-book-data-proxmox | lvm | `database.sqlite` + WAL, 46M; Anca's app on `better-sqlite3` | Code change | Nothing | 1 | M | Low | Only with a port to Postgres in the app |
| 41 | redis | data-redis-v2-0 | sas | Shared Redis, 142M | Is a server | n/a | 0 | | | Keep |
| 42 | rybbit | rybbit-clickhouse-data-proxmox | lvm | ClickHouse server, 1.8M | Is a server | n/a | 1 | M | Medium | Merge into claude-sessions ClickHouse, see notes |
| 43 | servarr | servarr-listenarr-data-proxmox | lvm | `listenarr.db` SQLite + WAL, 222M | No, SQLite only | n/a | 0 | | | Keep |
| 44 | servarr | servarr-prowlarr-data-proxmox | lvm | `prowlarr.db`, `logs.db` SQLite, 52M | Yes, Postgres 14-18; migration from SQLite unsupported | `config.xml`, text logs, `asp/` keys, definitions | 1 | M | Low | Fresh install on shared PG, remainder to NFS |
| 45 | servarr | servarr-qbittorrent-data-proxmox | lvm | qBittorrent config and fastresume files, no DB found, 14M | n/a | Same | 1 | S | Low | NFS |
| 46 | technitium | technitium-primary-config-encrypted | enc | DNS zones, config, stats, 1.1G; query logs already go to MySQL/PG | n/a | Same | 0 | | | Keep: DNS must survive NFS outage |
| 47 | technitium | technitium-secondary-config-encrypted | enc | Same, 785M | n/a | Same | 0 | | | Keep |
| 48 | technitium | technitium-tertiary-config-encrypted | enc | Same, 763M | n/a | Same | 0 | | | Keep |
| 49 | tor-proxy | tor-proxy-torrserver-data-proxmox | lvm | `config.db` bbolt, 808K | No; settings can be JSON, the torrent list is always bbolt | n/a | 0 | | | Keep |
| 50 | tripit | tripit-personal-documents | enc | Already on shared PG; app-encrypted ID documents | Yes, in use | Documents | 0 | | | Keep: LUKS under app AES by design, memory #7571 |
| 51 | uptime-kuma | uptime-kuma-data-proxmox | lvm | Already on MySQL (`db-config.json` type `mariadb`, `uptimekuma`); 4 KB `kuma.db` from May; 25 MB `error.log`; `upload/` and `screenshots/` empty | Yes, in use; MariaDB by `UPTIME_KUMA_DB_*` env | `db-config.json`, rewritten from env at start | 1 | S | Low | Env from a Secret, data dir emptyDir |
| 52 | vault | audit-vault-0 | enc | File audit log, tailed to Loki by the `audit-tail` sidecar | n/a | Log | 1 | S | Medium | Audit device to stdout, see notes |
| 53 | vault | data-vault-0 | enc | Raft `raft.db`, `vault.db` (bbolt) | No, and circular | n/a | 0 | | | Keep |
| 54 | vault | audit-vault-1 | enc | As 52, 127M | n/a | Log | 1 | S | Medium | As 52 |
| 55 | vault | data-vault-1 | enc | As 53 | No | n/a | 0 | | | Keep |
| 56 | vault | audit-vault-2 | enc | As 52, 80M | n/a | Log | 1 | S | Medium | As 52 |
| 57 | vault | data-vault-2 | enc | As 53 | No | n/a | 0 | | | Keep |
| 58 | vaultwarden | vaultwarden-data-encrypted | enc | `db.sqlite3` 3.1 MB, 2 attachment dirs, `icon_cache`, `rsa_key.*`, 19M | Yes, PG and MySQL, stable | RSA key, 2 attachments, icon cache | 0 or 1 | M | Medium | DB to MySQL is sound; the slot needs attachments off block, see notes |
| 59 | wa-bot | wa-bot-data | lvm | First-party; one JSON file `/data/state.json` (`~/code/wa-bot/main.go:112`) | n/a, no DB | `state.json` | 1 | S | Low | NFS, or a table in shared PG |
| 60 | wealthfolio | wealthfolio-data-encrypted | enc | `wealthfolio.db` SQLite + 3 pre-migration backups, 261M | No, SQLite only | n/a | 0 | | | Keep |

### Not attached at scan time (23)

These hold no slot today. The ones that wake attach one when they do.

| # | App | PVC | Class | How it is used | Content and DB | Verdict |
|---|---|---|---|---|---|---|
| 61 | actualbudget | actualbudget-emo-data-encrypted | enc | `enabled = false` since 2026-05-13, "Emo isn't using this instance" (`stacks/actualbudget/main.tf:153-172`) | SQLite budget | Dormant; delete when Emo confirms |
| 62 | affine | affine-data-encrypted | enc | Sablier scale-to-zero | Blobs and config; DB already on shared PG | Keep |
| 63 | broker-sync | broker-sync-data-encrypted | enc | 7 CronJobs mount it; 4 run daily and 2 are suspended, so about 4 attach and detach cycles a day | First-party; SQLite dedup and FX cache (`~/code/broker-sync/broker_sync/dedup.py:37`, `fx.py:36`), Wealthfolio session JSON, CSV drop | Move SQLite to shared PG: removes the daily attach churn, M |
| 64 | dbaas | data-mysql-standalone-0 | enc | MySQL 8.4 rollback copy, 0 replicas since 2026-10-19 | MySQL datadir as of the 2026-10-15 cutover | Delete once the rollback window is closed |
| 65 | dbaas | dbaas-pgadmin-encrypted | enc | pgadmin at 0/0 | pgAdmin SQLite | Dormant |
| 66 | dbaas | pg-cluster-1 | enc | PG16 rollback copy, hibernated since 2026-10-19 | Postgres datadir | Delete once the rollback window is closed |
| 67 | drone-logbook | drone-logbook-data-encrypted | enc | Sablier, plus a daily backup CronJob | DuckDB `flights.db`, no external option | Keep |
| 68 | grampsweb | grampsweb-data-encrypted | enc | `replicas = 0` since 2026-03-14 ("Not actively used", `stacks/grampsweb/main.tf:190-192`) | Gramps tree, user DB and search index, all SQLite; each can move to Postgres | Dormant 8 months; looks abandoned |
| 69 | instagram-poster | instagram-poster-data | lvm | `replicas = 0` since 2026-06-24, crons suspended | First-party; already has role `pg-instagram-poster` | Dormant |
| 70 | monitoring | storage-tempo-0 | lvm | No Tempo workload, Helm release or Terraform in this repo; PVC created 2026-06-22; a second Released PV of the same name exists | Unknown | **Orphan**: no owner found |
| 71 | openclaw | openclaw-data-proxmox | lvm | Parked 2026-09-27 (`stacks/openclaw/main.tf:411-423`) | App data | Dormant; same pod as 72, could share one PVC |
| 72 | openclaw | openclaw-home-proxmox | lvm | Same | Home dir | Dormant |
| 73 | openclaw | openlobster-data-proxmox | lvm | `replicas = 0` | App data | Dormant |
| 74 | paperless-ai | paperless-ai-data-encrypted | enc | Scaled down 2026-10-12, paperless-ngx's own AI does the work (`stacks/paperless-ai/main.tf:143-151`) | `.env`, RAG index | Dormant; replaced |
| 75 | privatebin | privatebin-data-proxmox | lvm | Sablier | Paste files in `/srv/data` | `Database` model on MySQL or PG, then no volume |
| 76 | proxy | proxy-profile-edinpriqtelvirtual-gmail-com-432ab095 | enc | Created and reaped by the broker at runtime (`stacks/proxy/files/broker/broker.py:974,1014-1031`), not Terraform | Chromium profile | Keep, by design |
| 77 | proxy | proxy-profile-vbarzin-gmail-com-5f8bbfba | enc | Same | Chromium profile | Keep |
| 78 | renovate | renovate-apps-cache | ssd | CronJob every 6h | Regenerable cache | Keep; separate from 79 on purpose (`stacks/renovate/main.tf:340-344`) |
| 79 | renovate | renovate-cache | ssd | CronJob hourly, so 24 attach cycles a day | Regenerable cache | Keep, see open questions |
| 80 | repowise | repowise-workspace | enc | Parked; MCP endpoint removed 2026-10-02 | Per-repo SQLite `wiki.db` (memory #10948) | Dormant |
| 81 | stirling-pdf | stirling-pdf-configs-proxmox | lvm | Sablier | H2 `stirling-pdf-DB-*.mv.db` (memory #2807); external Postgres is documented as Enterprise only | Keep |
| 82 | trek | trek-data-encrypted | enc | Sablier | SQLite `data/travel.db`, no external option | Keep; same pod as 83 |
| 83 | trek | trek-uploads-encrypted | enc | Sablier | Uploads | Merge into 82 by subPath |

### Tally of the 60 attached

| Group | Count | Slots freed |
|---|---|---|
| Embedded DB with no supported external option, or a sensitive remainder | 19 | 0 |
| DB servers, Vault data, Loki, Prometheus, Alertmanager, DNS, mail, tripit, android SDK, Dolt | 18 | 0 |
| Do now, S effort | 15 | 15: vault audit 3, uptime-kuma, learning, aiostreams, ntfy, roundcube 2, meshcentral files, glitchtip, health, freshrss, qbittorrent, wa-bot |
| Worth doing with care | 2 | 2: n8n, prowlarr |
| Possible, low value or open | 6 | 0 to 6: vaultwarden, rybbit ClickHouse, immich-postgresql, pushgateway, linkwarden, plotting-book |

[inferred from the table]

## Candidates, by slots freed per effort

### 1. Vault audit to stdout: 3 slots, S

Vault writes a file audit log to `/vault/audit/vault-audit.log` on a
dedicated PVC per pod, and a sidecar `audit-tail` runs
`tail -F /vault/audit/vault-audit.log` so Alloy ships it to Loki with
`job=vault-audit` (`stacks/vault/main.tf:219-262`) [source]. The PVC is a buffer
in front of Loki today. Vault's file audit device takes `file_path=stdout`,
"useful when running in a container", and "does not currently assist with any
log rotation" for a real file [source: developer.hashicorp.com/vault/docs/audit/file].
stdout sends the same lines to the container log, where Alloy already collects
them. That removes 3 PVCs and the sidecar, and ends the unrotated growth that
pvc-autoresizer now absorbs.

Risk: the audit trail then exists only in Loki, with Loki's retention, not on
an encrypted volume [inferred]. Vault "refuses to service the corresponding API
request" when it cannot log to at least one enabled device, and the docs say to
"Enable at least two audit devices" [source: developer.hashicorp.com/vault/docs/audit].
Today there is one: `file/` with `file_path=/vault/audit/vault-audit.log`
[measured: `vault audit list -detailed`]. A stdout device does not fill, which
a PVC can [inferred]. Enabling the stdout device next to the file one, then
disabling the file one, keeps an audit device live throughout [inferred].
Downtime: one rolling restart of the 3 pods to drop the sidecar and volume. A cheaper middle step is
pointing `auditStorage` off and the audit file into the data PVC; that also
frees 3 slots but lets a log fill the raft volume [inferred]. Not a DB move, but
it is the largest single gain.

### 2. Three apps that need no volume at all: 3 slots, S

- **uptime-kuma**: monitors already live in MariaDB on `mysql.dbaas`
  [measured: `db-config.json` type `mariadb`]. The volume holds that JSON file,
  a 25 MB `error.log`, a 4 KB `kuma.db` last written in May, and empty
  `upload/` and `screenshots/` [measured]. Uptime Kuma 2.5.9 reads
  `UPTIME_KUMA_DB_TYPE`, `_HOSTNAME`, `_PORT`, `_NAME`, `_USERNAME` and
  `_PASSWORD`, the last with a `_FILE` form, and then writes them into
  `data/db-config.json` (`server/setup-database.js` L14-31, L98-110) [source].
  So the data dir stays writable but can be emptyDir: the file is rebuilt at
  every start. Upstream says NFS is not supported (`README.md` L52) [source],
  and Uptime Kuma must survive an NFS outage anyway; emptyDir meets both
  [inferred]. Docker-TLS certs, if ever used, would need a Secret. A password
  change then needs only a pod restart; MySQL roles that Vault rotates keep the
  previous password valid until the next rotation
  (`docs/runbooks/db-credential-rotation.md:41-43`) [source]. Whether
  `uptimekuma` is one of those rotated roles was not checked.
- **learning** (first-party): config says "sqlite for local/dev+tests;
  postgres+asyncpg in the cluster" (`~/code/learning/backend/learn_api/config.py:13-14`)
  but the stack sets `DB_CONNECTION_STRING = sqlite+aiosqlite:////data/learn.db`
  (`stacks/learning/main.tf`) [source]. `learn.db` is 32 KB [measured]. Follow
  `docs/agents/new-app.md` steps 2 and 3 for the DB and role, copy the few rows,
  delete the PVC.
- **aiostreams**: already on shared PG [measured: pod env]. With Postgres,
  `/app/data` keeps only file caches: a downloaded anime database with ETag
  files, ID and scene mappings, the SeaDex dataset, templates, an instance ID
  and `cache/` (`.env.sample` L46-55 at v2.37.0, `anime-database/storage/paths.ts`)
  [source]. The image has no `ls`, so the volume was not read. emptyDir means a
  re-download after each restart and a new instance ID; whether the ID matters
  to Stremio clients was not checked.

### 3. Roundcube: 2 slots, S

`/var/www/html` is the Roundcube tree, plus the `vendor/` dir where
`ROUNDCUBEMAIL_COMPOSER_PLUGINS` installs 3 plugins
(`stacks/mailserver/modules/mailserver/roundcubemail.tf:197-198,225`) [source,
measured]. The image entrypoint copies `/usr/src/roundcubemail` in whenever
`index.php` is missing (roundcubemail-docker `apache/docker-entrypoint.sh`
L38-45) [source], so it needs no persistence. As emptyDir each start re-copies
and re-runs composer, which needs network at start and adds start time
[inferred]. Config comes from env; the DB is on MySQL [source].

The enigma homedir holds PGP keyrings for 2 users [measured]. With
`enigma_multihost = true` the plugin stores keys in the SQL `filestore` table
and syncs them to the homedir, which stays as a local working copy
(`plugins/enigma/config.inc.php.dist` L41-46, `enigma_driver_gnupg.php`
L590-682, added in 1.4) [source]. The homedir can then be emptyDir. Export both
keyrings first; the sync from an existing homedir into the table was not
tested. Both changes free 2. If the DB route is not wanted, a subPath merge of
the two PVCs frees 1.

### 4. Meshcentral files into meshcentral-data: 1 slot, S

Both PVCs mount in the same pod, so a subPath merge has no scheduling cost
[measured]. MeshCentral 1.3.1 accepts `mariaDB`, `mySQL` and `postgres` in place
of NeDB (`meshcentral-config-schema.json` L193-224) [source]. The DB move alone
frees no further slot: the data dir holds the root CA, agent-server, MPS and
web server private keys [measured]. A second step exists: `--dbpushconfigfiles`
with `--loadconfigfromdb <key>` stores config.json and the certs encrypted in
the DB (`meshcentral.js` L209-215, L1429) [source]. Then only user files and
recordings stay on disk, so 2 slots in all, M effort [inferred]. Whether NeDB
files are still created with an external DB was not verified.

### 5. Empty upload volumes: 2 slots, S

`glitchtip-uploads-encrypted` and `health-uploads-encrypted` hold only
`lost+found` [measured]. GlitchTip uses this for uploaded source maps and debug
files; nothing has been uploaded. health (first-party) streams an import to
`UPLOAD_DIR` and does not delete it after import except when the file is too
large (`~/code/health/backend/app/api/ingestion.py:133-147`) [source]; the dir
is empty, so no import has run since the PVC was created [inferred]. For health,
emptyDir works if an import completes before a restart; delete the staged file
after import either way. For GlitchTip, emptyDir loses source maps on restart;
fine while none are uploaded [inferred].

### 6. Non-sensitive remainders to NFS: 2 slots, S

- **freshrss**: on MySQL already; the remainder is PHP config, favicons and
  cache, and its extensions dir is already on NFS
  (`192.168.1.127:/srv/nfs/freshrss/extensions`) [measured]. Class is the
  unencrypted `proxmox-lvm`, so NFS loses nothing at rest [measured].
- **qbittorrent**: config and fastresume files, no DB found, unencrypted class
  [measured]. NFS write patterns of fastresume files are small rewrites
  [inferred].

### 7. Prowlarr to Postgres: 1 slot, M

Prowlarr supports Postgres 14-18 for a main and a log DB, set by
`Prowlarr__Postgres__Host`, `__MainDb`, `__LogDb` and friends
(`src/NzbDrone.Core/Datastore/PostgresOptions.cs` L7-23) [source]. The Servarr
wiki calls migrating an existing SQLite DB "unsupported"
(`prowlarr/postgres-setup.md` L78) [source], so the honest path is a fresh
install and re-entering the indexers [inferred]. The remainder is `config.xml`,
text logs, `asp/` DataProtection keys and definitions
(`PathExtensions.cs` L14-18, L289-294) [source]. The wiki FAQ says `/config`
"MUST be on local storage" because of SQLite on NFS (`prowlarr/faq.md` L310)
[source]; with Postgres no SQLite remains, so NFS is safe [inferred]. Costs two
connection pools on the shared PG.

### 8. n8n: 1 slot, S, with care

n8n already stores workflows and credentials in shared PG [source:
`stacks/n8n/main.tf:211-220`]. The volume's `config` file holds the encryption
key that decrypts every stored credential, and `N8N_ENCRYPTION_KEY` is not set
in the stack [measured]. The env var is authoritative; n8n writes it into
`~/.n8n/config` on first start and refuses to start if file and env disagree
(`packages/core/src/instance-settings/instance-settings.ts` L332-359, tag
`n8n@3.1.0`) [source]. Copy that exact key into Vault and the env first; then
the dir can be emptyDir. Binary data defaults to `filesystem` under
`~/.n8n/storage` (`packages/core/src/binary-data/binary-data.config.ts`
L28-37) [source]; its size here was not measured. Set
`N8N_DEFAULT_BINARY_DATA_MODE=database` so nothing lands there. Community packages in
`nodes/` would need reinstalling after each restart; whether n8n does that by
itself was not verified. Risk: a wrong key makes every stored credential
unreadable [inferred].

### 9. wa-bot: 1 slot, S

First-party. State is one JSON file written by one process
(`~/code/wa-bot/store.go`, "a single JSON file is enough") [source]. It is
on the unencrypted class already [measured]. NFS is fine for a single writer
that writes whole files [inferred]; a Postgres table is the ADR-0001 answer and
costs a code change.

### 10. ntfy: 1 slot, S

Only the auth DB `user.db` is on disk; no message cache is configured
[measured]. ntfy keeps users, ACLs, message cache and web push in Postgres when
`database-url` is set, and `auth-file`, `cache-file` and `web-push-file` must
then be unset (`docs/config.md` L424-436 at v2.37.2) [source]. It arrived as
experimental in v2.18.0 (`docs/releases.md` L631-642) [source]; the v2.37.2 docs
no longer mark it so. Only `attachment-cache-dir` would stay on disk, and it is
not configured [measured]. Users are few; recreate them with `ntfy user add`
rather than port the SQLite rows [inferred]. MySQL is not supported, so this
costs a Postgres pool.

### 11. Possible, low value, or ruled out

- **headscale**: v0.29.7's `config-example.yaml` L195-197 says "using Postgres
  is highly discouraged as it is only supported for legacy reasons. All new
  development, testing and optimisations are done with SQLite in mind"
  [source]. The keys could come from a Secret, since headscale reads an
  existing key file and writes one only when missing (`hscontrol/app.go`
  L1125-1165) [source]. The DB is the blocker, so keep it on block.
- **vaultwarden**: supports `mysql://` and `postgresql://` in `DATABASE_URL`
  (`.env.template` L57-66 at 1.37.5); the wiki calls the SQLite-to-server
  migration itself "unsupported" [source]. MySQL fits: 13 of 80 connections
  and dual-password rotation, so no restart window [measured, source]. The DB move alone frees no slot: 2
  attachments and `rsa_key.*` remain. Attachments are encrypted by the
  Bitwarden client before upload, so on NFS they are ciphertext, but the
  storage rule names passwords as sensitive (`docs/agents/storage-backup.md:7`)
  [source]. The RSA key can be a Secret mounted at `<RSA_KEY_FILENAME>.pem`,
  and `icon_cache` can be emptyDir (`src/config.rs` L521-535, L1701-1703)
  [source]. 1 slot only if the attachments also leave block.
- **rybbit ClickHouse into claude-sessions ClickHouse**: both run
  `clickhouse/clickhouse-server:26.10.3.7` [source]. Rybbit's data is 1.8 MB
  [measured]. One server with two databases frees 1 slot; it couples two apps'
  upgrades and the rybbit event pipeline now carries telemetry for several
  first-party apps [inferred]. M.
- **immich-postgresql into CNPG**: immich supports an existing Postgres 14 to
  19 with pgvector `>=0.7,<0.9` and VectorChord `>=0.3,<2.0` in
  `shared_preload_libraries`, calls it "not officially recommended", expects a
  superuser for its `pg_dumpall` backups, and says the DB should "never [be on]
  a network share" (`docs/docs/administration/postgres-standalone.md` L5-53,
  `docs/docs/install/requirements.md` L39) [source]. TensorChord publishes CNPG
  images with VectorChord (github.com/tensorchord/cloudnative-vectorchord)
  [source]. Live, immich v3.3.6 uses `vchord 0.4.3` and
  `vector 0.8.1`; the shared image `cnpg-postgis-pgvector:18-pgvector0.8.7` has
  `vector` but no `vchord` [measured]. Adding it means a new image and a
  `shared_preload_libraries` change, which is a rolling restart of the shared
  cluster (`docs/agents/databases.md`, pg_prewarm paragraph) [source]. Immich's
  own Postgres runs `shared_buffers=3072MB` (`stacks/immich/main.tf:894`), and
  the shared pool of 2048 MB was already fully used by one tenant in September
  [source]. 1 slot for L effort and a real latency risk to every tenant. Keep
  separate.
- **pushgateway**: one `pushgateway.bin` [measured]. As emptyDir, a restart
  drops the last push of every CronJob until it runs again, which can fire
  staleness alerts [inferred]. Not NFS: monitoring must not depend on NFS
  (`docs/agents/storage-backup.md:49`) [source].

### Unattached, worth acting on

- **broker-sync** (first-party): 7 CronJobs mount the RWO volume, 4 of them
  daily and 2 suspended, so it attaches and detaches about 4 times a day
  [measured: `kubectl get cronjob -n broker-sync`]. Its SQLite dedup and FX
  cache are a natural fit for the existing `pg-wealthfolio-sync` database or a new one
  [inferred]. This removes churn, not a standing slot.
- **storage-tempo-0**: no owner found. It and its Released twin are candidates
  for deletion after Viktor confirms Tempo is gone.
- **Rollback copies** `pg-cluster-1` (35Gi) and `data-mysql-standalone-0`
  (30Gi): no slots, 65 GiB provisioned. Both cutovers were on 2026-10-15, and
  both copies have had no pod since 2026-10-19.
- **trek**: data and uploads in one pod, a subPath merge halves its attach work.
- **privatebin**: a Sablier app; its `Database` model on MySQL or Postgres is
  stable and tested with both, and keeps the traffic limiter and salt in a
  `config` table (`cfg/conf.sample.php` L212-234, `lib/Data/Database.php`
  L368-411 at 2.1.1) [source]. The PVC then goes, so a wake attaches nothing.
- **stirling-pdf**: external Postgres is documented as an Enterprise feature
  (`settings.yml.template` L220-228 at 3.3.0, docs.stirlingpdf.com) [source].
  Keep the H2 file on block.
- **grampsweb**: if revived, the tree via the SharedPostgreSQL addon,
  `USER_DB_URI` and `SEARCH_INDEX_DB_URI` can all point at Postgres
  (grampsweb.org install_setup/postgres; gramps-web-api `config.py` L43)
  [source], leaving only caches and media.
- **Dormant for months**: grampsweb (since 2026-03-14), actualbudget-emo (since
  2026-05-13), instagram-poster (since 2026-06-24), openclaw x3 and repowise
  (since 2026-09-27), paperless-ai (since 2026-10-12). Each is a decision for
  Viktor, not a slot.

### Apps that could share one PVC

Only same-pod pairs are free of scheduling cost: roundcube html and enigma,
meshcentral data and files, vault audit and data, trek data and uploads,
openclaw data and home [measured]. Cross-pod sharing of an RWO volume pins the
pods to one node; `stacks/renovate/main.tf:342-344` rejected that for the two
renovate caches [source].

## Constraints that shape the verdicts

- **Connection budget.** The shared Postgres has 127 of 200 connections in use
  [measured]. ADR-0001 apps take 5 each plus 1 per migrate run
  (`docs/agents/new-app.md`, "Connection budget") [source]; third-party apps
  default higher. MySQL has 13 of 80 [measured]. Apps that support both should
  go to MySQL, which also rotates with a retained password and no restart
  window [source: `docs/runbooks/db-credential-rotation.md:41-43`].
- **Rotation restarts.** A Postgres role rotation restarts the app through
  Reloader; apps that read the password once at start need that opt-in
  [source: same runbook, "Adding a role" step 4].
- **Vault is circular.** DB credentials come from Vault, so Vault's storage
  cannot be the shared PG [inferred].
- **NFS is unencrypted** and is unsafe for embedded DBs; every past corruption
  here was SQLite on NFS (memory #205, #478) [source]. 55 of the 83 PVCs are
  encrypted, 49 on `enc` and 6 on `sas` [measured].

## Mismatches between docs and the live cluster

- `docs/agents/databases.md` "MySQL" table says `mysql-v26` runs
  `mysql:26.7.0` on `proxmox-lvm-encrypted`. Live: the pod runs
  `docker.io/library/mysql:26.10.0` and `data-mysql-v26-0` is on
  `proxmox-lvm-encrypted-sas` [measured].
- `docs/architecture/databases.md:52` says `pg-cluster-v18` is "primary + 2
  replicas". Live: 2 instances, matching `docs/agents/databases.md` [measured].
- Nextcloud's data dir still holds 4 SQLite files from before the MySQL move,
  a 27 MB SQL dump and a 167 MB rotated log, about 370 MB in all [measured].

## Open questions

- Is Linkwarden archiving switched on? The volume has been empty since
  2026-08-15 while the stack comment says archives were being regenerated.
- What is on `aiostreams-data-proxmox`? It needs a debug container to read,
  which this note did not start.
- Who owns `storage-tempo-0`? No Terraform or workload references it.
- Are the PG16 and MySQL 8.4 rollback copies still wanted?
- The renovate cache attaches 28 times a day. Is the cache worth that churn
  against emptyDir and a cold run? Not measured here.
- How long does Loki keep `job=vault-audit` lines? That becomes the audit
  retention if Vault audits to stdout.
- Does Roundcube's enigma sync an existing homedir into the `filestore` table
  on first start, or must keys be re-imported?
- headscale, matrix, loki and wa-bot images have no shell, so their volumes were
  not listed [measured: exec failed].

## Sources

Repo: `stacks/<app>/main.tf` for each row; `docs/agents/databases.md`;
`docs/agents/new-app.md`; `docs/agents/storage-backup.md`;
`docs/runbooks/db-credential-rotation.md`; `stacks/vault/main.tf:1139-1163`;
`docs/architecture/storage.md`. First-party code: `~/code/learning`,
`~/code/health`, `~/code/wa-bot`, `~/code/broker-sync`,
`~/code/Plotting-Your-Dream-Book` (Anca's, `better-sqlite3`).

First-party apps among the 83: learning, health, tripit, wa-bot,
broker-sync, instagram-poster, android-emulator, chrome-service browser, and
plotting-book (Anca's).

Upstream, each at the version Terraform runs, read on GitHub at the tag or in
the official docs:

| App, version | Where |
|---|---|
| Vaultwarden 1.37.5 | `.env.template` L57-66; `src/config.rs` L521-535, L1701-1703 |
| Headscale v0.29.7 | `config-example.yaml` L195-197; `hscontrol/app.go` L1125-1165 |
| MeshCentral 1.3.1 | `meshcentral-config-schema.json` L193-224; `meshcentral.js` L209-215, L1429 |
| ntfy v2.37.2 | `docs/config.md` L424-436; `docs/releases.md` L631-642 |
| FreshRSS 1.30.4 | `README.md` L70; `lib/Minz/ModelPdo.php` L73 |
| Prowlarr 2.7.0 | `src/NzbDrone.Core/Datastore/PostgresOptions.cs` L7-23; Servarr wiki `prowlarr/postgres-setup.md`, `prowlarr/faq.md` L310 |
| Listenarr 0.2.47 | `listenarr.api/Extensions/ServiceRegistrationExtensions.cs` L215-230 |
| Uptime Kuma 2.5.9 | `server/setup-database.js` L14-31, L98-110, L182; `README.md` L52 |
| n8n 3.1.0 | `packages/core/src/instance-settings/instance-settings.ts` L53-61, L332-359; `packages/core/src/binary-data/binary-data.config.ts` |
| Roundcube 1.7.6 image | roundcubemail-docker `apache/docker-entrypoint.sh` L38-45, L205-207; `plugins/enigma/config.inc.php.dist` L41-46 |
| Forgejo 17.0.1 | `custom/conf/app.example.ini` L1482-1581; forgejo.org/docs/v17.0/admin/installation/docker/ |
| Immich v3.3.6 | `docs/docs/administration/postgres-standalone.md`; `docs/docs/install/requirements.md` L39 |
| Audiobookshelf 2.37.2 | `server/Database.js` L177, L228-229 |
| Navidrome 0.64.2 | `db/db.go` L12, L27; PR #2821 |
| Calibre-Web-Automated v4.0.8 | `cps/ub.py` L1291-1305; `scripts/cwa_db.py`; `README.md` L89-112, `NETWORK_SHARE_MODE` |
| Frigate 0.18.2 | `frigate/app.py` L260-272; `docs/docs/configuration/advanced/system.md` L135-153 |
| Actual 26.11.0 | `packages/sync-server/src/db.js` L1; `account-db.js` L19 |
| Wealthfolio 3.12.0 | `crates/storage-sqlite`; no Postgres path in the tree |
| Tuwunel v1.9.4 | `src/database/Cargo.toml` L64; `tuwunel-example.toml` L40-43 |
| OwnTracks Recorder 1.0.4 | `Makefile` L22-23; `doc/STORE.md` |
| TorrServer MatriX.150 | `server/settings/settings.go` L91-93, L154-162, L309 |
| PrivateBin 2.1.1 | `cfg/conf.sample.php` L197-234; `doc/Installation.md` L216-217 |
| Stirling-PDF 3.3.0 | `settings.yml.template` L220-228; `DatabaseConfig.java` L70-73 |
| Gramps Web 26.11.2 | grampsweb.org/install_setup/postgres/; gramps-web-api `config.py` L43-89 |
| TREK 5.1.1 | `server/src/db/connection.ts` L1; `.env.example` L55 |
| Open DroneLog 3.3.2 | `src-tauri/Cargo.toml` L42-43; `src-tauri/src/database.rs` L51-68 |
| AIOStreams v2.37.0 | `.env.sample` L46-55 |
| Paperless-ngx 3.4.2 | `src/paperless/settings/__init__.py` L86-112, L742; `docs/setup.md` L155-160 |
| Loki 3.7 | `docs/sources/operations/storage/filesystem.md`; `tsdb.md` L9, L47-48 |
| GlitchTip 6.2.6, Linkwarden 2.16.3 | glitchtip-backend `glitchtip/settings.py` L27-39; linkwarden `.env.sample` L7-15, L84-90 |
| novelapp 1.1.6 | image `package.json` and Prisma schema, `provider = "sqlite"`; no public repo found |
| Vault | developer.hashicorp.com/vault/docs/audit/file and /vault/docs/audit |

The Vaultwarden and Servarr wiki pages and the Roundcube image repo were read on
master, not at a tag; the image Dockerfile pins 1.7.6.
