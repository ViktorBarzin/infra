# Product analytics and the telemetry standard: design

Date: 2026-11-09. Decision record: [ADR-0041](../adr/0041-product-analytics-on-rybbit-behind-vector.md). Comparison: [2026-11-09-product-analytics-platforms.md](../research/2026-11-09-product-analytics-platforms.md).

This design adds one analytics pipeline covering every app we serve, and a shared standard for **Product events** and logs, so that new telemetry fits the stack without per-app decisions. The terms follow `CONTEXT.md` (Product analytics section).

## Shape

```mermaid
flowchart TD
  B[Browsers] -->|/_t/r/| R[Rybbit]
  B -->|/_t/e/| V[Vector]
  N[Servers,<br/>Android TV] --> V
  V --> R
  V --> C[(Raw events)]
  B -.->|/_t/x/| G[GlitchTip]
  N -.-> G
```

Browsers cover first-party apps (Rybbit script and Segment SDK) and third-party apps (Rybbit script injected by the Traefik plugin). Vector also sends rejected events to Loki.

| Part | What it does | Where it lives |
|---|---|---|
| Rybbit | Pageviews, product events, funnels, retention, replay, Persons | `stacks/rybbit` |
| Vector | Receives Segment-spec events, checks them, fans them out | `stacks/rybbit` (same namespace as its targets) |
| Raw events | Every accepted event as received, kept forever | ClickHouse database `events_raw` on Rybbit's ClickHouse |
| GlitchTip | Errors and crashes from the Sentry SDKs | `stacks/glitchtip` |
| Ingest path | `/_t/` on every host, routed to the three services above | one host-independent Traefik route in `stacks/rybbit` |
| Injection plugin | Adds the Rybbit script to HTML from third-party apps | `stacks/traefik/modules/traefik/` local plugin, run as a `websecure` entrypoint middleware |

## One standard, several transports

Each app imports one library per language and follows one naming and id scheme. The data still travels by more than one path, because the clients differ:

| Data | App code calls | Path |
|---|---|---|
| Logs (backends) | its usual logger | JSON on stdout, Alloy, Loki |
| Product events | `track`, `identify` | Segment SDK, `/_t/e/`, Vector, Rybbit and Raw events |
| Pageviews and replay (browser) | nothing, the script loads itself | Rybbit script, `/_t/r/`, Rybbit |
| Errors and crashes | nothing, captured automatically | Sentry SDK, `/_t/x/`, GlitchTip |

Browsers and the Android TV app can only send over HTTP. Logs stay on stdout so they survive a pipeline outage. Vector could later replace Alloy as the log shipper as well, giving one collector for everything. That is a separate change, because Alloy also ships logs from software we did not write.

## Ingest path

One Traefik `IngressRoute` matches `PathPrefix(/_t/)` on any host, at a priority above app routes. It carries no forward-auth, because beacons have to work for signed-out visitors. The middlewares strip the prefix as follows:

| Prefix | Target | Used by |
|---|---|---|
| `/_t/r/` | Rybbit backend `/api/` | the Rybbit browser script: `script.js`, track, identify, replay, tracking config |
| `/_t/e/` | Vector | Segment SDKs: `/v1/batch`, the browser SDK's `/t`, `/p`, `/i`, `/b` paths, and the settings file the Kotlin SDK fetches at start |
| `/_t/x/` | GlitchTip | Sentry SDKs, through a DSN whose path is `/_t/x/<project>` |

Backends inside the cluster send to Vector's Service directly, so their events skip the public route.

## Product event standard

