# Cloud

Cloud is the homelab's self-hosted cloud for invited Users: they connect App
and Postgres Services in Projects, and agents do the same through an API. The
code is Forgejo `viktor/cloud` (plan `docs/plans/2026-11-12-cloud-v1-and-operator.md`,
vocabulary `GLOSSARY.md` there). This page covers what this repo runs for it.
Operations are in [docs/runbooks/cloud.md](../runbooks/cloud.md).

Scope: Project namespaces (`p-*`), Project Postgres roles and databases, and
`secret/cloud/<namespace>/*` belong to Cloud's database, not this repo
(AGENTS.md, "Cloud-owned objects"; [docs/agents/terraform.md](../agents/terraform.md)).

## What runs where

```mermaid
flowchart LR
  U["Users, Operators, agents"] -->|https| T[Traefik]
  T --> C["Deployment cloud<br/>console + API<br/>ns cloud"]
  C -->|Projects, jobs| DB[("Postgres db cloud<br/>role cloud")]
  C -->|list Ingresses,<br/>IngressRoutes, namespaces| K[Kubernetes API]
  R["Deployment cloud-reconciler<br/>ns cloud"] -->|claim jobs| DB
  R -->|OpenTofu state| ST[("db cloud_state<br/>role cloud_state")]
  R -->|roles, databases| PG[("pg-cluster-v18<br/>role cloud_provisioner")]
  R -->|login cloud-reconciler,<br/>write secret/cloud/p-*| V[Vault]
  R -->|apply| P["p-* namespaces<br/>(Cloud-owned)"]
  R -->|M5: dispatch builds,<br/>read repos| GH["api.github.com,<br/>ghcr.io, Forgejo"]
  C -->|M5: Metrics, logs| M["Prometheus, Loki<br/>ns monitoring"]
  A[Authentik] -. sign-in .- C
  P -. oauth2-proxy .- A
```

| Piece | Where | Defined in |
|---|---|---|
| Console and API | Deployment `cloud` (init container `migrate`), Kubernetes Service `cloud`, ingress `cloud.viktorbarzin.me` (`auth = "app"`), namespace `cloud` | `stacks/cloud/console.tf`, one `modules/kubernetes/tanstack_app` call |
| Reconciler | Deployment `cloud-reconciler` (1 replica, Recreate), Kubernetes Service `cloud-reconciler` (metrics only) | `stacks/cloud/reconciler.tf` |
| Env and credential files of both | locals | `stacks/cloud/deploy_rules.tf` |
| Reconciler identity and limits | service account `cloud-reconciler`, ClusterRoles, admission policies, Calico tier `cloud` | `stacks/cloud/main.tf`, `access_rules.tf` (M2) |
| Console identity | service account `cloud-console` with a token, ClusterRole `cloud-console` (get, list on namespaces, Ingresses, IngressRoutes) | `stacks/cloud/console.tf`, `deploy_rules.tf` |
| Sign-in | Authentik application `cloud` (console, confidential, authorization code and device code), `cloud-cli` (public, device code and refresh token, flow `cloud-cli-authorization` with an always-asked consent stage), groups `Cloud Users` and `Cloud Operators`; both providers send scope mapping `cloud: email (verified when vouched for)` instead of the managed `scope-email` | the module's `authentik.tf`, `stacks/cloud/cli_sign_in.tf`, `stacks/cloud/email_claim.tf` |
| Private Apps' sign-in | Authentik application `cloud-apps`, shared by every private App's oauth2-proxy | `stacks/authentik/cloud-apps.tf` (M2) |
| Postgres roles | `cloud` (console), `cloud_state`, `cloud_provisioner`, `cloud_projects` | `stacks/dbaas` |
| Vault | static roles `pg-cloud`, `pg-cloud-state`, `pg-cloud-provisioner`; Kubernetes auth roles `cloud-reconciler`, `cloud-project` | `stacks/vault` |
| Images | `ghcr.io/viktorbarzin/cloud` and `ghcr.io/viktorbarzin/cloud-reconciler`, private; Kyverno copies `ghcr-credentials` into `cloud` | `stacks/kyverno` `ghcr-credentials.tf` |
| Alerts | group `Cloud` | `stacks/monitoring` `prometheus_chart_values.tpl` |

The console's ingress is proxied, so `external-monitor-sync` adds the Uptime
Kuma monitor `[External] cloud` by itself.

## Credentials

