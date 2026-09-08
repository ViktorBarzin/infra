-- Create the reconciler's read-only login on the Tier-1 state database.
--
-- Run by the stray-workload-detect-db-init Job (stray_workload.tf) as the CNPG
-- superuser `root`, connected to `terraform_state`, on every apply. Idempotent:
-- the role is created or its password reset, and every grant is re-issued.
--
-- Why a dedicated role rather than reusing `pg-terraform-state`: that
-- credential can WRITE state, and state-write is arbitrary infrastructure
-- takeover on the next apply. Putting it in a Secret in the monitoring
-- namespace would widen that blast radius for a job that only ever SELECTs.
--
-- Everything here is cluster- or database-scoped from the current connection,
-- so there is no \connect: CREATE ROLE and GRANT ... ON DATABASE work from any
-- database, and the default-privileges and per-schema grants want to run
-- against terraform_state, which is where we already are. That also makes the
-- whole file testable by wrapping it in BEGIN / ROLLBACK.
--
-- Called with: psql -v ON_ERROR_STOP=1 -v reader_password="$READER_PASSWORD"
-- The variable is interpolated at the top level of an ordinary statement (never
-- inside a dollar-quoted block, where psql does not substitute) and %L quotes
-- it as a literal.

\set reader tf_state_reader

-- Create the role, or reset its password if a previous apply already made it.
SELECT format('%s ROLE %I WITH LOGIN PASSWORD %L',
              CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'reader')
                   THEN 'ALTER' ELSE 'CREATE' END,
              :'reader', :'reader_password')
\gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'reader')
\gexec

-- Future schemas and tables. The pg backend creates a schema per stack as
-- `terraform_state` (verified 2026-09-01: all 162 state schemas are owned by
-- that role), so these two lines cover every stack added from now on without
-- anyone remembering to re-grant.
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE terraform_state GRANT USAGE ON SCHEMAS TO %I', :'reader')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE terraform_state GRANT SELECT ON TABLES TO %I', :'reader')
\gexec

-- Catch up the schemas that already exist: default privileges are not
-- retroactive. Scoped to schemas that actually hold a `states` table, so the
-- reader gets nothing beyond what the projection reads.
SELECT format('GRANT USAGE ON SCHEMA %I TO %I', nspname, :'reader')
FROM pg_namespace n
JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = 'states' AND c.relkind = 'r'
WHERE nspname NOT IN ('pg_catalog', 'information_schema', 'public')
\gexec
SELECT format('GRANT SELECT ON TABLE %I.states TO %I', nspname, :'reader')
FROM pg_namespace n
JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = 'states' AND c.relkind = 'r'
WHERE nspname NOT IN ('pg_catalog', 'information_schema', 'public')
\gexec