Events use the [Segment spec](https://segment.com/docs/connections/spec/) and are sent with Segment's open-source SDKs (MIT): `@segment/analytics-next`, `@segment/analytics-node`, `analytics-python`, `analytics-go` and `analytics-kotlin`, each pointed at the Ingest path.

| Field | Rule |
|---|---|
| `type` | `track`, `identify`, or `screen` (Android). Browser pageviews come from the Rybbit script, so the browser SDK does not send `page` |
| `event` | `noun.past_verb`, lower case, matching `^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$`, e.g. `recording.started`, `trip.created` |
| `userId` | The Person's Authentik `sub` once signed in, omitted before |
| `anonymousId` | The SDK's own id, sent on every event, so Rybbit can merge it into the Person at `identify` |
| `properties` | snake_case keys, at most 2,048 characters as JSON (Rybbit's limit) |
| `context.page.url` | Set by the browser SDK. Server and Android events set `context.app` instead |
| write key | One per app, in Vault at `secret/rybbit` under `write_key_<app>`. Vector derives `app` from it and ignores any `app` the client sends |

Vector rejects an event, and sends it to Loki under `{job="event-pipeline", outcome="rejected"}` with the reason, when:
- the write key is unknown;
- the name or a property key breaks the pattern;
- the properties are too long;
- the browser host is not a production host (`*.viktorbarzin.me` and `viktorbarzin.me`).

## Log standard

Each app writes one JSON object per line to stdout. The existing Alloy collector ships it to Loki. Field names follow the OpenTelemetry log data model and semantic conventions. Attributes we add are snake_case.

This replaces the earlier contract in app-kit ADR-0001 (`ts`, `level`, `logger`, `msg`, `exc`), which tripit, offline-reader, tasks and alexa-assistant use today. No Loki rule or dashboard reads those field names, so they change in the rollout without breaking a query. `@viktorbarzin/log` moves to the fields below in a major version (app-kit ADR-0002).

| Field | Meaning |
|---|---|
| `timestamp` | RFC 3339 with nanoseconds, UTC |
| `severity_text`, `severity_number` | `DEBUG` 5, `INFO` 9, `WARN` 13, `ERROR` 17, `FATAL` 21 |
| `body` | The message |
| `service.name`, `service.version` | App and release |
| `deployment.environment.name` | `production` or `dev` |
| `trace_id`, `span_id` | From the active OTel span, when there is one |
| `enduser.id` | The Person's Authentik `sub`, when known |
| other keys | snake_case attributes, e.g. `channel_id`, `duration_ms` |

The per-language libraries set these fields, so app code calls its usual logger.

## Errors

Apps use the Sentry SDKs with a DSN per app pointing at `/_t/x/<project>` on their own host. Retention is GlitchTip's default of 90 days. Releases are tagged with the app version, so errors group by release. Android uploads its ProGuard mapping at build time.

## Client libraries

| Language | Home | Contents |
|---|---|---|
| TypeScript (browser, Bun/Node) | `app-kit`, `@viktorbarzin/telemetry` | Rybbit script tag, Segment client with our host and inline settings, Sentry init, JSON logger. On by default in new app-kit apps |
| Python | `telemetry` repo, `viktorbarzin-telemetry` | Segment client config, Sentry init, `logging` JSON formatter |
| Go | `telemetry` repo, `telemetry/go` | Segment client config, Sentry init, `slog` JSON handler |
| Kotlin | `telemetry` repo, `telemetry-android` | Segment client config (our settings host, telemetry off), Sentry init |

The libraries are public, as app-kit is. The TypeScript packages publish to npm through app-kit's release workflow. The Python package publishes to PyPI through trusted publishing from the `telemetry` repo's GitHub mirror. The Go module is fetched from the mirror. JitPack builds the Android library from tags. The code holds no secrets: Write keys and DSNs come from each app's configuration.

## Settings

| Setting | Value |
|---|---|
| Event retention | Forever, in Rybbit and in the raw table |
| Replay retention | 90 days |
| Replay masking | Password inputs only (`data-replay-mask-all-inputs="false"`, `data-replay-mask-input-options='{"password":true}'`) |
| Error retention | 90 days |
| Access | Rybbit and GlitchTip behind Authentik, for Viktor and the infra admins |
| Backups | Rybbit's ClickHouse (events, replays, raw table) and GlitchTip's Postgres go to the offsite copy |
| Consent | Measurement is assumed on visit. There is no banner or notice |

## Third-party apps

The injection plugin adds `<script src="/_t/r/script.js" data-site-id="<hosted>" defer>` before `</head>` of HTML documents. It acts only on `GET` requests that ask for HTML and get a `text/html` 200 back.

It runs as an entrypoint middleware on `websecure`, as CrowdSec and compression do, so every host is covered from one place and a new service needs no change. Putting it in `ingress_factory` instead would change a module about 100 stacks use, and CI would then apply all of them in turn. The plugin filters hosts itself:

- `excludeHosts` lists the denylisted services: Authentik, Vault, Vaultwarden, the Kubernetes dashboard, Proxmox, OPNsense, Headscale, and APIs that serve no HTML.
- First-party apps load the script themselves, so they opt out with `<meta name="analytics" content="sdk">` in their HTML or an `X-Analytics: sdk` response header. The plugin strips that header before it reaches the browser.
- `includeHosts` limits the plugin to named hosts for a staged start. It is cleared once the first hosts work.

## Rollout

1. **Platform.**
   - Rybbit gets Redis, the 90-day replay TTL, the two sites, and an ingest key.
   - Add Vector and the raw table.
   - Add GlitchTip.
   - Add the Ingest path route.
2. **Libraries.** The TypeScript, Python, Go and Kotlin libraries.
3. **tv test.** Wire tv's web app, backend and Android TV app, then check that:
   - web, backend and Android TV events reach Rybbit and the raw table;
   - replay records with only password fields masked;
   - an anonymous visitor who signs in becomes one Person;
   - retention counts Persons, not sessions;
   - one shared site gives usable per-app views by hostname.

   Passing those checks ends the test.
4. **Every other app.**
   - tripit (with tripit ADR-0076), terminal-lobby (its `TLEVENT` events move to the standard), the remaining first-party apps, and the static sites.
   - The injection plugin for third-party apps.
   - Logs moved to the standard.
5. **Clean-up.** Retire the duplicated Loki dashboards for events that moved. tv's viewing tables stay, because tv features read them.

## Open questions

- Whether Vector's `http_server` answers before or after the disk buffer write. This decides how much an outage can lose, and the tv test measures it.
- Android TV behaviour of the Segment and Sentry SDKs. Neither documents TV devices.
- Third-party apps with nonce-based Content Security Policy will block the injected script. Those apps keep server-side counts only.
