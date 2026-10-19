# shellcheck shell=bash
# Verify checks for stacks/beads-server, the Dolt SQL server behind beads and
# presence (docs/runbooks/verify-jobs.md). The probe logs in as the `beads`
# user (empty password, as every bd client does) and writes only to a scratch
# database it drops.
VERIFY_GROUP="db"
VERIFY_NAMESPACES="beads-server"
VERIFY_ALERTNAMES="^(Dolt.*|Beads.*)$"

MYSQL_IMAGE=docker.io/library/mysql:8.4.8

DOLT_PROBE='
set -eu
m() { mysql -h dolt.beads-server.svc.cluster.local -u beads --connect-timeout=10 -N -B -e "$1"; }
echo "dolt $(m "select dolt_version()")"
n=$(m "select count(*) from code.issues"); echo "code.issues rows: $n"
[ "$n" -gt 100 ]
p=$(m "select count(*) from beads.presence_claims"); echo "beads.presence_claims rows: $p"
c=$(m "select count(*) from code.dolt_log"); echo "code.dolt_log commits: $c"
[ "$c" -gt 100 ]
m "select max(length(description)), max(length(notes)) from code.issues" >/dev/null
D=verify_probe_$(date +%s)
m "create database $D"
m "create table $D.t (id int primary key, v varchar(8))"
m "insert into $D.t values (1, '"'"'ok'"'"')"
v=$(m "select v from $D.t where id = 1")
m "drop database $D"
echo "scratch database written, read back ($v), dropped"
[ "$v" = ok ]
'

_probe() { run_pod dolt-probe "$MYSQL_IMAGE" "$DOLT_PROBE" timeout=300 memory=256Mi; }

verify_component() {
  check "dolt converged" retry 300 10 workload_ready beads-server deployment/dolt
  check "Dolt: data readable, scratch database write/read/drop" _probe
  check "beadboard converged" retry 300 10 workload_ready beads-server deployment/beadboard
  check "dolt-workbench converged" retry 300 10 workload_ready beads-server deployment/dolt-workbench
  check "no panic or corruption in Dolt logs (30m)" expect_no_log_errors beads-server app=dolt 'panic|fatal|corrupt|manifest.*error' 30m
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    check "dolt-backup Job completes (dump + restore check)" run_cronjob beads-server dolt-backup 900
  fi
}
