# Product analytics: operations

The pipeline from [ADR-0041](../adr/0041-product-analytics-on-rybbit-behind-vector.md), as it runs. The design and the telemetry standard are in [2026-11-09-product-analytics-design.md](../plans/2026-11-09-product-analytics-design.md). Terms (Product event, Ingest path, Write key, Raw events, Analytics site) are defined in `CONTEXT.md`.

## What runs where

| Part | Kubernetes object | Stack |
|---|---|---|
| Rybbit backend and dashboard | `rybbit/rybbit`, `rybbit/rybbit-client`, dashboard at `rybbit.viktorbarzin.me` behind Authentik | `stacks/rybbit/main.tf` |
| ClickHouse (Rybbit events, replays, Raw events) | `rybbit/clickhouse` | `stacks/rybbit/main.tf` |
| Replay TTL and `events_raw` schema | CronJob `rybbit/clickhouse-schema` every 6 h, plus a one-shot Job per script change | `stacks/rybbit/clickhouse_schema.tf` |
| Event pipeline (Vector 0.61) | `rybbit/event-pipeline`, Service port 80, metrics on 9598 | `stacks/rybbit/event_pipeline.tf`, `stacks/rybbit/files/vector.yaml` |
| Ingest path `/_t/` on every host | IngressRoute `rybbit/ingest-path`, priority 10000 | `stacks/rybbit/ingest_path.tf` |
| GlitchTip | `glitchtip/glitchtip`, dashboard at `glitchtip.viktorbarzin.me` | `stacks/glitchtip` ([architecture](../architecture/glitchtip.md)) |

Ingest path routes:

| Path | Goes to |
|---|---|
| `/_t/r/<x>` | Rybbit `/api/<x>` (script.js, track, identify, session replay) |
| `/_t/e/<x>` | Vector (Segment SDK endpoints: `/v1/batch`, `/t`, `/i`, `/b`, ...) |
| `/_t/x/api/<project>/{envelope,store,minidump}/` | GlitchTip ingest only |

## Settings and secrets

Vault `secret/rybbit`, extracted into the `rybbit-secrets` Secret:

| Key | Meaning |
|---|---|
| `admin_email`, `admin_password` | The Rybbit admin account (`admin@viktorbarzin.me`) |
| `ingest_api_key` | Rybbit API key named `event-pipeline`, scope `ingest:write`. Only Vector holds it |
| `site_id_apps`, `site_id_hosted` | Analytics sites: `apps` is 1, `hosted` is 2 |
| `rybbit_org_id` | The `Viktor` organization |
| `write_keys` | JSON, app name to Write key, e.g. `{"tv": "..."}` |

Vault `secret/glitchtip` holds `secret_key`, `oidc_client_secret`, and one `dsn_<app>` per project. A DSN has the form `https://<key>@<app host>/_t/x/<project id>`.

Vector reads its secrets from files (`/etc/vector/secrets`, the mounted `rybbit-secrets`) through its `directory` secret backend. Vector 0.61 does not expand environment variables in its config unless it is started with `--dangerously-allow-env-var-interpolation`, and it sends an unexpanded reference as literal text. On 2026-11-09 that made ClickHouse answer 401, and made Rybbit treat the pipeline as keyless and drop its events as bots while still answering 200.

## Add an Instrumented app

1. Add a Write key: `vault kv patch secret/rybbit write_keys='{"tv":"...","<app>":"<openssl rand -hex 16>"}'`. Keep the existing keys in the JSON.
2. Add `<app> = "<app host>"` to `local.analytics_apps` in `stacks/rybbit/event_pipeline.tf`, then land it. CI applies it and Reloader restarts Vector.
3. Create a GlitchTip project and store its DSN. A Django shell in the pod works, and so does the dashboard:

   ```sh
   kubectl -n glitchtip exec deploy/glitchtip -c glitchtip -- ./manage.py shell -c "
   from apps.organizations_ext.models import Organization
   from apps.projects.models import Project, ProjectKey
   org = Organization.objects.get(slug='viktor')
   p, _ = Project.objects.get_or_create(organization=org, slug='<app>', defaults={'name': '<app>'})
   k = ProjectKey.objects.filter(project=p).first() or ProjectKey.objects.create(project=p)
   print(p.id, k.public_key.hex)"
   vault kv patch secret/glitchtip dsn_<app>="https://<key>@<app host>/_t/x/<id>"
   ```

