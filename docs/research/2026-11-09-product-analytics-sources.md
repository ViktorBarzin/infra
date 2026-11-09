# Self-hostable product analytics: comparison for the homelab

Researched 2026-11-09. Release and activity numbers come from the GitHub API on that date ("commits 90d" counts commits on the default branch since 2026-08-11, capped at 100 by the query, so "100" means "100 or more"). Feature claims come from each project's own docs or source, cited per section. Anything I could not confirm against a primary source is marked **unverified**.

Requirements recap: product events (named events per user, funnels, retention, cohorts, journeys), web traffic, web session replay; clients in SvelteKit, TanStack Start/React, Python, Go, Bun/Node, native Android and Android TV (Kotlin); Authentik user id plus anonymous visitors with anonymous-to-identified merge; 10 to 15 apps on one instance; free self-host only.

## Summary: platform

| Tool | License | Latest release | Commits 90d | Storage | Official deploy | Documented minimum | Free self-host status |
|---|---|---|---|---|---|---|---|
| Rybbit | AGPL-3.0 | v2.9.2, 2026-10-24 | 100+ | ClickHouse + Postgres + Redis | docker-compose (no Helm) | 2 GB RAM VPS | Active; some cloud-only pages (below) |
| PostHog (hobby) | MIT outside `ee/`; `ee/` proprietary | Continuous; `posthog/posthog:latest` built 2026-11-09 | 100+ | ClickHouse (custom image), Postgres, Kafka/Redpanda, Valkey, SeaweedFS, Temporal, more | docker-compose hobby script; Helm sunset | 4 vCPU, 16 GB RAM, 30 GB+ disk | "Officially unsupported"; paid features cloud-only; 1 project |
| Umami | MIT | v3.4.1, 2026-10-23 | 100+ | Postgres only (self-host) | Source, Docker image, compose; third-party HelmForge chart | Node 20.19+, Postgres 12.14+ | Active; a few cloud-only extras |
| OpenPanel | AGPL-3.0 | GitHub v3.30.0, 2026-11-06; public images 2.3.0, 2026-08-18 | 100+ | ClickHouse + Postgres + Redis (+ Redpanda from 3.0) | CLI/compose; community Helm chart | 4 GB RAM | v3 images supporter-only ($20/month) |
| Swetrix CE | AGPL-3.0 | v5.5.3, 2026-11-06 | 100+ | ClickHouse + Redis (+ S3 for replays) | docker-compose | **unverified** | Several features cloud-only |
| Plausible CE | AGPL-3.0 | v3.2.1, 2026-05-15 | 100+ (analytics repo) | ClickHouse + Postgres | docker-compose | 2 GB RAM | Twice-yearly releases; funnels and journeys cloud-only |
| Matomo On-Premise | GPL-3.0 | 5.14.2, 2026-10-22 | 100+ | MySQL/MariaDB | PHP app; no official Helm | **unverified** | Funnels, cohorts, flows, replay, SAML are paid plugins |
| OpenReplay CE | AGPL-3.0 core, `ee/` proprietary, some MIT | v1.28.0, 2026-09-25 | 100+ | Postgres, ClickHouse, Kafka, Redis, MinIO (chart deps) | Official Helm charts | 2 vCPU, 8 GB RAM, 50 GB | SSO is EE-only |
| Countly Lite | AGPL-3.0 with modified section 7, "non-commercial" | 24.05.55 / 25.03.58, late Oct 2026 | 100+ | MongoDB | Installer script, Docker | **unverified** | Journeys enterprise-only; funnels/cohorts unclear |
| Jitsu | MIT | only prereleases (2.15.0-beta.108, 2026-11-06) | 100+ | Pipeline into your warehouse (e.g. ClickHouse) | docker-compose | **unverified** | Collection only, no analysis UI |
| RudderStack | Elastic License 2.0 | v1.92.1, 2026-10-28 | 100+ | Pipeline only | Helm/compose | n/a | Not open source; collection only |
| Snowplow | Snowplow Limited Use License for new core releases since 2024-01-08 | main repo last release 22.01 | 1 | Pipeline only | n/a | n/a | Licence excludes it |
| Aptabase | AGPL-3.0 | no GitHub releases | 17 | ClickHouse + Postgres | self-hosting repo | **unverified** | No user identifiers by design |
| Highlight.io | GitHub reports NOASSERTION (not checked further) | docker-v0.5.6, 2025-08-08 | 7 | ClickHouse, Postgres, Kafka, OpenSearch | compose | n/a | Hosted service ended 2026-02-28 (LaunchDarkly) |
| Trench (Frigade) | MIT | trench-js 0.0.17, 2024-12-04 | 0 | ClickHouse + Kafka | compose | n/a | Dormant |

