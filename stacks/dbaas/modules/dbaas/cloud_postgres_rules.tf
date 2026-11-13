# Cloud's Postgres access (Cloud v1 plan in the cloud repo, "How does Cloud
# create Postgres databases?"; ADR-0003 there). Locals only, so
# tests/cloud-postgres.test.sh can read both values with `terraform console`
# and check them against a real PostgreSQL 18. The resources that use them are
# in cloud_postgres.tf and in null_resource.pg_cluster_v18 (main.tf).
#
# Who owns what: this file creates the three fixed roles and the cloud_state
# database. Every Project role and database (members of cloud_projects) is
# created and dropped by Cloud's reconciler as cloud_provisioner and is owned
# by Cloud's database, not by this repo (AGENTS.md, "Cloud-owned objects").

locals {
  # pg_hba rules for the active CNPG cluster. CNPG writes them between its
  # fixed rules (local peer, streaming_replica and pooler certs) and its
  # default `host all all all scram-sha-256`, and the first matching line
  # wins, so these run before the rule every other app uses. They match only
  # the cloud_* roles and members of cloud_projects; no other role matches any
  # line, so no existing app is affected. A change reloads Postgres; nothing
  # restarts (CNPG docs, "Changing configuration").
  #
  # 1. cloud_provisioner first: it holds ADMIN OPTION on cloud_projects, and
  #    Postgres counts that as membership for `+cloud_projects`, so without
  #    this line rule 5 would lock it into a database named cloud_provisioner.
  # 2-3. cloud_state reaches only its own database. Its password is the
  #    reconciler's state credential; it has no business anywhere else.
  # 4-5. A Project role reaches only the database with its own name
  #    (`sameuser`) and is refused everywhere else, including postgres,
  #    terraform_state and other apps' databases, which PUBLIC can otherwise
  #    CONNECT to by default.
  cloud_pg_hba = [
    "host all cloud_provisioner all scram-sha-256",
    "host cloud_state cloud_state all scram-sha-256",
    "host all cloud_state all reject",
    "host sameuser +cloud_projects all scram-sha-256",
    "host all +cloud_projects all reject",
  ]

  # Run as the superuser on the primary, on every change of this text, and
  # safe to run again: roles and the database are created only when missing,
  # and no statement sets a password, so a rerun never undoes a Vault
  # rotation. Vault's static roles pg-cloud-provisioner and pg-cloud-state
  # (stacks/vault/cloud.tf) set the real passwords on their first run.
  #
  # PG 16+ (live: 18.6) limits CREATEROLE: cloud_provisioner can alter, drop
  # and grant only roles it holds ADMIN OPTION on, which means the roles it
  # created itself plus cloud_projects. It cannot touch any existing app's
  # role or database, and it cannot create SUPERUSER, REPLICATION or
  # BYPASSRLS roles (tests/cloud-postgres.test.sh checks each of these).
  #
  # SET ON PARAMETER temp_file_limit: the parameter is superuser-only, so
  # without this grant cloud_provisioner could not put a temp-file limit on a
  # Project role, and a Project role cannot lift one it was given.
  # statement_timeout needs no grant, but any role can SET it in its own
  # session, so for Project roles it is a default, not a limit.
  cloud_roles_sql = <<-SQL
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'cloud_projects') THEN
        CREATE ROLE cloud_projects NOLOGIN;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'cloud_provisioner') THEN
        CREATE ROLE cloud_provisioner LOGIN PASSWORD 'changeme-vault-will-rotate';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'cloud_state') THEN
        CREATE ROLE cloud_state LOGIN PASSWORD 'changeme-vault-will-rotate';
      END IF;
    END
    $$;
    ALTER ROLE cloud_projects NOLOGIN NOCREATEDB NOCREATEROLE;
    ALTER ROLE cloud_provisioner LOGIN CREATEDB CREATEROLE CONNECTION LIMIT 5;
    ALTER ROLE cloud_state LOGIN NOCREATEDB NOCREATEROLE CONNECTION LIMIT 10;
    GRANT cloud_projects TO cloud_provisioner WITH ADMIN TRUE, INHERIT FALSE, SET FALSE;
    GRANT SET ON PARAMETER temp_file_limit TO cloud_provisioner;
    SELECT 'CREATE DATABASE cloud_state OWNER cloud_state'
      WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database WHERE datname = 'cloud_state')
    \gexec
    REVOKE CONNECT, TEMPORARY ON DATABASE cloud_state FROM PUBLIC;
    GRANT CONNECT, TEMPORARY ON DATABASE cloud_state TO cloud_state;
  SQL
}
