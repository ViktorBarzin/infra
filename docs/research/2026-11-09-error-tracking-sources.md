# Error and crash tracking: comparison for the homelab, plus analytics gaps

Researched 2026-11-09 against GitHub/GitLab source at the tagged release, project docs, and Docker Hub. Companion to `analytics-research.md` in the same directory; analytics findings there are not repeated. Anything not confirmed against a primary source is marked unverified.

## Part A summary

Y = in the free self-hosted build, P = partial, N = no, ? = unverified.

| Tool | License | Latest | Services (self-host) | Documented minimum | k8s / Helm | Accepts Sentry SDKs | Android JVM / NDK / ANR | Source maps | ProGuard/R8 | Alerts | Releases | Tracing | Replay on error | OIDC in free self-host | Retention config |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Sentry self-hosted | FSL-1.1-Apache-2.0 | 26.10.1, 2026-10-29 | 53 compose services (28 in `errors-only`) incl. Kafka, ClickHouse, Postgres, Redis, Memcached, SeaweedFS, Snuba, Relay, Symbolicator | 4 CPU / 16 GB + 16 GB swap / 20 GB disk (32 GB recommended); `errors-only` 2 CPU / ~7 GB | No official support; community chart `sentry-kubernetes/charts` 35.0.0 (app 26.10.1, 2026-10-29) | Y (native) | Y / Y / Y | Y | Y | Y | Y | Y (feature-complete) | Y | P: SAML2, Google, GitHub built in; OIDC via third-party `sentry-auth-oidc` plugin | `SENTRY_EVENT_RETENTION_DAYS=90` |
| GlitchTip | MIT | 6.2.6, 2026-08-07 (master active 2026-11-06) | Web + worker (can be one process) + Postgres 14+; Valkey optional | 256 MB RAM all-in-one, 512 MB recommended; ~30 GB per 1M events/month | Official Helm chart 9.1.1 (2026-10-15) | Y (this is its client model) | Y / P (minidump endpoint) / ? | Y | Y (v6.2.6 code) | Y (email, webhook, Discord, Slack-compatible, Google Chat, ntfy, Teams, Zulip, Feishu) | Y | P (transactions) | N | Y (django-allauth generic OIDC) | `GLITCHTIP_RETENTION_DAYS` default 90, per-type overrides |
| Bugsink | PolyForm Shield 1.0.0 | 2.6.3, 2026-11-06 | One app + snappea worker; SQLite default, MySQL/Postgres optional | Not documented | User-contributed manifests; Helm "work in progress" | Y | Y / experimental (`FEATURE_MINIDUMPS`) / ? | Y | N (not found) | Y (email, Slack, Mattermost, Discord, Teams, Telegram, Google Chat, webhook) | Y | N (by design) | N | N (local accounts only) | Count-based per project; optional `MAX_EVENT_AGE_DAYS` |
| PostHog hobby error tracking | MIT outside `ee/` | Continuous (hobby compose changed 2026-11-08) | Part of the 47-service hobby stack (`ingestion-error-tracking`, `cymbal`, `cymbal-resolution`) | 4 vCPU / 16 GB / 30 GB+ (whole stack) | Helm sunset | N (PostHog SDKs) ? | Y / ? / ? | Y | Y (Android "upload-mappings") | ? | Y | N | Y (issue shows session replay) | N | No TTL on events table; replay 30 d |
| Rybbit 2.9.2 errors | AGPL-3.0 | v2.9.2, 2026-10-24 | Same as analytics | Same | Same | N | N | N | N | N (not documented) | N | N | ? (replay exists separately) | N | n/a |
| Swetrix CE errors | AGPL-3.0 | v5.5.3, 2026-11-06 | Same as analytics | Same | Same | N | N | N (not documented) | N | N in CE (alerts are Cloud only) | N | N | ? | Y (OIDC, per earlier report) | ? |
| Umami 3.4.1 / OpenPanel | MIT / AGPL-3.0 | n/a | No error tracking in either codebase | | | N | N | N | N | N | N | N | N | n/a | n/a |
| SigNoz / HyperDX (OTel) | SigNoz mixed (NOASSERTION); HyperDX MIT | SigNoz v0.149.0 2026-11-04; HyperDX 2.43.1 2026-11-01 | ClickHouse-based | | | N | N (no Android crash reporter found) | ? | N | Y | ? | Y | HyperDX ? | | |