4. Wire the app with the shared telemetry library (design, "Client libraries").

## Check that it works

```sh
# script and pipeline answer on an app host
curl -s -o /dev/null -w '%{http_code}\n' https://tv.viktorbarzin.me/_t/r/script.js
WK=$(vault kv get -field=write_keys secret/rybbit | jq -r .tv)
AUTH="authorization: Basic $(printf '%s:' "$WK" | base64)"
curl -s -X POST https://tv.viktorbarzin.me/_t/e/v1/batch -H "$AUTH" -H 'content-type: application/json' \
  -d '{"batch":[{"type":"track","event":"pipeline.checked","anonymousId":"runbook"}]}'

# accepted events, newest first
kubectl -n rybbit exec deploy/clickhouse -- clickhouse-client -q \
  "SELECT received_at, app, type, event FROM events_raw.events ORDER BY received_at DESC LIMIT 5"
kubectl -n rybbit exec deploy/clickhouse -- clickhouse-client -q \
  "SELECT timestamp, event_name, hostname FROM clickhouse.events ORDER BY timestamp DESC LIMIT 5"

# rejected events and the reason
homelab logs query '{job="event-pipeline", outcome="rejected"}' --since 1h
```

Vector's own counters are on port 9598 (`kubectl -n rybbit port-forward deploy/event-pipeline 9598`, then `/metrics`): `vector_component_sent_events_total` and `vector_component_errors_total` per component.

Rybbit and ClickHouse write in batches, so a new event can take a few seconds to appear.

## Test the pipeline config

`files/vector.yaml` carries unit tests. Run them before landing a change:

```sh
T=$(mktemp -d); mkdir -p $T/keys $T/secrets $T/data
printf 'write_key,app,hostname,site_id\ntestkey,tv,tv.viktorbarzin.me,1\n' > $T/keys/keys.csv
printf x > $T/secrets/ingest_api_key; printf x > $T/secrets/clickhouse_password
docker run --rm -v $PWD/stacks/rybbit/files/vector.yaml:/etc/vector/vector.yaml:ro \
  -v $T/keys:/etc/vector/keys:ro -v $T/secrets:/etc/vector/secrets:ro -v $T/data:/var/lib/vector \
  docker.io/timberio/vector:0.61.0-debian test /etc/vector/vector.yaml
```

## Replay events into Rybbit

The sinks buffer in memory. A disk buffer held small writes without the sink ever reading them (seen on 0.61.0, 2026-11-09). Events in flight when Vector restarts can be lost on the way to Rybbit, but `events_raw.events` keeps every event Vector accepted, with the original Segment message in `payload`. To fill a gap, select the rows for the window and post them again to `/_t/e/v1/batch` with the app's Write key. Rybbit does not deduplicate, so take only the missing window.

## Bootstrap (done 2026-11-09)

The Rybbit instance had no users and sign-up was closed. The first admin was created by:

1. A one-off apply with sign-up open, limited to the backend: `scripts/tg apply -var rybbit_signup_open=true -target=kubernetes_deployment.rybbit` from `stacks/rybbit`.
2. `POST /api/auth/sign-up/email` from inside the pod with the Vault credentials.
3. A normal apply to close sign-up again.

The organization, the two sites (both with First-Party Proxy on, `saltUserIds` off) and the `event-pipeline` API key were then created through the API with the admin session. Nobody else has signed up: `SELECT email FROM "user"` in the `rybbit` database returns only the admin.

Repeat this only for a fresh database. Rybbit's API key routes are `POST /api/user/api-keys` (create, body `{"name", "permissions": {"ingest": ["write"]}}`), `GET /api/auth/api-key/list` and `POST /api/auth/api-key/delete`.

## Known gaps

- Rybbit's MCP query user (`rybbit_query`) is not created, because the ClickHouse `default` user has `access_management` off. Rybbit logs this at start. The dashboard does not use that user.
- Funnels in Rybbit count sessions, not Persons (ADR-0041, Consequences).