## Summary: features in the free self-hosted edition

Y = documented in the free self-host build. P = partial. N = not available. ? = unverified.

| Tool | Named events | Funnels | Retention | Cohorts / segments | Journeys | Web traffic | Web replay | Feature flags | SQL / export | Native Android SDK | Python / Go / Node server | Anon to identified merge | Dashboard SSO in free self-host | Multiple projects free |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Rybbit 2.9.2 | Y | Y | Y | P (segments, user retention) | Y | Y | Y (no plan gate) | Y (+ experiments) | P (SQL cloud-only; MCP `run_query` on self-host) | N (React Native SDK only; HTTP API) | HTTP API only; Node package broken | Y (retroactive, 30 days) | N (email/password; Google/GitHub cloud-only) | Y (sites per org) |
| PostHog hobby | Y | Y | Y | Y | Y (advanced paths paid) | Y | Y (no download) | Y (no multi-env) | Y (SQL editor) | Y (minSdk 23, replay) | Y / Y / Y | Y | N (SAML and SSO enforcement paid; social login only) | **N: 1 project per org, no extra orgs** |
| Umami 3.4.1 | Y | Y | Y | Y (cohorts since 3.0) | Y | Y | Y (since 3.1.0) | N | P (API, no SQL UI) | N | HTTP `/api/send`, `@umami/node` | P (forward only; pre-identify events stay anonymous) | N | Y (websites, teams) |
| OpenPanel 2.3 public | Y | Y | Y | Y | ? | Y | Y | N (A/B testing) | P (export API) | P (Kotlin SDK "not yet published") | Python, Node, Rust, Ruby, Java; no Go | P (profileId replaces deviceId; no documented backfill) | N (Google/GitHub only) | Y |
| Swetrix CE | Y | Y | ? | ? | Y (user flows) | Y | Y (needs S3) | ? | ? | N | ? | Y (identified users, mechanism unverified) | **Y (OIDC)** | Y |
| Plausible CE | Y (goals) | N | N | N | N | Y | N | N | N | N | HTTP Events API | N | N | Y |
| Matomo | Y | N (paid) | N (Cohorts paid) | P (segments free) | N (Users Flow paid) | Y | N (paid) | N (A/B paid) | Y (MySQL) | Y (BSD SDK) | Python/Node HTTP tracking API | P (User ID) | P (community LoginOIDC, last commit 2024-06) | Y |
| OpenReplay CE | Y | Y | ? | ? | Y | Y | Y (core product) | N | ? | Y (MIT tracker) | ? | P (setUserID) | N (SAML is EE) | Y |
| Countly Lite | Y | ? | ? | ? | N (enterprise) | P | N | P (remote-config plugin) | ? | Y | ? | ? | ? | Y |

## Per-tool notes

### Rybbit (already deployed, v2.9.2)