SigNoz groups exceptions from OTel span events by service, type and message, and I found no Android crash SDK or mobile symbolication for either. They fail the "frontend + Android crash grouping" bar, so I did not go further.

### SDK coverage for our stack

| Tool | Browser JS / React | SvelteKit | TanStack Start | Python | Go | Node | Bun | Android Kotlin |
|---|---|---|---|---|---|---|---|---|
| Sentry (self-hosted, GlitchTip, Bugsink all use these) | Y | Y | Y (guide exists) | Y | Y | Y | Y (guide exists) | Y (Gradle plugin uploads mappings; ANR >5 s; NDK) |
| PostHog | Y | Y | via React | Y | Y | Y | ? | Y (JVM exceptions via uncaught handler, needs SDK 3.32.0+ for remote config) |
| Rybbit | script `trackErrors` / `captureError` | via script | via script | N | N | N | N | N |
| Swetrix | script / npm `swetrix` | via script | via script | N | N | N | N | N |

GlitchTip and Bugsink caveats on Sentry SDKs: GlitchTip does not implement release-health sessions (issue #206, the advice is to disable session tracking in the SDK), and has no replay. Bugsink says to keep `traces_sample_rate=0` because it ignores traces.

## Per-tool notes

### Sentry self-hosted

- License is FSL-1.1-Apache-2.0. Permitted Purpose is anything except a Competing Use, and "internal use and access" is listed explicitly; each release converts to Apache 2.0 after two years. Self-hosting for our own apps is within the grant. [LICENSE.md](https://github.com/getsentry/sentry/blob/master/LICENSE.md), [develop.sentry.dev/self-hosted](https://develop.sentry.dev/self-hosted/)
- Latest 26.10.1 (2026-10-29), monthly cadence. GitHub releases API.
- Resources: docs say 4 CPU, 16 GB RAM + 16 GB swap, 20 GB disk, 32 GB recommended. `install/_min-requirements.sh` enforces 14000 MB / 4 CPU, or 7000 MB / 2 CPU with `COMPOSE_PROFILES=errors-only`. [_min-requirements.sh](https://github.com/getsentry/self-hosted/blob/master/install/_min-requirements.sh)
- `errors-only` keeps Issues, Alerts, Integrations, Dashboards, Releases, Errors and drops Traces, Profiles, Replays, User Feedback, Crons, Application Metrics. So replay-on-error needs the full profile. [errors-only](https://develop.sentry.dev/self-hosted/optional-features/errors-only/)
- `docker-compose.yml` defines 53 services; 28 run in `errors-only`. Includes Kafka, ClickHouse, Postgres + pgbouncer, Redis, Memcached, SeaweedFS, Snuba consumers, Relay, Symbolicator, taskbroker/workers. `.env` default image tag is `nightly`, `SENTRY_EVENT_RETENTION_DAYS=90`. [docker-compose.yml](https://github.com/getsentry/self-hosted/blob/master/docker-compose.yml), [.env](https://github.com/getsentry/self-hosted/blob/master/.env)
- Kubernetes: the self-hosted docs give no guidance for scaling or Kubernetes. Community chart `sentry-kubernetes/charts` is at sentry-v35.0.0 with appVersion 26.10.1 (2026-10-29).
- Missing vs SaaS: billing, spike protection, Seer/AI features, data-location choice; limited mobile stack-trace resolution (no Android system symbols redistributed, no built-in iOS symbol repos). [develop.sentry.dev/self-hosted](https://develop.sentry.dev/self-hosted/)
- SSO: SAML2 built in since 20.6.0, Google since 9.1, GitHub since 10; no plan gate mentioned. "Once you enable SSO, this will be the only way to login." OIDC is not built in; `siemens/sentry-auth-oidc` (Apache-2.0, v9.1.1, 2026-04-22) would need a custom image. Authentik can also be a SAML IdP, which avoids the plugin. [SSO](https://develop.sentry.dev/self-hosted/sso/)
- Android: automatic error reporting, ANR when blocked over five seconds, NDK, release health, Gradle plugin uploads ProGuard mappings, replay optional (`onErrorSampleRate 1.0` in sample). [Android features](https://docs.sentry.io/platforms/android/features/), [Android](https://docs.sentry.io/platforms/android/)

### GlitchTip

- MIT. Latest tag v6.2.6 (2026-08-07); Docker Hub `glitchtip/glitchtip:6.2.6` pushed 2026-08-08; master commits continue to 2026-11-06. GitLab API.
- Postgres 14+ plus "a single service"; Valkey/Redis 7+ optional (Postgres then handles queue, cache, sessions). 256 MB RAM all-in-one minimum, 512 MB recommended, ~30 GB disk per 1M events/month. Official Helm chart (glitchtip-helm-chart 9.1.1, 2026-10-15). [install](https://glitchtip.com/documentation/install)
- Retention: `GLITCHTIP_RETENTION_DAYS` (default 90, legacy `GLITCHTIP_MAX_EVENT_LIFE_DAYS`), per-type `GLITCHTIP_EVENT_RETENTION_DAYS`, `GLITCHTIP_TRANSACTION_RETENTION_DAYS`; `GLITCHTIP_EVENT_HOT_DAYS` 30 with optional DuckDB/Parquet cold archive. `glitchtip/settings.py` at v6.2.6 lines 195-222.
- OIDC: django-allauth social apps include GitHub, Google, Microsoft, Okta and generic OpenID Connect. [install](https://glitchtip.com/documentation/install)
- Android: `apps/difs/tasks.py` at v6.2.6 imports `symbolic` and filters DIFs by `symbol_type="proguard"`, so ProGuard deobfuscation and native debug files are in the release. `apps/event_ingest/minidump_event.py` exists at v6.2.6. ANR display not checked.
- Alerts at v6.2.6: email, Slack-compatible webhook, Discord, Google Chat, ntfy, Teams, Zulip, Feishu (`apps/alerts/constants.py`). Source maps via the beta CLI or sentry-cli. [error tracking](https://glitchtip.com/documentation/error-tracking)
- Also ships performance (transactions), uptime monitoring, logs, an OTLP ingest module (`otlp.py`) and an MCP server.
- Not implemented: release-health sessions ([issue #206](https://gitlab.com/glitchtip/glitchtip-backend/-/issues/206)); session replay (no replay ingest found in source; third-party [Better Stack comparison](https://betterstack.com/community/comparisons/sentry-vs-glitchtip.md) agrees).

### Bugsink

- PolyForm Shield 1.0.0 for the main code, BSD-3 for the vendored `sentry/` directory. Shield allows any use except providing a product that competes with Bugsink, so internal self-hosting is fine. Not OSI open source. [LICENSE](https://github.com/bugsink/bugsink/blob/main/LICENSE)
- Latest 2.6.3 (2026-11-06); Docker Hub `bugsink/bugsink` updated same day.
- One app process plus the snappea worker (`SNAPPEA_NUM_WORKERS`, 2 to 4 recommended); SQLite at `/data/db.sqlite3` is the default and called production-ready, MySQL/Postgres via `DATABASE_URL`. No documented CPU/RAM minimum. [settings](https://www.bugsink.com/docs/settings/), [installation](https://www.bugsink.com/docs/installation/)
- Kubernetes: user-contributed manifests "not official guides"; Helm charts "work in progress". [installation](https://www.bugsink.com/docs/installation/)
- Scope: "Bugsink intentionally focuses only on error events" and does not support traces. [SDK recommendations](https://www.bugsink.com/docs/sdk-recommendations/)
- Rate limits default 1,000 per project per 5 minutes, 5,000 per hour, 1,000,000 per month. Retention is count-based (`MAX_RETENTION_PER_PROJECT_EVENT_COUNT`, `MAX_RETENTION_EVENT_COUNT`), plus optional `MAX_EVENT_AGE_DAYS`. [settings](https://www.bugsink.com/docs/settings/)
- Auth: local users, registration controls, no SSO setting and no `REMOTE_USER` handling in the code (GitHub code search: 0 hits for oidc, allauth, social_django, REMOTE_USER).
- Minidumps experimental behind `FEATURE_MINIDUMPS`; debug files assembled for sentry-cli. ProGuard does not appear in the changelog, only in the event JSON schema, so minified Kotlin stack traces would likely stay obfuscated. [CHANGELOG](https://github.com/bugsink/bugsink/blob/main/CHANGELOG.md)
- Alerts: Slack, Mattermost, Discord, Teams, Telegram, Google Chat, custom webhook, email (hourly cap default 60). CHANGELOG.

### PostHog error tracking in hobby

- The hobby compose runs `ingestion-error-tracking` and `cymbal` + `cymbal-resolution` (`ghcr.io/posthog/posthog/cymbal:master`, the symbolication service), so error tracking is part of the free self-host stack. [docker-compose.hobby.yml](https://github.com/PostHog/posthog/blob/master/docker-compose.hobby.yml)
- Install list covers Web, React, SvelteKit, Node.js, Python, Go, Android, Kotlin Multiplatform and others. [installation](https://posthog.com/docs/error-tracking/installation)
- Android: `errorTrackingConfig.autoCapture = true` wraps the uncaught-exception handler; uploading R8/ProGuard mappings is a required step; NDK and ANR are not mentioned. [Android](https://posthog.com/docs/error-tracking/installation/android)
- Issues show the affected user's session replay, events and properties; release tagging; assignment. [error tracking](https://posthog.com/docs/error-tracking)
- Exceptions are `$exception` events, so retention is the events table (no TTL, see Part B 3). Replay stays capped at 30 days.
- Unverified: alert channels for error issues in hobby, custom grouping rules, Sentry SDK ingestion.

### Rybbit 2.9.2 errors

- Browser-only. Enable per site in the dashboard or with `trackErrors: true`; manual `rybbit.captureError()`. Groups errors by message, shows stack traces when the browser provides them, counts occurrences and affected sessions. "On Rybbit Cloud, error tracking needs a Standard plan or higher"; the v2.9.2 source has the errors pages and `getErrorEvents/Names/Bucketed` endpoints with no self-host gate found. No source maps, alerts, releases or backend SDKs documented. [errors](https://rybbit.com/docs/behavior-analytics/errors), source tree at v2.9.2.

### Swetrix CE errors

- Browser-only via script or the `swetrix` npm package. Grouped by signature with occurrence counts, affected users, last seen; stack traces up to 64,000 characters; resolved status and regression detection. [error tracking](https://swetrix.com/docs/error-tracking)
- README Cloud vs CE table: errors included in CE; "Alerts & notifications" (email, Slack, Telegram, Discord, webhook, web push) not included in CE. The README contradicts itself on replay (feature list says Cloud, table says CE with S3). [README](https://github.com/Swetrix/swetrix/blob/main/README.md)

### Umami 3.4.1 and OpenPanel

No error-tracking feature: no error routes or queries in the Umami v3.4.1 tree or OpenPanel main tree (file-tree search).

## Part A takeaway: the two ways

| Option | What you get | What you give up |
|---|---|---|
| Analytics with built-in errors: PostHog hobby | One SDK per app, error issue linked to replay and person, Android JVM exceptions with R8 mappings | Python/Go/Node all covered, but NDK/ANR undocumented; 1 project; 47 services and 16 GB; officially unsupported |
| Analytics with built-in errors: Rybbit or Swetrix CE | Browser JS errors next to pageviews | No backend, no Android, no source maps; Swetrix CE has no alerts |
| Separate tool: GlitchTip | Sentry SDKs everywhere incl. ProGuard and minidumps, OIDC with Authentik, official Helm, Postgres-only, 512 MB | No replay, no release-health sessions; tracing basic |
| Separate tool: Sentry self-hosted | Full feature set incl. replay-on-error, ANR, NDK | 16 GB+ (7 GB errors-only), 53 containers, no official k8s, OIDC via plugin or SAML |
| Separate tool: Bugsink | Smallest footprint, SQLite | No ProGuard, no SSO, no tracing, PolyForm Shield, Helm WIP |

My read: GlitchTip is the separate-tool fit for this cluster (Authentik OIDC, official Helm chart, shared Postgres, all our SDKs via Sentry clients). Built-in error tracking only covers every client type in PostHog.

## Part B

1. Rybbit, one site across many hostnames. Yes. In v2.9.2 `/api/track` is a public CORS path (`server/src/lib/cors.ts`, `origin: true` for public paths), and `resolveTrackingRequest` returns null only when the site id is unknown (`trackingRequest.ts`). The ingest pipeline checks a denylist (`excludedHostnames` in `siteExclusionDecision`), not an allowlist; `site.domain` is not consulted on ingest. Each event keeps `payload.hostname`, and `hostname` is a filter in `shared/src/filters.ts`. So all first-party apps can share one site and one user space and still be split by hostname.
2. Umami 3.4.1 identity is per website. `session_link` has primary key `(website_id, distinct_id, session_id)` (`prisma/schema.prisma` lines 87-96) and `getLinkedSessionIds(websiteId, distinctId)` filters on both. Funnels (`getFunnel.ts`) and retention (`getRetention.ts`) count `distinct session_id`, not distinct id. Umami's session id is `uuid(websiteId, ip, userAgent, salt, distinctId)` with the salt rotating monthly by default (`SALT_ROTATION`, `send/route.ts` line 156-162), so a "session" in these reports is roughly one device per website per month. A user on two devices counts twice, and a returning visitor gets a new session id each month.
3. PostHog hobby.
   - Retention: the sharded events table SQL has no row TTL. The only TTLs in `posthog/models/event/sql.py` are a 60-day TTL on temporary properties in the JSON events table and 9 days on the auxiliary `events_recent` table. Events are kept until you delete them. Replay is 30 days (already verified). Redpanda log retention is set to 1 hour in hobby.
   - Volume limits: none in the compose or self-host docs. The docs flowchart asks whether you expect more than 300k events, 1k recordings or 300k flag calls, as a prompt to consider Cloud. [self-host](https://posthog.com/docs/self-host)
   - Services: 47 in `docker-compose.hobby.yml` (last changed 2026-11-08). Yes to Kafka (it is Redpanda v25.1.9, plus ZooKeeper 3.7.0), Temporal (`temporalio/auto-setup:1.26.2`, admin-tools, UI 2.47.2, a Django worker), and SeaweedFS 4.29 (both `seaweedfs` and `objectstorage`, which replaced MinIO). Full list: db, redis7, valkey, clickhouse, zookeeper, kafka, worker, web, plugins, ingestion-general, ingestion-sessionreplay, recording-api, ingestion-error-tracking, ingestion-logs, ingestion-traces, proxy, objectstorage, seaweedfs, browserless, asyncmigrationscheck, temporal, temporal-admin-tools, temporal-ui, temporal-django-worker, capture, capture-ai, capture-logs, replay-capture, property-defs-rs, property-defs-ai, livestream, personhog-replica, personhog-router, personhog-router-leader, personhog-leader, personhog-writer, personhog-identity, personhog-publisher, personhog-changelog-relay, etcd, personhog-etcd-init, personhog-tables-ready, feature-flags, hypercache-server, kafka-init, cymbal, cymbal-resolution.
4. Official live demos (all returned HTTP 200 on 2026-11-09):

| Tool | Demo |
|---|---|
| Rybbit | https://demo.rybbit.com/81 (linked from rybbit.com) |
| Umami | https://cloud.umami.is/share/LGazGOecbDtaIwDr/umami.is (README "Try demo") |
| Swetrix | https://swetrix.com/demo (README) |
| OpenPanel | https://demo.openpanel.dev (official domain, page title "Projects, OpenPanel.dev"; not linked from the homepage HTML) |
| Sentry | https://sandbox.sentry.io/ (linked from sentry.io) |
| PostHog | No public sandbox found; https://posthog.com/demo is a marketing page |
| GlitchTip | None found |
| Bugsink | None found |

## Verified / unverified

Verified against source or official docs: every license line; all version numbers and dates; Sentry requirements, profiles, service count, retention default, SSO list, self-host gaps; GlitchTip requirements, Helm, OIDC, retention settings, ProGuard/DIF and minidump code in v6.2.6, alert types; Bugsink license, scope, DB, limits, retention, alerts, minidump flag, no SSO code; PostHog hobby services, error-tracking services, no events TTL, Android autoCapture and mappings; Rybbit errors scope and the absence of a domain allowlist; Swetrix CE alert exclusion; Umami identity scope, funnel/retention counting, session id formula; demo URLs.

Unverified: GlitchTip ANR display and v6.2.6 Slack-native alert type (master has it, v6.2.6 has the Slack-compatible webhook); Bugsink ProGuard (absence inferred from changelog and code search); Bugsink resource needs; PostHog error alerts, grouping rules, NDK/ANR, Bun; whether PostHog ingests Sentry SDK payloads; Rybbit and Swetrix links from an error to its replay; HyperDX error grouping; SigNoz/HyperDX Android (no evidence found, not proven absent).
