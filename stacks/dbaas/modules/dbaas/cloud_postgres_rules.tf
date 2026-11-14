# Cloud's Postgres access (Cloud v1 plan in the cloud repo, "How does Cloud
# create Postgres databases?"; ADR-0003 there). Locals only, so
# tests/cloud-postgres.test.sh can read both values with `terraform console`
# and check them against a real PostgreSQL 18. The resources that use them are
# in cloud_postgres.tf and in null_resource.pg_cluster_v18 (main.tf).
#
# Who owns what: this file creates the three fixed roles and the cloud_state
# database. Every Project role and database (p_*, members of cloud_projects) is
# created and dropped by Cloud's reconciler as cloud_provisioner and is owned
# by Cloud's database, not by this repo (AGENTS.md, "Cloud-owned objects").

locals {
  # pg_hba rules for the active CNPG cluster. CNPG writes them between its
  # fixed rules (local peer, streaming_replica and pooler certs) and its
  # default `host all all all scram-sha-256`, and the first matching line
  # wins, so these run before the rule every other app uses. A change reloads
  # Postgres; nothing restarts (CNPG docs, "Changing configuration").
  #
  # Project roles are matched by NAME, never by membership of cloud_projects.
  # cloud_provisioner holds ADMIN OPTION on that group and can grant it to any
  # existing role, postgres included; a membership rule would then lock the
  # grantee out of every database not named after it. With name rules, a
  # grant of cloud_projects changes nobody's network access, and the group
  # exists only to hold grants. Regex user and database fields need PG 16+
  # (live: 18).
  #
  # The reconciler names every Project role and database p_<name> and refuses
  # a name that matches an existing role or database. Checked live on
  # 2026-11-13: no role or database name starts with p_, so no existing app
  # matches lines 4 to 8.
  #
  # 1-3. cloud_provisioner reaches the postgres maintenance database (CREATE
  #    ROLE, CREATE DATABASE) and Project databases, nothing else. Other app
  #    databases grant CONNECT to PUBLIC, so without line 3 it could read their
  #    catalogs and create TEMP tables there.
  # 4-5. cloud_state reaches only its own database. Its password is the
  #    reconciler's state credential; it has no business anywhere else.
  # 6-7. A p_* role reaches only the database with its own name (`sameuser`)
  #    and is refused everywhere else, including postgres, terraform_state and
  #    other apps' databases. No app database starts with p_, so `sameuser`
  #    cannot land a Project role in one.
  cloud_pg_hba = [
    "host postgres cloud_provisioner all scram-sha-256",
    "host \"/^p_[a-z0-9_]+$\" cloud_provisioner all scram-sha-256",
    "host all cloud_provisioner all reject",
    "host cloud_state cloud_state all scram-sha-256",
    "host all cloud_state all reject",
    "host sameuser \"/^p_[a-z0-9_]+$\" all scram-sha-256",
    "host all \"/^p_\" all reject",
  ]

  # Run as the superuser on the primary, on every change of this text, and
  # safe to run again: roles and the database are created only when missing,
  # and no statement sets a password, so a rerun never undoes a Vault
  # rotation. Both LOGIN roles start with PASSWORD NULL, so nobody can sign in
  # as them until Vault's static roles pg-cloud-provisioner and pg-cloud-state
  # (stacks/vault/cloud.tf) set the real passwords on their first rotation.
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
  #
  # search_path = pg_catalog, pg_temp on cloud_provisioner: it connects into
  # Project databases (the reconciler's postgresql_grant resources do, and
  # their provider runs unqualified pg_advisory_xact_lock, pg_roles and
  # pg_database there). A Project role owns its database, so it can run
  # ALTER DATABASE <own> SET search_path = public, pg_catalog and plant
  # public.pg_advisory_xact_lock(bigint); the next statement cloud_provisioner
  # runs there would call it with cloud_provisioner's rights, which include
  # changing every other p_* role's password. A role setting outranks a
  # database setting, and only a role with ADMIN on cloud_provisioner (the
  # superuser) can set one for it per database, so the planted function is
  # never found. tests/cloud-postgres.test.sh plants that trap. Any other role
  # that ever connects into a p_* database needs the same setting.
  # The audit behind alert CloudProvisionerForeignRole (stacks/monitoring):
  # how many roles cloud_provisioner administers, directly or through a role
  # it administers, whose name is not p_*. pg_hba confines only p_* names, so
  # a role it created under another name (or renamed) falls through to
  # `host all all all scram-sha-256` and reaches every database that grants
  # CONNECT to PUBLIC. Postgres records the creator of a role as holding
  # ADMIN OPTION on it, granted by the bootstrap superuser, so the creator
  # cannot revoke that record to hide a role. cloud_projects is excluded:
  # this repo grants it. Exported by the CNPG exporter from the primary as
  # cnpg_cloud_provisioner_foreign_roles_count (pg_custom_queries in main.tf).
  cloud_provisioner_audit_sql = <<-SQL
    WITH RECURSIVE administered AS (
      SELECT m.roleid FROM pg_catalog.pg_auth_members m
        JOIN pg_catalog.pg_roles p ON p.oid = m.member
       WHERE p.rolname = 'cloud_provisioner' AND m.admin_option
      UNION
      SELECT m.roleid FROM pg_catalog.pg_auth_members m
        JOIN administered a ON a.roleid = m.member
       WHERE m.admin_option
    )
    SELECT count(*) AS count
      FROM administered a JOIN pg_catalog.pg_roles r ON r.oid = a.roleid
     WHERE r.rolname != 'cloud_projects' AND r.rolname !~ '^p_[a-z0-9_]+$'
  SQL

  # The audit behind alerts CloudProjectRoleUnlimited and
  # CloudProjectConnectionsOverCeiling (stacks/monitoring), M2 contract point
  # 9. Postgres cannot cap the sum of CONNECTION LIMITs across roles, so the
  # Cloud-wide ceiling of 20 lives in the reconciler; this detects when it
  # does not hold. Over the LOGIN roles cloud_provisioner administers
  # (directly or through a role it administers, cloud_projects excluded):
  #   unlimited       how many have CONNECTION LIMIT -1 (none) or above 8, the
  #                   largest Size's limit (medium); a stolen provisioner
  #                   credential could otherwise open connections until the
  #                   cluster's non-superuser slots run out
  #   connlimit_sum   the sum of their CONNECTION LIMITs, -1 counted as 0
  #                   (the first gauge catches it)
  # Detection, not enforcement. Exported by the CNPG exporter from the primary
  # as cnpg_cloud_provisioner_role_limits_unlimited and
  # cnpg_cloud_provisioner_role_limits_connlimit_sum.
  cloud_role_limits_audit_sql = <<-SQL
    WITH RECURSIVE administered AS (
      SELECT m.roleid FROM pg_catalog.pg_auth_members m
        JOIN pg_catalog.pg_roles p ON p.oid = m.member
       WHERE p.rolname = 'cloud_provisioner' AND m.admin_option
      UNION
      SELECT m.roleid FROM pg_catalog.pg_auth_members m
        JOIN administered a ON a.roleid = m.member
       WHERE m.admin_option
    )
    SELECT count(*) FILTER (WHERE r.rolconnlimit < 0 OR r.rolconnlimit > 8) AS unlimited,
           coalesce(sum(greatest(r.rolconnlimit, 0)), 0) AS connlimit_sum
      FROM administered a JOIN pg_catalog.pg_roles r ON r.oid = a.roleid
     WHERE r.rolname != 'cloud_projects' AND r.rolcanlogin
  SQL

  cloud_roles_sql = <<-SQL
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'cloud_projects') THEN
        CREATE ROLE cloud_projects NOLOGIN;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'cloud_provisioner') THEN
        CREATE ROLE cloud_provisioner LOGIN PASSWORD NULL;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'cloud_state') THEN
        CREATE ROLE cloud_state LOGIN PASSWORD NULL;
      END IF;
    END
    $$;
    ALTER ROLE cloud_projects NOLOGIN NOCREATEDB NOCREATEROLE;
    ALTER ROLE cloud_provisioner LOGIN CREATEDB CREATEROLE CONNECTION LIMIT 5;
    ALTER ROLE cloud_state LOGIN NOCREATEDB NOCREATEROLE CONNECTION LIMIT 10;
    GRANT cloud_projects TO cloud_provisioner WITH ADMIN TRUE, INHERIT FALSE, SET FALSE;
    GRANT SET ON PARAMETER temp_file_limit TO cloud_provisioner;
    ALTER ROLE cloud_provisioner SET search_path = pg_catalog, pg_temp;
    SELECT 'CREATE DATABASE cloud_state OWNER cloud_state'
      WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database WHERE datname = 'cloud_state')
    \gexec
    REVOKE CONNECT, TEMPORARY ON DATABASE cloud_state FROM PUBLIC;
    GRANT CONNECT, TEMPORARY ON DATABASE cloud_state TO cloud_state;
  SQL
}
