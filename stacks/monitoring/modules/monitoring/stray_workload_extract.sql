-- Project every workload Terraform DECLARES out of the Tier-1 state backend.
--
-- Tier-1 state lives in the `terraform_state` database on the CNPG cluster
-- (see the root terragrunt.hcl: `backend = "pg"`, one schema per stack, table
-- `states`, column `data` holding the whole state document as text). That
-- makes the declared set readable from inside the cluster over an ordinary
-- read-only Postgres connection, which is what lets the reconciler run as a
-- CronJob at all.
--
-- Tier-0 stacks (infra, platform, cnpg, vault, dbaas, external-secrets) keep
-- LOCAL state in the repo and are not visible here. Their 11 workloads come
-- from declared_tier0.json instead — see scripts/gen-tier0-workload-inventory.py.
--
-- Shape: one line per declaration, `kind|namespace|name|stack`, pipe-separated,
-- via `psql -At -F'|'`. `HelmRelease` rows are release coordinates, not
-- workloads: a chart's Deployments carry meta.helm.sh/release-name and are
-- matched back to the release by the reconciler.
--
-- The heavy work (casting ~160 multi-MB state documents to jsonb) stays
-- server-side; the client only ever sees the ~330-row projection. Measured
-- 2026-09-01: 1.3s wall, 328 rows, ~50 MiB psql RSS.
--
-- Every statement runs in ONE psql session via \gexec. ON_ERROR_STOP=1 is set
-- on the command line so a schema the reader role cannot SELECT aborts the
-- whole extraction rather than quietly producing a SHORT inventory — a short
-- inventory would read as "the cluster is full of stray workloads".

SELECT format($q$
SELECT CASE r->>'type'
         WHEN 'helm_release'                 THEN 'HelmRelease'
         WHEN 'kubernetes_deployment'        THEN 'Deployment'
         WHEN 'kubernetes_deployment_v1'     THEN 'Deployment'
         WHEN 'kubernetes_stateful_set'      THEN 'StatefulSet'
         WHEN 'kubernetes_stateful_set_v1'   THEN 'StatefulSet'
         WHEN 'kubernetes_daemonset'         THEN 'DaemonSet'
         WHEN 'kubernetes_daemon_set'        THEN 'DaemonSet'
         WHEN 'kubernetes_daemon_set_v1'     THEN 'DaemonSet'
         WHEN 'kubernetes_cron_job'          THEN 'CronJob'
         WHEN 'kubernetes_cron_job_v1'       THEN 'CronJob'
       END,
       -- kubernetes_* resources keep metadata as a single-element LIST;
       -- helm_release keeps name/namespace at the top level.
       coalesce(i->'attributes'->'metadata'->0->>'namespace', i->'attributes'->>'namespace'),
       coalesce(i->'attributes'->'metadata'->0->>'name',      i->'attributes'->>'name'),
       %1$L
FROM %1$I.states st,
     LATERAL jsonb_array_elements((st.data::jsonb)->'resources') r,
     LATERAL jsonb_array_elements(coalesce(r->'instances', '[]'::jsonb)) i
WHERE r->>'mode' = 'managed'
  AND r->>'type' = ANY (ARRAY['helm_release','kubernetes_deployment','kubernetes_deployment_v1',
                              'kubernetes_stateful_set','kubernetes_stateful_set_v1',
                              'kubernetes_daemonset','kubernetes_daemon_set','kubernetes_daemon_set_v1',
                              'kubernetes_cron_job','kubernetes_cron_job_v1'])
UNION ALL
-- No workload is declared through kubernetes_manifest today (checked
-- 2026-09-01: 192 instances, all ExternalSecret / IngressRoute / Middleware /
-- ClusterPolicy). Covered anyway so that declaring one later does not read as
-- a stray workload. kubernetes_manifest stores the object as a cty-typed pair,
-- so the values live under ->'value', not directly under ->'manifest'.
SELECT i->'attributes'->'manifest'->'value'->>'kind',
       i->'attributes'->'manifest'->'value'->'metadata'->>'namespace',
       i->'attributes'->'manifest'->'value'->'metadata'->>'name',
       %1$L
FROM %1$I.states st,
     LATERAL jsonb_array_elements((st.data::jsonb)->'resources') r,
     LATERAL jsonb_array_elements(coalesce(r->'instances', '[]'::jsonb)) i
WHERE r->>'mode' = 'managed'
  AND r->>'type' = 'kubernetes_manifest'
  AND i->'attributes'->'manifest'->'value'->>'kind'
      = ANY (ARRAY['Deployment','StatefulSet','DaemonSet','CronJob'])
$q$, nspname)
FROM pg_namespace n
JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = 'states' AND c.relkind = 'r'
WHERE nspname NOT IN ('pg_catalog', 'information_schema', 'public')
ORDER BY nspname
\gexec