- Release and activity: v2.9.2 published 2026-10-24, v2.9.0 2026-09-12, v2.8.0 2026-07-27; 100+ commits in 90 days; 13.2k stars (GitHub API, `rybbit-io/rybbit`). The 2.9.2 release note is a Node CVE patch.
- In-cluster: `stacks/rybbit` pins `ghcr.io/rybbit-io/rybbit-backend:v2.9.2`, `rybbit-client:v2.9.2` and `clickhouse/clickhouse-server:26.10.3.7`.
- Self-host vs cloud, from `docs/content/docs/(docs)/self-host-vs-cloud.mdx` (https://rybbit.com/docs/self-host-vs-cloud): self-host has web analytics, API, session replays, funnels, goals, sessions, journeys, users, retention, error tracking, organizations/teams. Self-host does **not** have the Pages view, Web Vitals, email reports, Google Search Console, Bots page, "Custom SQL queries and dashboards", Google/GitHub sign-in, or email (admins create accounts directly). "Custom SQL queries are still available to AI assistants on self-hosted instances through the MCP `run_query` tool."
- Session replay (`feature-guides/session-replay.mdx`): "Self-hosted instances have no plan gate." rrweb-style recording with input masking on by default; 50 MB per-session cap, configurable via `SESSION_REPLAY_MAX_MB_PER_SESSION` ("Not in 2.9.2; applies to edge images and the next release").
- Funnels (`funnels.mdx`): steps can be paths (with wildcards), custom events, outbound links, button clicks, form submits, copy events.
- Segments (`segments.mdx`): saved filter sets, per site or org-wide. Cohorts in the "saved behavioural group" sense are covered only through segments plus the retention view; there is no separate cohort builder.
- Feature flags and experiments (`feature-flags.mdx`, `experiments.mdx`, both present at tag v2.9.2): boolean, multivariant and remote-config flags, client or server runtime.
- Identity (`identify-users.mdx`): `window.rybbit.identify(userId, traits)`. "When a new alias is created ... Rybbit retroactively updates that device's anonymous events from the last 30 days to include the identified user ID." Default anonymous ID is a device fingerprint. Traits limited to 2 KB.
- Server-side (`sdks/node.mdx`, `api/sending-events.mdx`): "The published `@rybbit/node` package (1.0.0) doesn't work with the current API." The documented path is a plain `POST /api/track` with a Bearer API key holding `ingest:write`. Without such a key, requests from server HTTP clients (python-requests, Go's client, node-fetch) are classified as bots. No Python or Go SDK exists; the HTTP API is small enough to wrap.
- Mobile: only `@rybbit/react-native` (`sdks/react-native.mdx`). No native Android/Kotlin SDK (the org has three repos: `rybbit`, `rybbit-js`, `rybbit-node`). Android and Android TV would use `/api/track` directly with an `anonymous_id`; shipping an `ingest:write` key inside an APK is a trade-off to weigh.
- Ad-blocker proxy: a dedicated proxy guide (`proxy-guide/*`: nginx, Caddy, Express, Next.js, Cloudflare Workers, and more).
- Deployment: docker-compose with a setup script (`self-hosting.mdx`); "at least 2GB of RAM". No Helm chart. Already translated to Terraform here.
- SSO: no OIDC for dashboard login. Code search hits for "oidc" are the MCP OAuth server (`server/src/lib/oauth.ts`, `server/src/mcp/wellKnown.ts`), not a login provider. Authentik forward-auth in front of the dashboard would still leave Rybbit's own login behind it.

### PostHog (hobby deploy)

- Self-host page (https://posthog.com/docs/self-host): "You will need something equivalent to a Hetzner VM with 4 vCPU, 16GB RAM, and more than 30GB storage." "New deployments of PostHog's paid open source product using Kubernetes are no longer supported" and it refers to "the sunsetted Helm chart releases". "self-hosted deployments are officially unsupported." "We offer a free Docker Compose deployment under an MIT license." "All paid-plan features are Cloud-only."
- Disclaimer page (https://posthog.com/docs/self-host/open-source/disclaimer): "unlikely to scale past a couple 100ks events without significant effort in scaling". Missing in self-host: insight/dashboard subscriptions, advanced paths, correlation analysis, lifecycle insights, group analytics, data pipelines, more than two alerts, one-year retention; replay download; multi-environment flags and group experiments; most survey options; SSO enforcement and SAML; RBAC; audit logs.
- Project limit, verified in source: `posthog/api/project.py` allows one non-demo project per organization when the `ORGANIZATIONS_PROJECTS` feature is absent ("they can only have one non-demo project"), and `posthog/api/organization.py` `PremiumMultiorganizationPermission` blocks a user who already belongs to an org from creating another ("You must upgrade your PostHog plan to be able to create and manage multiple organizations"). A licence-less hobby instance does not get that feature (inferred from "All paid-plan features are Cloud-only"). For 10 to 15 apps this means one shared project with an `app` property on every event, or separate signups per app.
- Licence (repo `LICENSE`): content under `ee/` uses `ee/LICENSE`; the rest is MIT.
- Footprint: `docker-compose.hobby.yml` on master defines about 45 services, including ClickHouse (custom `ghcr.io/posthog/clickhouse-posthog` image), Kafka plus Zookeeper, Valkey, SeaweedFS object storage, Temporal and its UI/workers, capture, replay-capture, feature-flags, cymbal, several `personhog-*` services and etcd. Images track `:master`/`latest` (latest built 2026-11-09); there are no versioned core releases. The in-cluster ClickHouse 26.10 is unlikely to be reusable because PostHog ships its own ClickHouse image (**unverified** whether stock ClickHouse works).
- Identity (https://posthog.com/docs/product-analytics/identify): "This merges the anonymous person into the identified person, linking the two IDs together." An already-identified user cannot be re-identified to a different distinct ID.
- SDKs: first-party repos for JS, Python, Go, Node, Android (`PostHog/posthog-android`, android-v3.76.1 on 2026-11-06, `MIN_SDK = 23`, session replay supported). Android TV: no issues or docs mention it; it is a standard Android library so it should work on API 23+ TV devices, but this is **unverified**, and replay on Leanback/Compose-for-TV UIs is untested.
- Proxy: PostHog documents reverse-proxy setups (https://posthog.com/docs/advanced/proxy, not fetched this session).

### Umami (v3.4.1)

- MIT; v3.4.1 2026-10-23 (security hotfix: Next.js 16.4.2, Node 22.23.4 base); v3.4.0 2026-09-17 added annotations, MCP, API keys. 40k stars.
- Install (https://umami.is/docs/install): source, Docker Compose, Docker image, or "Kubernetes with a third-party Helm chart maintained by the HelmForge project". Postgres only (v12.14+); the environment-variable reference lists no ClickHouse option for self-host. Fits the shared CNPG cluster directly.
- Features in docs repo (`umami-software/docs`): funnels, goals, journeys, retention, cohorts ("Available since v3.0.0"), segments, attribution, revenue, error tracking, boards, teams. Replays "Available since v3.1.0", per-website toggle with sample rate (default 0.15), mask level, 5-minute default max duration, 30-day retention, separate `recorder.js`. Replay code: `prisma/migrations/19_add_session_replay` (first commit 2026-03-09).
- Identity (`distinct-ids.mdx`, `guides/identify-logged-in-users.mdx`): `data-distinct-id` on the script tag or `umami.identify()`. "Page views and events sent after this call are linked to the ID. The ones sent before it are anonymous." So no retroactive merge; the docs recommend setting the ID at page load to avoid the gap.
- SDKs: browser tracker, `@umami/node`, HTTP `/api/send`, new typed `@umami/api-client`. No native Android SDK.
- Proxy: `bypass-ad-blockers.mdx` and `TRACKER_SCRIPT_NAME` / `COLLECT_API_ENDPOINT` env vars.
- SSO: none (code search for "oidc" returns 0 hits). 2FA exists.

### OpenPanel

- AGPL-3.0; GitHub release v3.30.0 on 2026-11-06, with several builds the same day.
- Surprise: GitHub v3.x releases are "Build of main ... Supporters get it with `openpanel upgrade --supporter`; public releases are published from the self-hosting tag." The `self-hosting` and `v2.3.0` tags both point at a 2026-08-18 commit, and Docker Hub `lindesvard/openpanel-api` has `2`, `2.3`, `2.3.0`, `latest` from 2026-08-18 and no `3` tag. The supporter page (`self-hosting/supporter-access-latest-docker-images.mdx`) says private images cost "$20/month". The free self-host is therefore about three months and one major version behind.
- Features (README): funnels, cohorts, user profiles, session history, session replay (rrweb, opt-in per project, present at tag v2.3.0), A/B testing, notifications, revenue. Retention appears in the dashboard (**unverified** in docs). Journeys/paths not listed (**unverified**).
- Deploy: CLI + compose, "At least 4GB RAM (Redpanda, ClickHouse and Postgres run side by side)". Kubernetes via a "community-maintained Helm chart" (`yashGoyal40/openpanel`, 7 stars, last push 2025-12-24).
- Identity (`how-it-works.mdx`): device ID is a hash of UA, IP, origin and a salt that rotates daily; `profileId` defaults to deviceId until `identify()`. No documented backfill of earlier anonymous events.
- SDKs (`sdks/index.mdx`): web, React, Next, Python, Node/Express, Rust, Ruby, Java, Swift, Kotlin, React Native. The Kotlin page says "This package is not yet published" (`dev.openpanel:openpanel:0.0.1`; `Openpanel-dev/kotlin-sdk` last push 2026-03-03). No Go SDK.
- SSO: Google and GitHub social login only (`self-hosting/social-login.mdx`).
- Proxy: documented (`adblockers.mdx`), built-in for Next.js and WordPress.

### Swetrix Community Edition

- AGPL-3.0; v5.5.3 2026-11-06; 1.2k stars; very active.
- README CE column: core analytics (traffic, events, sessions, funnels, performance, errors) included; "Session replays: Included; requires S3-compatible storage"; "Advanced features (Revenue, Experiments, AI): Cloud only"; alerts and email reports not included; teams limited to direct project invites. The README features list still tags replays "(Cloud)", which conflicts with the table.
- OIDC: `Swetrix/selfhosting/.env.example` has `OIDC_ENABLED`, `OIDC_ONLY_AUTH`, `OIDC_DISCOVERY_URL`, client ID/secret. This is the only candidate with generic OIDC login in the free self-host, so Authentik would work directly.
- Stack: `selfhosting/compose.yaml` runs `swetrix-fe`, `swetrix-api` (v5.5.3), Redis, ClickHouse 26.8, nginx.
- Gaps: no Android SDK found; most small SDK repos (`swetrix-js`, `swetrix-node`, `python-sdk`) are archived, presumably folded into the monorepo (**unverified**). Retention and cohorts not documented (**unverified**). Feature flags listed in "More" alongside cloud-only items (**unverified** for CE).

### Plausible Community Edition

- AGPL-3.0; CE v3.2.1 2026-05-15, v3.2.0 2026-01-26. `plausible/community-edition` README: "At least 2 GB of RAM"; ClickHouse needs SSE 4.2.
- https://plausible.io/self-hosted-web-analytics: "Marketing funnels, user journeys, ecommerce revenue goals, SSO and sites API are not available" in CE; CE is "a long term release published twice per year".
- SSO code lives under `extra/` (`extra/lib/plausible/auth/sso/integration.ex`), which is not part of the AGPL build.
- Web traffic only. No user identity, retention, cohorts or replay. Drop for this use case.

### Matomo On-Premise

- GPL-3.0; 5.14.2 stable 2026-10-22; 6.1.0 alphas nightly.
- Premium plugin list (https://plugins.matomo.org/premium) includes Heatmap & Session Recording, Funnels, Cohorts, Users Flow, Custom Reports, A/B Testing, Login SAML. Prices not shown on the page.
- Free: web analytics, events, goals, segments, User ID, visitor profiles. Native Android SDK `matomo-org/matomo-sdk-android` (BSD-3, last push 2026-09-07).
- OIDC: community `dominik-th/matomo-plugin-LoginOIDC` (GPL-3.0), last push 2024-06-21.
- MySQL/MariaDB; nothing reuses CNPG or ClickHouse. Drop: the product-analytics features are paid.

### OpenReplay Community Edition

- Licence: AGPL-3.0 default, `ee/` proprietary, some MIT directories (repo `LICENSE`). v1.28.0 2026-09-25, v1.27.0 2026-05-05.
- Official Kubernetes deploy via Helm charts in `scripts/helmcharts` (dependencies: ClickHouse, Kafka, MinIO, Postgres, Redis, Vault). Docs: "requires 2 vCPUs, 8 GB of RAM, 50 GB of storage"; multi-node clusters need "RWX PVC with user id 1001 RW permission".
- Product analytics docs: trends, funnels, journeys, heatmaps, dashboards, web analytics, monitors. Retention and cohorts not listed.
- SSO: "Single-Sign-On (via SAML2) is available on OpenReplay Enterprise Edition only."
- Native Android tracker (`openreplay/android-tracker`, MIT, active 2026-10-29) with `setUserID`.
- Strong on replay, weak on product analytics depth and server-side events (no server SDKs found, **unverified**). Its own nginx ingress chart would need adapting to Traefik.

### Countly Lite

- README: "Free to use under an open-source, non-commercial license"; licence "AGPL-3.0 with modified Section 7".
- https://countly.com/lite lists "A/B testing, cohorts, funnels, retention" as Lite plugins, but the open-source repo's `plugins/` directory has no funnels, cohorts or retention plugin (it has `views`, `web`, `remote-config`, `slipping-away-users`, `crashes`, `push`). I could not reconcile these; treat as **unverified**. Journeys are listed under the full platform only.
- MongoDB backend, which this cluster does not run. Drop.

### Pipelines plus DIY (Jitsu, RudderStack, Snowplow, ClickHouse + Grafana)

- Jitsu (MIT): Segment-compatible collection into ClickHouse or other destinations; every release in the last 30 is a prerelease. No analysis UI, no replay. A Jitsu or plain HTTP collector into the existing ClickHouse 26.10 with Grafana dashboards is possible, but funnels, retention and journeys would be hand-written SQL, and replay would need another tool.
- RudderStack server is Elastic License 2.0 (repo `LICENSE`), so source-available, collection only.
- Snowplow: "As of January 8, 2024, Snowplow introduced the Snowplow Limited Use License Agreement" for new core releases (repo README). Excluded.

### Dropped

- Aptabase: README says it collects "minimal usage data without using unique identifiers", which rules out per-user analytics and identity merge. No GitHub releases; 17 commits in 90 days.
- Highlight.io: hosted service scheduled to end 2026-02-28 after the LaunchDarkly acquisition (https://www.highlight.io/blog/launchdarkly-migration); repo has 7 commits in 90 days and last docker release 2025-08-08. Also an observability tool rather than product analytics.
- Trench (Frigade): last release 2024-12-04, no commits in 90 days.
- June: shut down after its 2025 acquisition by Amplitude (from memory, **unverified** this session); it was never self-hostable.

## Verified vs unverified

Verified against primary sources this session: all release dates, licences and commit counts (GitHub API); Rybbit features, gaps, identity backfill, Node SDK breakage and mobile SDK list (Rybbit docs source in repo); PostHog resources, scale caveat, Helm sunset, paid-feature list, identity merge (posthog.com) and the one-project/one-org limit (PostHog source); PostHog Android minSdk 23; Umami replays, cohorts, identity behaviour, Postgres-only install (Umami docs repo); OpenPanel supporter-only v3 images (release notes, tags, Docker Hub), unpublished Kotlin SDK, social-login-only SSO; Swetrix CE feature table and OIDC env vars; Plausible CE exclusions; Matomo premium plugin list; OpenReplay resources, Helm deploy, SAML EE-only; Countly README licence and plugin directory; Snowplow and RudderStack licences.

Unverified: PostHog or Rybbit behaviour on Android TV specifically; whether PostHog runs on stock ClickHouse; OpenPanel retention and journeys; Swetrix retention, cohorts, CE feature flags and SDK coverage; Countly Lite funnels/cohorts (sources conflict); OpenReplay retention and server-side ingestion; resource minimums for Swetrix, Matomo, Countly; June's status; PostHog reverse-proxy page contents (not fetched).

## Shortlist

1. **Rybbit (keep and adopt).** It is already deployed on the in-cluster ClickHouse, and the self-host build covers every required analysis feature: events, funnels, retention, journeys, users, segments, web traffic, and replay without a plan gate, plus flags and experiments. It has the best anonymous-to-identified handling of the lightweight tools (30-day retroactive backfill on `identify()`), and multiple sites per organization suit 10 to 15 apps. Gaps to plan around: no native Android SDK (call `/api/track` from Kotlin with an `anonymous_id`; decide whether an `ingest:write` key in the APK is acceptable), no Python/Go SDKs and a broken Node package (a thin HTTP helper per language), no OIDC login, and custom SQL dashboards and Web Vitals are cloud-only.
2. **PostHog hobby (only if depth or native Android matter more than operability).** It has the deepest feature set and the best SDK coverage, including native Android with replay, Python and Go, and a proper person-merge model. The costs: self-host is officially unsupported, there is no Helm path, about 45 compose services would need hand-porting to Terraform, it needs 4 vCPU and 16 GB, PostHog says it is unlikely to scale past a few hundred thousand events without effort, and a free instance gets one project, so all apps share one project separated by a property.
3. **Umami 3.4 (lightest fallback).** MIT, Postgres-only so it sits on the shared CNPG cluster, with funnels, retention, journeys, cohorts, segments and replays since v3.1. Weaker fit on identity (no backfill of pre-identify events), no native Android SDK, no SSO.

Worth watching: Swetrix CE, for its built-in OIDC (Authentik login works directly) and CE replays, once retention/cohorts and SDK coverage are confirmed. OpenPanel would rank higher if its public images kept pace with the supporter builds.
