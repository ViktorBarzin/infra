# Authentik LDAP and RAC outposts

Step 7 of `docs/plans/2026-09-01-service-identity-and-request-attribution-design.md`
extends identity to the two remaining protocols authentik can reach natively:
Postgres (via an LDAP outpost and PostgreSQL's own `ldap` auth method) and
SSH/RDP/VNC (via a RAC outpost).

Both are declared in Terraform and both are inert. This runbook covers what
exists, what a person has to do to switch each half on, and the Postgres-side
change that is deliberately not in the Terraform.

Everything below was read from the live instance on 2026-09-01, against authentik
**2026.8.0** (`/api/v3/admin/version/`). Two earlier notes in the tree say
2026.2.4; the chart in `stacks/authentik/modules/authentik/main.tf` is at
`2026.8.0` and the server pods run `ghcr.io/viktorbarzin/authentik-server:2026.8.0-patch3`.

## Licence: neither feature needs one

Settled from our own instance, since the public docs are ambiguous.

| Question | Answer | How it was read |
|---|---|---|
| Is this instance licensed? | No | `/api/v3/enterprise/license/summary/` returns `status: unlicensed`, `license_flags: []`, zero licence objects |
| Does RAC need a licence? | No | App label `authentik.providers.rac`, model `authentik_providers_rac.racprovider`. `RACProviderViewSet` is a plain `ModelViewSet`; `EnterpriseRequiredMixin` appears nowhere under `/authentik/providers/rac/` |
| Does the LDAP provider need a licence? | No | Same shape: `authentik.providers.ldap`, `authentik_providers_ldap.ldapprovider`, plain `ModelViewSet`, no mixin |
| Does impersonation need a licence? | No | `UserViewSet.impersonate` (`/authentik/core/api/users.py`) has no licence check. Its gates are the brand's `impersonation` flag, the `authentik_core.impersonate` permission, not-self, and a reason when `impersonation_require_reason` is set |
| Is impersonation switched on? | Yes | `/api/v3/admin/settings/` reports `impersonation: true`, `impersonation_require_reason: true`; `/api/v3/root/config/` capabilities include `can_impersonate` |

Every licence-gated provider lives under `authentik.enterprise.providers.*`
(radius, scim, ssf, google_workspace, microsoft_entra, ws_federation) and its
serializer carries `EnterpriseRequiredMixin`. RAC and LDAP do not.

One caveat that is unchanged by this: impersonation is session-based. It writes
into `request.session`, so it needs an authenticated admin browser session and
cannot be started with an API bearer token. `is_enterprise` does appear in the
capabilities list, but that flag only reports that the enterprise app is
installed, which it is in the OSS image; the licence summary is the authoritative
read.

## What exists after the prepare commit

`stacks/authentik/postgres-ldap.tf` and `stacks/authentik/rac.tf`, 15 authentik
objects in total:

| Object | Name / slug | State |
|---|---|---|
| Flow | `ldap-bind` | New. Identification (order 10) + user login (order 100) |
| Identification stage | `ldap-bind-identification` | Username or email, password embedded |
| User login stage | `ldap-bind-login` | `session_duration = minutes=5` |
| LDAP provider | `Provider for Postgres LDAP` | `base_dn = dc=ldap,dc=viktorbarzin,dc=me`, `bind_mode`/`search_mode` = `direct`, `mfa_support = true` |
| Application | `postgres-ldap` | LDAP provider attached as **backchannel** provider, so it stays off the user app grid |
| Group | `Postgres LDAP Users` | Empty |
| RAC provider | `Provider for Remote Access` | `connection_expiry = hours=8` |
| Application | `remote-access` | RAC provider as protocol provider (launchable by design) |
| Group | `RAC Users` | Empty |
| Outpost | `postgres-ldap` (type `ldap`) | `kubernetes_replicas = 0` |
| Outpost | `rac` (type `rac`) | `kubernetes_replicas = 0` |
| Policy bindings | one per application | Order 0, group only |

No ingress, no Traefik middleware, no `ingress_factory` call, and no Kubernetes
resource in either file. Verified by planning both files in isolation: 15 objects
to add, none of type `kubernetes_*`.

### Why there is no ingress

Read from the live server source:

- **LDAP.** `LDAPKubernetesController` declares ports 389 (container 3389), 636
  (container 6636) and 9300 metrics, and adds no ingress reconciler; only
  `ProxyKubernetesController` does that. So the outpost is reachable at
  `ak-outpost-postgres-ldap.authentik.svc.cluster.local:389` inside the cluster
  and nowhere else. LDAP is not HTTP, so there is no Traefik router for the
  `auth` tier conventions to apply to.
- **RAC.** `RACKubernetesController` sets `deployment_ports = []` and deletes the
  Service reconciler, so a RAC outpost is a Deployment and nothing else. It dials
  the authentik server outbound over a websocket. The browser side is served by
  the authentik server on paths the existing `authentik.viktorbarzin.me` ingress
  already covers: `/application/rac/<app>/<endpoint>/`, `/if/rac/<token>/`,
  `/ws/rac/<token>/` and `/ws/outpost_rac/<channel>/`. That ingress is
  `auth = "none"` because authentik cannot gate its own UI, so access control for
  RAC is the application's policy binding, not a middleware.

### Default-deny is carried by the policy bindings

`core_default_app_access` defaults to `True` and this instance leaves it at the
default (the live `flags` map is empty), which means **an application with no
policy bindings is reachable by any authenticated user**. This is the same gap
`app-access-bindings.tf` closed for the OIDC apps. Both new applications
therefore carry a binding to a group that is created empty, so nobody passes
until a person is added.

## Checking current state

```sh
# outposts and their replica counts (expect postgres-ldap and rac at 0)
kubectl -n authentik get deploy -l app.kubernetes.io/managed-by=goauthentik.io

# the LDAP Service exists but has no endpoints while replicas is 0
kubectl -n authentik get svc,endpoints | grep postgres-ldap

# from the API side
AK=$(vault kv get -field=tf_api_token secret/authentik)
curl -s -H "Authorization: Bearer $AK" \
  https://authentik.viktorbarzin.me/api/v3/outposts/instances/ \
  | jq -r '.results[] | "\(.name)\t\(.type)\t\(.config.kubernetes_replicas)"'
```

## Enabling RAC

RAC is the shorter of the two because nothing outside the authentik stack has to
change.

1. **Add an endpoint.** This is currently blocked on the terraform provider
   version. The 2026.8.0 API requires `auth_mode` on endpoint creation
   (`EndpointRequest.required = [auth_mode, host, name, protocol, provider]`; the
   model field carries no default), and `goauthentik/authentik` **2024.12.1**,
   which `stacks/authentik/providers.tf` pins, has no `auth_mode` attribute on
   `authentik_rac_endpoint`. A create from that provider is rejected with a 400.
   Two ways forward, both their own change:
   - bump the authentik terraform provider, which re-plans every provider,
     flow and stage this stack already manages and so wants its own review; or
   - create endpoints in the authentik UI and adopt them with an `import {}`
     block once the provider can express them.

   The intended shape is written out at the bottom of `stacks/authentik/rac.tf`.

2. **Set `local.rac_outpost_replicas = 1`** in `stacks/authentik/rac.tf` and
   apply the stack. Authentik's controller scales the Deployment;
   `ghcr.io/goauthentik/rac:<server version>` is pulled from a registry the
   Kyverno allowlist already covers, and namespace `authentik` is on that
   policy's exclude list in any case.

3. **Add the people who may connect** to the `RAC Users` group.

4. **Watch a real session, not the pod.** Launch the app from the authentik app
   grid and open an endpoint. Session length through Traefik is an open question:
   the `websecure` entrypoint runs `readTimeout=3600s`, `idleTimeout=600s`,
   `writeTimeout=0s`, and those are total-duration caps rather than per-read idle
   timeouts, so measure how long a session actually survives instead of assuming.

## Enabling Postgres LDAP

Two halves. The first is in this stack. The second is a change to the CNPG
cluster and is **not** in the Terraform.

### Half 1: the authentik side (this stack)

1. Set `local.ldap_outpost_replicas = 1` in `stacks/authentik/postgres-ldap.tf`
   and apply. Expect a `ak-outpost-postgres-ldap` Deployment with one replica and
   its Service endpoints to appear.

2. Add the people who may bind to the `Postgres LDAP Users` group.

3. Verify the bind path before touching Postgres at all, from any pod that has
   `ldapsearch` (or a throwaway one):

   ```sh
   ldapsearch -x \
     -H ldap://ak-outpost-postgres-ldap.authentik.svc.cluster.local:389 \
     -D 'cn=<authentik-username>,ou=users,dc=ldap,dc=viktorbarzin,dc=me' \
     -W -b 'dc=ldap,dc=viktorbarzin,dc=me' '(objectClass=user)'
   ```

   A successful bind should also appear as a login event in authentik. A bind
   that hangs or fails is an authentik problem and is much cheaper to debug here
   than through Postgres.

   Two things to know about the bind:
   - `mfa_support = true`, so a user with a TOTP device may append `;<code>` to
     their password. A password that itself contains a semicolon can be misparsed
     and rejected.
   - Directory *searches* need the `authentik_providers_ldap.search_full_directory`
     permission on a service account. Plain binds do not, which is why the
     Postgres recipe below uses simple bind and needs no service account.

### Half 2: the Postgres side, which this change does not make

This is a tier-0 database change to the cluster every stack depends on, so it is
written down rather than applied. It needs its own review before anyone runs it.

**Why it is treated that way.** `pg_hba.conf` is first-match-wins. The live file
today is:

```
# FIXED RULES
local all all peer map=local
hostssl postgres    streaming_replica     all cert map=cnpg_streaming_replica
hostssl replication streaming_replica     all cert map=cnpg_streaming_replica
hostssl all         cnpg_pooler_pgbouncer all cert map=cnpg_pooler_pgbouncer
# USER-DEFINED RULES        <- .spec.postgresql.pg_hba lands here
# DEFAULT RULES
host all all all scram-sha-256
```

CNPG inserts `.spec.postgresql.pg_hba` entries into the USER-DEFINED block,
ahead of the default `scram-sha-256` rule. A rule that is broader than intended
(`host all all all ldap ...`, for instance) would put every application's
service account behind LDAP and take the cluster down for all of them. Scope the
rule to a named database and named roles.

**What the change consists of.**

1. **One or more `pg_hba` lines**, added to the CNPG Cluster in
   `stacks/dbaas/modules/dbaas/main.tf` under `spec.postgresql.pg_hba`. Simple
   bind, which needs no authentik service account, because the outpost resolves
   the provider from the bind DN:

   ```
   host <db> "<role>" 10.10.0.0/16 ldap \
     ldapserver="ak-outpost-postgres-ldap.authentik.svc.cluster.local" \
     ldapport=389 \
     ldapprefix="cn=" \
     ldapsuffix=",ou=users,dc=ldap,dc=viktorbarzin,dc=me"
   ```

   Decisions the reviewer has to take, deliberately left open here:
   - `host` versus `hostssl`. `hostssl` also requires the client's
     connection to Postgres to be TLS, which is stricter and independent of LDAP.
   - Whether the Postgres-to-outpost leg is encrypted. Without `ldaptls=1` the
     password crosses the pod network in the clear on port 389. With `ldaptls=1`
     (StartTLS on 389) or `ldapscheme=ldaps` plus `ldapport=636`, the outpost has
     to present a certificate the Postgres container trusts, which means setting
     `certificate` on the LDAP provider and giving the Postgres pod a CA bundle.
     What the outpost presents when no certificate is configured has not been
     verified; check it before choosing.
   - Which databases and roles. One narrow rule per database is easier to reason
     about than one broad one.

2. **A PostgreSQL role per person.** LDAP authenticates; it does not create
   roles. The role name must match the authentik username, and unquoted
   identifiers fold to lower case, so quote it:

   ```sql
   CREATE ROLE "viktor" LOGIN;
   GRANT CONNECT ON DATABASE <db> TO "viktor";
   -- plus whatever schema and table grants the person actually needs
   ```

3. **Apply mechanics.** The Cluster is a `null_resource.pg_cluster` with a
   `local-exec kubectl apply`, so editing the YAML alone is inert: bump the
   `pg_params` trigger, then apply narrowly with
   `-target=module.dbaas.null_resource.pg_cluster`. In PostgreSQL `pg_hba.conf`
   is reload-only rather than restart-only, but confirm how CNPG rolls the change
   out before scheduling it.

**Prerequisites already verified**, so nobody has to re-check them:

- The image supports LDAP auth. `ghcr.io/viktorbarzin/cnpg-postgis-pgvector:16-pgvector0.8.0`
  runs PostgreSQL 16.9 built `--with-ldap` and links `libldap_r-2.4.so.2`.
- The cluster carries no `pg_hba` entries today, so the USER-DEFINED block is
  empty and an addition collides with nothing.

## What LDAP auth means for the password

Worth stating before anyone is added to the group: PostgreSQL's `ldap` method
sends the password the user typed to the LDAP server for a bind. So a person
authenticating to Postgres this way is typing their authentik SSO password into
`psql`. That is inherent to the method, not to this configuration. The mitigation
available inside authentik is `mfa_support`, which is on.

## Rolling back

The prepare commit is inert, so there is nothing to roll back from it. After
enabling:

- **RAC:** set `local.rac_outpost_replicas = 0` and apply. The Deployment scales
  to zero and live sessions end.
- **Postgres LDAP, authentik side:** set `local.ldap_outpost_replicas = 0` and
  apply. Every LDAP bind then fails.
- **Postgres LDAP, database side:** remove the `pg_hba` lines and re-apply the
  Cluster. Roles created for LDAP users keep existing but can no longer
  authenticate, since no rule routes them to a password method. Removing the
  roles is a separate step.

Emptying the `Postgres LDAP Users` or `RAC Users` group is the quickest way to
cut access without an apply.

## Open questions

- What the LDAP outpost presents on 636 and on StartTLS when the provider has no
  `certificate` set. This decides whether the Postgres leg can be encrypted
  without further work.
- Whether `session_duration = minutes=5` on `ldap-bind-login` is the right value.
  It was chosen to keep `AuthenticatedSession` rows from accumulating in the
  shared Postgres, not measured against real bind volume.
- The 512Mi ceiling on the RAC outpost. It bundles guacd, which allocates per
  active connection; the number is a starting point rather than a measurement.
- How long a RAC session survives through the `websecure` entrypoint.

## Related

- `docs/plans/2026-09-01-service-identity-and-request-attribution-design.md`
- `docs/architecture/authentication.md`
- `stacks/authentik/postgres-ldap.tf`, `stacks/authentik/rac.tf`
- `stacks/dbaas/modules/dbaas/main.tf` (the CNPG Cluster, for half 2)