| Credential | Source | Reaches | How |
|---|---|---|---|
| `BETTER_AUTH_SECRET`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | Vault KV `secret/cloud-console`, seeded by hand | console | ExternalSecret `cloud-auth` (env) |
| Console database password (role `cloud`) | Vault static role `pg-cloud` | console, migrate, reconciler | ExternalSecret `cloud-db-creds`, file `/secrets/db/password` |
| Authentik reader and approver tokens | Terraform (`authentik_token`) | console | Secrets `cloud-authentik-reader`, `cloud-authentik-approver` (env) |
| Kubernetes API token | service account `cloud-console` | console | projected token |
| `CLOUD_STATE_URL` (role `cloud_state`) | Vault static role `pg-cloud-state` | reconciler | ExternalSecret `cloud-reconciler-postgres`, file `/secrets/postgres/state-url` |
| `POSTGRES_PROVISIONER_PASSWORD` | Vault static role `pg-cloud-provisioner` | reconciler | same ExternalSecret, file `/secrets/postgres/provisioner-password` |
| `REGISTRY_TOKEN` (read:packages ghcr token) | Vault KV `secret/cloud/system` `ghcr_pull_token` | reconciler, copied into each Project | ExternalSecret `cloud-reconciler-registry`, file `/secrets/registry/token` |
| Vault token | Kubernetes auth login, role `cloud-reconciler`, 1 h TTL | reconciler | logs in with its service account token before each job |
| Kubernetes API token | service account `cloud-reconciler` | reconciler, OpenTofu | projected token |
| `cloud_apps_client_id`, `cloud_apps_client_secret` | Vault KV `secret/cloud/system` | read by the reconciler's OpenTofu through Vault | Vault policy `cloud-reconciler` |
| M5: `GITHUB_DISPATCH_TOKEN`, `GITHUB_OWNER_READ_TOKEN`, `FORGEJO_READ_TOKEN`, `FORGEJO_ADMIN_TOKEN`, `SECRETS_PRIVATE_KEY` | Vault KV `secret/cloud/system` keys `github_dispatch_token`, `github_owner_read_token`, `forgejo_read_token`, `forgejo_admin_token`, `secrets_private_key`, written by hand | reconciler | ExternalSecret `cloud-reconciler-system`, files `/secrets/system/<key with dashes>`; the reconciler also reads the same keys from Vault itself |
| M5: `SECRETS_PUBLIC_KEY`, `GITHUB_API_TOKEN` (optional) | Vault KV `secret/cloud/system` keys `secrets_public_key`, `github_api_token`, written by hand | console | ExternalSecret `cloud-console-system` (env, optional) |

The two M5 ExternalSecrets read all of `secret/cloud/system` (`dataFrom`
`extract`) and write only their own keys, through a template that uses
`{{ index . "key" }}`. ESO renders templates with `missingkey=error`, so
`{{ .key }}` or a `data` entry would fail the whole sync while one token is
not in Vault yet. A missing key becomes an empty file or an empty variable,
which the cloud code treats as unset; the reconciler then falls back to
reading Vault itself. The console holds no Vault token and gets only the
public key and the GitHub API token, never `secrets_private_key`. The
reconciler's Vault policy has `patch` on `secret/data/cloud/p-*`, because
App secrets are written as KV v2 merge patches; `secret/cloud/system` stays
read-only for it.

`secret/cloud/system` is written by stacks/authentik (`cloud-apps.tf`), and a
write replaces the whole secret. That stack reads the hand-written M5 keys
back and writes them again (`local.cloud_system_carried_keys`), so changing
`ghcr_pull_token` or rotating the client secret keeps them. A new
hand-written key must be added to that list.

The reconciler holds no Authentik credential. The three Postgres passwords
rotate on Tuesdays (10:17 for `pg-cloud`, `pg-cloud-state` and
`pg-cloud-provisioner`). The reconciler reads its files again on every job, and
Reloader restarts it when `cloud-reconciler-postgres`,
`cloud-reconciler-registry` or `cloud-reconciler-system` changes. The M5
files are read once at start, so that restart is what brings in a rotated
token. On such a restart, a pod delete or a CI
rollout the pod finishes its running job first (grace period 3780 s, the
longest a job can run). A node drain or eviction with a shorter grace period
cuts the job (the automated node upgrade drains with `--grace-period=300`);
the job stays `running` until `RECONCILE_STALE_SECONDS` pass, is requeued and
resumes from the OpenTofu state. `cloud-db-creds` restarts
nothing: both processes read the password file on each new connection.

