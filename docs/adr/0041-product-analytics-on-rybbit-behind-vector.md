# ADR-0041: Product analytics on Rybbit behind a Vector pipeline, errors in GlitchTip

- Status: accepted
- Date: 2026-11-09
- Related: `docs/plans/2026-11-09-product-analytics-design.md` (the design and the telemetry standard), `docs/research/2026-11-09-product-analytics-platforms.md` (the comparison), `stacks/rybbit`, tripit ADR-0076

## Context

Until now, usage data lived wherever each app put it. tv kept viewing tables in its own Postgres. terminal-lobby wrote `TLEVENT` lines to Loki, tripit counted usage through OTel traces, and Immich share links went through Loki recording rules. Rybbit was deployed in April 2026 but has never had a site configured. We want one pipeline across every app we serve. It should give us product events per Person, web traffic, session replay, and error tracking, from web, backend and Android TV clients.

No self-hosted platform meets every requirement (see the comparison):

- **PostHog** has per-Person funnels and native SDKs. Its free self-host is 47 compose services and officially unsupported. It allows one project, locks replay retention at 30 days, and warns at "a couple 100ks events". Our estimate is 200,000 to 800,000 events a month.
- **Rybbit** counts funnels per session, and identity is scoped per site. Its ingest accepts any hostname, so all first-party apps can share one site and one set of users. It runs as two small images on ClickHouse, Postgres and Redis.

## Decision

1. **Rybbit is the analytics platform.** It has two sites:
   - `apps`: every first-party app and static site, so a Person is one user across apps.
   - `hosted`: pageviews from the third-party apps we host.

   Events are kept forever and replays for 90 days. The 90 days comes from a Terraform-managed `ALTER TABLE ... MODIFY TTL`, because Rybbit hardcodes 30 days.
2. **Vector sits in front of Rybbit for every SDK event.** Apps send the Segment spec through Segment's open-source SDKs. Each app has its own write key. Vector:
   - checks each event against the telemetry standard;
   - stamps the app from the write key;
   - forwards to Rybbit with the server-side ingest key;
   - writes every accepted event to a raw table in ClickHouse, kept forever;
   - sends rejected events to Loki.

   The Rybbit browser script still carries pageviews and replay directly to Rybbit.
3. **GlitchTip is the error and crash tracker.** Apps use the Sentry SDKs. GlitchTip runs as one app on the shared Postgres and signs users in through Authentik over OIDC.
4. **Browsers reach all three through an Ingest path, `/_t/`, on each app's own host.** One host-independent Traefik route serves it, so no app stack changes for it.
5. **Third-party apps get the Rybbit script from an in-repo Traefik plugin.** It is on by default through `ingress_factory`, with a denylist for authentication, secrets and admin consoles.
6. **Logs follow the same standard:** JSON lines on stdout using OpenTelemetry field names, collected by the existing Alloy into Loki.

## Consequences

- Funnels spanning more than one session are out of reach in Rybbit. If they become important, the raw table and the Vector sink make a later move to PostHog a pipeline change, with no change in the apps.
- We own the Segment-to-Rybbit mapping. Rybbit rejects unknown fields with a 400 and returns 200 for events it drops as bots. The raw table, not Rybbit's response, is the record of what was sent.
- The injection plugin runs inside Traefik. Traefik disables every local plugin when one fails to load, so the plugin passes a Yaegi load test before each release.

## Considered options

- PostHog hobby on a VM: rejected for its footprint, support status, the 30-day replay lock and the scale warning.
- Umami and Swetrix: Umami has per-website identity and sessions that rotate monthly. Swetrix has no retention or cohort reports.
- Jitsu and RudderStack as the pipeline: Jitsu needs four datastores and an operator, and has shipped only betas since July 2026. RudderStack keeps its configuration in its vendor cloud.
- Sentry self-hosted for errors: 53 services and 16 GB. GlitchTip accepts the same SDKs.
