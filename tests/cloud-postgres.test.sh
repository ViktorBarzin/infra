#!/usr/bin/env bash
# Checks the Postgres side of Cloud (Cloud v1 plan, "How does Cloud create
# Postgres databases?") against a real PostgreSQL 18, the major version of the
# live pg-cluster-v18.
#
# stacks/dbaas/modules/dbaas/cloud_postgres_rules.tf holds only locals, so
# `terraform console` reads the pg_hba rules and the role SQL without
# providers, state or credentials. The test builds pg_hba.conf the way CNPG
# does (fixed rules, then .spec.postgresql.pg_hba, then the default
# `host all all all scram-sha-256`), runs the SQL twice as the superuser, and
# then checks what each role can and cannot do over TCP:
#   neither LOGIN role accepts a password before Vault sets one;
#   cloud_provisioner creates a Project role in cloud_projects and its
#     database, sets a temp_file_limit on it, reaches only postgres and p_*
#     databases, and cannot touch an existing app's role or database;
#   a p_* role reaches only the database named after it, never an app
#     database without a role of its own name;
#   granting cloud_projects to an existing role (tasks, postgres) changes
#     nothing about where it can connect;
#   cloud_state reaches only the cloud_state database;
#   an existing app role (tasks) still reaches its own database.
# Needs docker and the postgres:18 image.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/stacks/dbaas/modules/dbaas/cloud_postgres_rules.tf"
IMAGE="${CLOUD_PG_TEST_IMAGE:-postgres:18}"
NAME="cloud-pg-test-$$"

TMP="$(mktemp -d)"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT

cp "$SRC" "$TMP/" || { echo "FAIL: cannot copy $SRC"; exit 1; }
if ! (cd "$TMP" && echo 'local.cloud_roles_sql' | terraform console >"$TMP/sql.raw" 2>"$TMP/err" \
  && echo 'jsonencode(local.cloud_pg_hba)' | terraform console >"$TMP/hba.raw" 2>>"$TMP/err"); then
  echo "FAIL: terraform console could not evaluate $SRC (it must hold only locals)"; cat "$TMP/err"; exit 1
fi
# terraform console prints a multi-line string as <<EOT ... EOT and a
# single-line one as a quoted HCL string.
python3 - "$TMP" <<'PY' || exit 1
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
raw = (d / "sql.raw").read_text().rstrip("\n")
lines = raw.splitlines()
if lines and lines[0].startswith("<<"):
    marker = lines[0].lstrip("<-")
    body = lines[1:]
    if body and body[-1].strip() == marker:
        body = body[:-1]
    sql = "\n".join(body) + "\n"
else:
    sql = json.loads(raw)
(d / "cloud.sql").write_text(sql)
hba = json.loads(json.loads((d / "hba.raw").read_text()))
(d / "rules.json").write_text(json.dumps(hba))
PY

{
  echo "# FIXED RULES (test copy: the superuser through the socket only)"
  echo "local all postgres trust"
  echo "# USER-DEFINED RULES (.spec.postgresql.pg_hba)"
  python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))))' "$TMP/rules.json"
  echo "# DEFAULT RULES"
  echo "host all all all scram-sha-256"
} >"$TMP/pg_hba.conf"

docker run -d --name "$NAME" -e POSTGRES_PASSWORD=unused -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
  "$IMAGE" >/dev/null || { echo "FAIL: cannot start $IMAGE"; exit 1; }
for _ in $(seq 1 60); do
  docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 || { echo "FAIL: postgres did not start"; docker logs "$NAME" | tail; exit 1; }
# The image's first start runs initdb and restarts once; wait for the final server.
sleep 2
for _ in $(seq 1 30); do
  docker exec "$NAME" psql -U postgres -tAc 'select 1' >/dev/null 2>&1 && break
  sleep 1
done
docker exec -i "$NAME" sh -c 'cat > "$PGDATA/pg_hba.conf"' <"$TMP/pg_hba.conf" \
  || { echo "FAIL: cannot install pg_hba.conf"; exit 1; }
docker exec "$NAME" psql -U postgres -qc 'select pg_reload_conf()' >/dev/null

sup() { docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -X -q "$@"; }
# A TCP login as role $1 with password pw-$1 to database $2.
as() { local role="$1" db="$2"; shift 2
  docker exec -i -e PGPASSWORD="pw-$role" "$NAME" psql -h 127.0.0.1 -U "$role" -d "$db" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }

FAILS=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
expect_ok()   { local what="$1"; shift; if out="$("$@" 2>&1)"; then ok "$what"; else bad "$what: $out"; fi; }
expect_fail() { local what="$1" pattern="$2"; shift 2
  if out="$("$@" 2>&1)"; then bad "$what: succeeded, expected failure";
  elif grep -qiE "$pattern" <<<"$out"; then ok "$what"; else bad "$what: wrong error: $out"; fi; }