## Data flow of a change

1. A User or an agent saves a Project change in the console or through
   `/api/v1`. The console checks it (Plan): names, Budget, the 20-connection
   Postgres ceiling and taken hosts, which it reads from the cluster with its
   ClusterRole. It writes a new desired version and queues a reconcile job in
   the `cloud` database.
2. The reconciler claims the job (`FOR UPDATE SKIP LOCKED`), reads the
   cluster's taken hosts again, renders the Project as OpenTofu JSON into
   `/tmp`, logs in to Vault, and runs `init`, `plan` and `apply` with state in
   `cloud_state`, schema `p_<project>`.
3. OpenTofu writes the `p-<project>` namespace and its objects through the
   reconciler's RBAC and the admission policies, the Project's Postgres role
   and database as `cloud_provisioner`, and the Project's Vault entries under
   `secret/cloud/p-<project>/`.
4. The reconciler waits for the Project's pods (180 s), records the result,
   duration and a redacted log excerpt on the job, and sets the Project's
   applied version. A failed job is retried up to 3 times with backoff.

## Agent sign-in

Two Authentik clients sign agents in:

| | `cloud` | `cloud-cli` |
|---|---|---|
| Client type | confidential | public |
| Grants | authorization code, device code | device code, refresh token |
| Access token | 15 minutes | 1 hour |
| Refresh token | none (no `offline_access`) | 30 days |
| Issuer | `https://authentik.viktorbarzin.me/application/o/cloud/` | `https://authentik.viktorbarzin.me/application/o/cloud-cli/` |
| Who may sign in | Cloud Users, Cloud Operators, Home Server Admins | the same |

Authentik 2026.8 requires the client secret at the token endpoint for the
device code grant on a confidential client (`authentik/providers/oauth2/token/base.py`),
so only a holder of the console's secret can complete a device sign-in on
`cloud`, and it could not refresh either. A CLI cannot hold that secret, so
agents sign in on `cloud-cli`. Both
clients use `sub_mode = hashed_user_id`, so a person has the same `sub` on both
and is one User.

The console's env carries `API_TOKEN_AUDIENCES=cloud,cloud-cli`,
`AGENT_OIDC_CLIENT_ID=cloud-cli` and `AGENT_OIDC_DISCOVERY_URL` (the
`cloud-cli` discovery document). As of 2026-11-13 the cloud code reads only the
first: it verifies tokens against the console's own issuer, so a `cloud-cli`
token passes the audience check and fails the issuer check. The code change
for the API to accept `cloud-cli` tokens: verify bearer tokens against both
discovery URLs (`OIDC_DISCOVERY_URL` with audience `cloud`,
`AGENT_OIDC_DISCOVERY_URL` with audience `cloud-cli`), point the CLI's
`cloud login` and the MCP Protected Resource Metadata at `AGENT_OIDC_*` in
`agentSettings()`, and add `offline_access` to the CLI's scopes.
`tests/cloud-deploy.test.sh` fails once the code reads the two `AGENT_OIDC_*`
names, as a reminder to drop them from its pending list.

**Email claim.** Authentik's managed `scope-email` mapping sends
`email_verified: false` for every account. Cloud's owner check (M5) finds a
Project owner's Forgejo account by an email both sides verified, so the
console's provider (module input `email_scope_mapping_id`) and `cloud-cli`
send `cloud: email (verified when vouched for)` instead
(`stacks/cloud/email_claim.tf`). It sends `email_verified: true` only for an
account the `cloud-apps-active-users` policy in `stacks/authentik/cloud-apps.tf`
admits: active, not `guest`, not a service account, not proxy-only, and
enrolled by a social source, on path `users/email-verified`, or carrying
`attributes.cloud_apps_email_vouched: true`. The two expressions are copies;
`tests/cloud-deploy.test.sh` runs both on the same accounts and fails when
they disagree.

**Device-code phishing.** Anyone can start a device authorization on the
public `cloud-cli` client, and Authentik returns a link
(`/device?code=XXXX`) that grants the code to the starter when a signed-in
person opens it. A hostile User could send that link to an Operator. So
`cloud-cli` uses its own authorization flow, `cloud-cli-authorization`, whose
consent stage asks every time (`always_require`) and names "Cloud CLI": the
person must confirm before any token is issued. The stock explicit-consent
flow remembers consent for weeks, so it would not stop a second link.