# The stand-ins for what already lives on the cluster: one app with its own
# database, an app database with no role of its own name (like the live
# dawarich_queue, which PUBLIC may CONNECT to), and the infra Terraform state.
sup <<'SQL' || { echo "FAIL: fixture setup"; exit 1; }
ALTER ROLE postgres PASSWORD 'pw-postgres';
CREATE ROLE tasks LOGIN PASSWORD 'pw-tasks';
CREATE DATABASE tasks OWNER tasks;
CREATE DATABASE dawarich_queue OWNER tasks;
CREATE ROLE terraform_state LOGIN PASSWORD 'pw-terraform_state';
CREATE DATABASE terraform_state OWNER terraform_state;
SQL
as terraform_state terraform_state -c 'CREATE SCHEMA dbaas; CREATE TABLE dbaas.states (id int, data text); INSERT INTO dbaas.states VALUES (1, $$secret$$);' >/dev/null \
  || { echo "FAIL: fixture terraform_state table"; exit 1; }

expect_ok "role SQL runs as the superuser" sup -f - <"$TMP/cloud.sql"
expect_ok "role SQL runs again (idempotent)" sup -f - <"$TMP/cloud.sql"
expect_fail "cloud_provisioner has no password before Vault sets one" "password authentication failed" \
  bash -c "docker exec -e PGPASSWORD=changeme-vault-will-rotate $NAME psql -h 127.0.0.1 -U cloud_provisioner -d postgres -tAc 'select 1'"
expect_fail "cloud_state has no password before Vault sets one" "password authentication failed" \
  bash -c "docker exec -e PGPASSWORD=changeme-vault-will-rotate $NAME psql -h 127.0.0.1 -U cloud_state -d cloud_state -tAc 'select 1'"
# Vault's static roles set the real passwords; stand in for them here.
sup -c "ALTER ROLE cloud_provisioner PASSWORD 'pw-cloud_provisioner'; ALTER ROLE cloud_state PASSWORD 'pw-cloud_state';"

attrs="$(sup -tAc "select string_agg(rolname||':'||rolcanlogin||':'||rolcreatedb||':'||rolcreaterole||':'||rolconnlimit, ' ' order by rolname) from pg_roles where rolname in ('cloud_projects','cloud_provisioner','cloud_state')")"
[ "$attrs" = "cloud_projects:false:false:false:-1 cloud_provisioner:true:true:true:5 cloud_state:true:false:false:10" ] \
  && ok "role attributes ($attrs)" || bad "role attributes: $attrs"
grant="$(sup -tAc "select admin_option||':'||inherit_option||':'||set_option from pg_auth_members where roleid='cloud_projects'::regrole and member='cloud_provisioner'::regrole")"
[ "$grant" = "true:false:false" ] && ok "cloud_provisioner holds ADMIN, not INHERIT or SET, on cloud_projects" || bad "membership options: $grant"
owner="$(sup -tAc "select pg_get_userbyid(datdba) from pg_database where datname='cloud_state'")"
[ "$owner" = "cloud_state" ] && ok "cloud_state database owned by cloud_state" || bad "cloud_state owner: $owner"
# A rerun must not reset a password Vault already rotated.
expect_ok "a rerun keeps the rotated password" bash -c "docker exec -i $NAME psql -U postgres -v ON_ERROR_STOP=1 -X -q -f - <'$TMP/cloud.sql' && docker exec -e PGPASSWORD=pw-cloud_state $NAME psql -h 127.0.0.1 -U cloud_state -d cloud_state -tAc 'select 1'"

# --- cloud_provisioner -------------------------------------------------------
expect_ok "provisioner reaches the postgres database" as cloud_provisioner postgres -c 'select 1'
expect_ok "provisioner creates a Project role in cloud_projects" \
  as cloud_provisioner postgres -c "CREATE ROLE p_demo LOGIN PASSWORD 'pw-p_demo' CONNECTION LIMIT 3 IN ROLE cloud_projects"
expect_ok "provisioner creates the Project database" \
  as cloud_provisioner postgres -c "GRANT p_demo TO cloud_provisioner WITH SET TRUE" -c "CREATE DATABASE p_demo OWNER p_demo" -c "REVOKE CONNECT, TEMPORARY ON DATABASE p_demo FROM PUBLIC"
expect_ok "provisioner sets a temp_file_limit and statement_timeout on its role" \
  as cloud_provisioner postgres -c "ALTER ROLE p_demo SET temp_file_limit = '256MB'" -c "ALTER ROLE p_demo SET statement_timeout = '60s'"
expect_ok "provisioner drops what it created" \
  as cloud_provisioner postgres -c "CREATE ROLE p_gone NOLOGIN IN ROLE cloud_projects" -c "DROP ROLE p_gone"