The consent screen in authentik 2026.8 shows "You're about to sign into Cloud
CLI." and the scopes, but not the user code or who started the sign-in. The
flow title is the heading of that screen, so it carries the warning:
"Continue only if you ran cloud login yourself in the last few minutes.
Whoever started this sign-in gets your Cloud access." The remaining risk is a
person who clicks Allow on a link they did not start: the link fills in the
code, so one click still grants that person's 30-day refresh token to the
sender. To make the code typed by hand, a Traefik middleware could strip the
`code` query parameter from authentik's `/device`; that is not in place.

## Metrics

The reconciler serves `/metrics` on 9090; Kubernetes Service `cloud-reconciler` carries
the `prometheus.io` annotations and `cloud_.+` is on the
`kubernetes-service-endpoints` keep list. The job sets `honor_labels: true`,
so the Postgres series keep their own `service` label, the Cloud Service name.

| Metric | Exported by | Read by |
|---|---|---|
| `cloud_reconcile_total{result}`, `cloud_reconcile_duration_seconds{kind}`, `cloud_reconcile_queue_depth` | reconciler | `CloudReconcileQueueStuck`, `CloudReconcileFailing` |
| `cloud_postgres_database_bytes`, `cloud_postgres_database_limit_bytes`, `cloud_postgres_database_unmeasured` `{project,service}` | reconciler | `CloudPostgresDatabaseNearSize`, `CloudPostgresDatabaseUnmeasured` |
| `cloud_project_converging_seconds{project}` | not yet exported: the reconciler, after the cloud code change below | `CloudProjectStuckConverging` |
| `cloud_build_minutes_used`, `cloud_build_minutes_allowance` | not yet exported (M5, builds) | `CloudBuildMinutesHigh` |
| `up{namespace="cloud",service="cloud-reconciler"}` | Prometheus | `CloudReconcilerDown` |

**Code change for `cloud_project_converging_seconds`.** As of 2026-11-13 no
process exports it, so `CloudProjectStuckConverging` has no input and stays
quiet. The reconciler should export it, because it already reads desired and
applied versions: a gauge in `src/reconciler/metrics.ts` with label `project`
(the slug), set on each pass of the worker loop to the seconds since the
oldest `queued` or `running` `reconcile_jobs` row whose `desired_version` is
above its Project's `applied_version`, and removed (or 0) when there is none.
It is scraped with the other reconciler series (`service="cloud-reconciler"`,
the label `tests/cloud-deploy/alerts.test.yml` uses). No infra change is
needed when it lands; `cloud_.+` is already kept.

`CloudReconcileFailing` has no `for`: a failed job is not retried, so one
failure fires the warning, which stays up while the failure is inside the
15-minute window. prom-client creates the `result="failed"` series at its
first increment, which `increase()` cannot see. The rule's
`last_over_time(...[1h] offset 15m)` clause counts a series with no sample in
the hour before the window as new, so the first failure after a restart fires
too: a restarted pod has a new `instance` label. A scrape gap shorter than an
hour, such as a Prometheus restart, does not make an old failure look new; a
longer gap can fire one false warning. `CloudReconcileQueueStuck` uses the
same clause for finished jobs. Zero-initialised result labels in
`src/reconciler/metrics.ts` would let both rules drop the clause.

Only `CloudReconcilerDown` and `CloudReconcileQueueStuck` page: then no Project
change applies until an Operator acts. The other alerts are warnings about one
Project or one database. `CloudProvisionerForeignRole`,
`CloudProjectRoleUnlimited` and `CloudProjectConnectionsOverCeiling` (M2, the
PostgreSQL group) cover the provisioner audit. `tests/cloud-deploy.test.sh`
runs promtool unit tests on the group.

## Builds and network (M5)

Builds and Deploys run in the reconciler; one switch turns them on:
`variable "builds_enabled"` in `stacks/cloud/deploy_rules.tf`, passed as
`BUILDS_ENABLED`. It is `false` until the GitHub tokens exist (runbook,
"Turn on builds"); `false` is also the M5 rollback. The reconciler also gets
`FORGEJO_URL=http://forgejo.forgejo.svc.cluster.local` and
`FORGEJO_AUTH_SOURCE_ID=1`. `forgejo admin auth list` shows source 1
"Authentik" as disabled (checked 2026-11-13): it makes no new accounts, and
the accounts it made still carry it, which is what the owner check matches
on. The console gets `PROMETHEUS_URL=http://prometheus-server.monitoring.svc.cluster.local`
(Metrics tab) and `LOKI_URL=http://loki.monitoring.svc.cluster.local:3100`
(logs tab).

Network: neither Deployment has an egress NetworkPolicy, and namespace
`cloud` carries `tier=4-aux`, so Calico's `wave1-egress-observe-tier34`
(order 2000, Allow) passes all its egress. Namespaces `forgejo` and
`monitoring` have no ingress policy. Checked on 2026-11-13 from the running
pods: the reconciler reached Forgejo, Prometheus, Loki, `api.github.com`,
`github.com` and `ghcr.io`; the console reached Prometheus and Loki. If
tier 4-aux egress is ever restricted, namespace `cloud` needs these allowed
first. The Calico tier `cloud` applies to `p-*` namespaces only.

## Connections on the shared primary

| Holder | Connections |
|---|---|
| console pool, role `cloud` (`APP_POOL_MAX` 4, plus 1 LISTEN) | 5 |
| reconciler pool, role `cloud` | 4 |
| `migrate` init container while it runs | 1 |
| **role `cloud` at most** | **10**, the figure in [docs/agents/databases.md](../agents/databases.md) |
| `cloud_provisioner` | 5 (CONNECTION LIMIT) |
| `cloud_state` | 10 (CONNECTION LIMIT) |

A second replica of either Deployment needs this budget raised first.

## CI

The workflow files are kept here, reviewed with the stack:
[cloud-ci/build.yml](cloud-ci/build.yml) and [cloud-ci/deploy.yml](cloud-ci/deploy.yml).
On 2026-11-13 the cloud repo's master still has its first build.yml (the full
test suite against a Postgres service, the console image only) and a
deploy.yml that sets only `cloud`; the runbook's "Register the repo with CI"
copies these two in. Once they are in place, the cloud repo builds both images
on GitHub Actions from its private mirror: one job on pushes to master,
`bun run check` and `typecheck`, then the console image (the Dockerfile's last
stage) and the reconciler image (target `reconciler`), each with its own build
cache and ghcr retention, with a newer push cancelling a running build. The unit, HTTP
and e2e suites run locally before a change lands, because private Actions
minutes are nearly used up. Woodpecker's deploy pipeline sets both images:
`cloud` (containers `migrate` and `cloud`) first, waiting for its rollout so
the migrations have run, then `cloud-reconciler` (container `reconciler`). It
reports the reconciler's rollout without failing on it, since the old pod may
first finish a job of up to 3780 s. Both Deployments ignore their images in Terraform
(`CI_SETS_IMAGE`). Registration: [docs/runbooks/cloud.md](../runbooks/cloud.md),
"Register the repo with CI".

## How to debug a stuck Project

A Project is stuck when its desired version stays ahead of its applied
version. Work down this list:

1. **Is the reconciler running?** `kubectl -n cloud get pods -l app=cloud-reconciler`.
   Down: runbook "Restart".
2. **Is the Project's job queued, running or failed?** In the `cloud` database:
   `SELECT id, kind, state, attempts, last_error, updated_at FROM reconcile_jobs WHERE project_id = (SELECT id FROM projects WHERE slug = '<project>') ORDER BY id DESC LIMIT 5;`
   A `running` job older than 10 minutes (`RECONCILE_STALE_SECONDS`) is
   requeued by the reconciler itself.
3. **What did OpenTofu say?** The job's `log_excerpt`, then the logs:
   `homelab logs query '{namespace="cloud", container="reconciler"} |= "<project>"'`.
4. **Admission refused an object?** The error names the policy
   (`cloud-reconciler-scope`, `cloud-managed-*`, `cloud-ingress-live-hosts`).
   A host the homelab took after the last `cloud` apply is refused by the live
   host guard; the Project must pick another name.
5. **Credentials?** `Vault login as role cloud-reconciler answered 403`,
   `password authentication failed for user "cloud_state"` or
   `"cloud_provisioner"`: check the ExternalSecrets
   (`kubectl -n cloud get externalsecret`) and runbook "Recover from a failed
   apply".
6. **State lock?** `Error acquiring the state lock` names the lock holder in
   `cloud_state`, schema `p_<project>`. Runbook "Recover from a failed apply".