expect_fail "provisioner cannot alter an existing app role" "permission denied|must have admin" \
  as cloud_provisioner postgres -c "ALTER ROLE tasks CONNECTION LIMIT 1"
expect_fail "provisioner cannot change an existing app role's password" "permission denied|must have admin" \
  as cloud_provisioner postgres -c "ALTER ROLE tasks PASSWORD 'x'"
expect_fail "provisioner cannot drop an existing app database" "must be owner" \
  as cloud_provisioner postgres -c "DROP DATABASE tasks"
expect_fail "provisioner cannot create a superuser" "permission denied|must be superuser|only roles with the SUPERUSER" \
  as cloud_provisioner postgres -c "CREATE ROLE p_root SUPERUSER"
expect_fail "provisioner is refused terraform_state" "pg_hba.conf rejects|no pg_hba.conf entry" \
  as cloud_provisioner terraform_state -c "select * from dbaas.states"
expect_fail "provisioner is refused an app database" "pg_hba.conf rejects|no pg_hba.conf entry" \
  as cloud_provisioner tasks -c 'select 1'
expect_ok "provisioner reaches a Project database" as cloud_provisioner p_demo -c 'select 1'
expect_fail "provisioner cannot grant itself the superuser role" "permission denied|must have admin" \
  as cloud_provisioner postgres -c "GRANT postgres TO cloud_provisioner"

# --- a Project role ----------------------------------------------------------
expect_ok "Project role reaches its own database" as p_demo p_demo -c 'create table t (id int); select 1'
expect_fail "Project role is refused the postgres database" "pg_hba.conf rejects|no pg_hba.conf entry" as p_demo postgres -c 'select 1'
expect_fail "Project role is refused another app's database" "pg_hba.conf rejects|no pg_hba.conf entry" as p_demo tasks -c 'select 1'
expect_fail "Project role is refused terraform_state" "pg_hba.conf rejects|no pg_hba.conf entry" as p_demo terraform_state -c 'select 1'
expect_fail "Project role is refused cloud_state" "pg_hba.conf rejects|no pg_hba.conf entry" as p_demo cloud_state -c 'select 1'
expect_fail "Project role cannot lift its temp_file_limit" "permission denied" as p_demo p_demo -c "SET temp_file_limit = -1"
lim="$(as p_demo p_demo -c 'show temp_file_limit' 2>&1)"
[ "$lim" = "256MB" ] && ok "Project role session carries temp_file_limit=256MB" || bad "temp_file_limit in session: $lim"

# --- cloud_state -------------------------------------------------------------
expect_ok "cloud_state reaches cloud_state and creates a schema" \
  as cloud_state cloud_state -c 'CREATE SCHEMA p_demo; CREATE TABLE p_demo.states (id int)'
expect_fail "cloud_state is refused terraform_state" "pg_hba.conf rejects|no pg_hba.conf entry" as cloud_state terraform_state -c 'select 1'
expect_fail "cloud_state is refused the postgres database" "pg_hba.conf rejects|no pg_hba.conf entry" as cloud_state postgres -c 'select 1'
expect_fail "provisioner is refused cloud_state" "pg_hba.conf rejects|no pg_hba.conf entry" \
  as cloud_provisioner cloud_state -c 'select * from p_demo.states'

# --- names, not group membership ---------------------------------------------
expect_ok "provisioner creates p_dawarich_queue, named after an app database" \
  as cloud_provisioner postgres -c "CREATE ROLE p_dawarich_queue LOGIN PASSWORD 'pw-p_dawarich_queue' IN ROLE cloud_projects"
expect_fail "p_dawarich_queue is refused the dawarich_queue database" "pg_hba.conf rejects|no pg_hba.conf entry" \
  as p_dawarich_queue dawarich_queue -c 'select 1'
expect_ok "provisioner grants cloud_projects to tasks and postgres (ADMIN OPTION allows it)" \
  as cloud_provisioner postgres -c "GRANT cloud_projects TO tasks" -c "GRANT cloud_projects TO postgres"
expect_ok "tasks, now in cloud_projects, still reaches tasks" as tasks tasks -c 'select 1'
expect_ok "tasks, now in cloud_projects, still reaches dawarich_queue" as tasks dawarich_queue -c 'select 1'
expect_ok "postgres, now in cloud_projects, still reaches tasks over TCP" as postgres tasks -c 'select 1'

# --- nothing else changed ----------------------------------------------------
expect_ok "an existing app role still reaches its database" as tasks tasks -c 'select 1'
expect_ok "terraform_state still reaches its database" as terraform_state terraform_state -c 'select count(*) from dbaas.states'

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: cloud postgres roles and pg_hba"; else echo "FAIL: $FAILS check(s)"; exit 1; fi
