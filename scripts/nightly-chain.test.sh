#!/bin/bash
# Tests for scripts/nightly-chain.sh. kubectl, systemctl and curl are stubs
# that log every call to $CALLS; the kured lock helper is replaced by
# functions driven by $LOCK_RC. No cluster or host access.
# Run: bash scripts/nightly-chain.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

CALLS=$WORK/calls
WORK_METRICS=$WORK/metrics
CRONJOBS_FILE=$WORK/cronjobs.json
cat >"$CRONJOBS_FILE" <<'JSON'
{"items":[
 {"metadata":{"namespace":"dbaas","name":"postgresql-backup","annotations":{"backup.viktorbarzin.me/nightly-chain":"daily"}}},
 {"metadata":{"namespace":"vault","name":"vault-raft-backup","annotations":{"backup.viktorbarzin.me/nightly-chain":"sunday"}}},
 {"metadata":{"namespace":"headscale","name":"headscale-backup","annotations":{}}},
 {"metadata":{"namespace":"default","name":"backup-etcd","annotations":{"backup.viktorbarzin.me/nightly-chain":"daily"}}}]}
JSON

cat >"$WORK/kubectl" <<'STUB'
#!/bin/bash
echo "kubectl $*" >>"$CALLS"
case "$*" in
  "get --raw /readyz") [ "${API_DOWN:-0}" = 1 ] && exit 1; echo ok ;;
  "get cronjobs -A -o json") cat "$CRONJOBS_FILE" ;;
  create\ job*) exit 0 ;;
  get\ cronjob\ -n*)
    # lastSuccessfulTime after (GONE_OK=1) or before the dump started
    if [ "${GONE_OK:-0}" = 1 ]; then t=2099-01-01T00:00:00Z; else t=2000-01-01T00:00:00Z; fi
    echo "{\"status\":{\"lastSuccessfulTime\":\"$t\"}}" ;;
  get\ job*)
    case "$*" in
      *"${GONE_JOB:-none}"*) echo 'Error from server (NotFound): jobs.batch not found' >&2; exit 1 ;;
      *"${FAIL_JOB:-none}"*) echo '{"status":{"conditions":[{"type":"Failed","status":"True"}]}}' ;;
      *) echo '{"status":{"conditions":[{"type":"Complete","status":"True"}]}}' ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
cat >"$WORK/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >>"$CALLS"
[ "$3" = "${FAIL_UNIT:-none}.service" ] && exit 1
exit 0
STUB
cat >"$WORK/curl" <<'STUB'
#!/bin/bash
cat >>"$WORK_METRICS"
exit 0
STUB
chmod +x "$WORK/kubectl" "$WORK/systemctl" "$WORK/curl"

run_chain() { # [args...] -> prints the log; leaves $CALLS and $WORK_METRICS
  : >"$CALLS"
  : >"$WORK_METRICS"
  (
    export PATH="$WORK:$PATH" CALLS WORK_METRICS CRONJOBS_FILE
    export NIGHTLY_CHAIN_POLL=0 NIGHTLY_CHAIN_LOCK_LIB=/dev/null NIGHTLY_CHAIN_SOURCE_ONLY=1
    # shellcheck source=nightly-chain.sh
    . "$HERE/nightly-chain.sh"
    kured_lock_acquire() { echo "lock acquire $1" >>"$CALLS"; return "${LOCK_RC:-0}"; }
    kured_lock_release() { echo "lock release $1" >>"$CALLS"; }
    main "$@"
    echo "rc=$?"
  )
}
order() { grep -n -E "$1" "$CALLS" | head -1 | cut -d: -f1; }

out=$(NIGHTLY_CHAIN_DOW=3 run_chain)
grep -q "create job.*postgresql-backup-chain" "$CALLS" && grep -q "create job.*backup-etcd-chain" "$CALLS" \
  && ok "weekday: the daily dumps run" || bad "weekday dumps: $(cat "$CALLS")"
grep -q "vault-raft-backup" "$CALLS" && bad "weekday ran a Sunday dump" || ok "weekday: the Sunday dump does not run"
grep -q "headscale-backup" "$CALLS" && bad "ran a CronJob without the annotation" || ok "CronJobs without the annotation are left alone"
grep -q "create job -n dbaas postgresql-backup-chain-[0-9]* --from=cronjob/postgresql-backup" "$CALLS" \
  && ok "dump Jobs are created from their CronJob" || bad "create form: $(grep create "$CALLS")"
eq_last=$(tail -1 <<<"$out")
[ "$eq_last" = "rc=0" ] && ok "a clean night exits 0" || bad "clean night: $out"

out=$(NIGHTLY_CHAIN_DOW=7 run_chain)
grep -q "create job -n vault vault-raft-backup-chain" "$CALLS" && ok "Sunday: the Sunday dump runs too" || bad "sunday: $(cat "$CALLS")"

out=$(NIGHTLY_CHAIN_DOW=3 run_chain)
steps=$(grep -o 'systemctl start --wait [a-z0-9.-]*' "$CALLS" | awk '{print $4}' | tr '\n' ' ')
[ "$steps" = "nfs-mirror.service lvm-pvc-snapshot.service daily-backup.service devvm-home-backup.service t3-state-pull.service offsite-sync-backup.service " ] \
  && ok "host steps run in dependency order" || bad "host order: [$steps]"
# t3-state-pull writes /mnt/backup/t3-state, so it must finish before
# offsite-sync-backup copies /mnt/backup to the Synology.
[ "$(order 'systemctl start --wait t3-state-pull')" -lt "$(order 'systemctl start --wait offsite-sync-backup')" ] \
  && ok "the T3 snapshot pull runs before the offsite copy" || bad "t3 vs offsite: $(cat "$CALLS")"
last_dump=$(grep -n 'get job' "$CALLS" | tail -1 | cut -d: -f1)
[ "$last_dump" -lt "$(order 'systemctl start --wait nfs-mirror')" ] && ok "host steps start only after every dump finished" || bad "dumps vs host: $(cat "$CALLS")"
[ "$(order 'lock acquire')" -lt "$(order 'create job')" ] && [ "$(order 'lock release')" -gt "$(order 'offsite-sync-backup')" ] \
  && ok "the kured lock covers the whole night" || bad "lock span: $(cat "$CALLS")"
grep -q 'nightly_chain_last_success_timestamp' "$WORK_METRICS" && ok "a clean night records last success" || bad "success metric: $(cat "$WORK_METRICS")"

out=$(NIGHTLY_CHAIN_DOW=3 FAIL_UNIT=lvm-pvc-snapshot run_chain)
grep -q 'systemctl start --wait offsite-sync-backup' "$CALLS" && ok "a failed step does not stop the later ones" || bad "continue after fail: $(cat "$CALLS")"
[ "$(tail -1 <<<"$out")" = "rc=1" ] && ok "a failed step makes the night exit 1" || bad "fail rc: $out"
grep -q 'nightly_chain_step_ok{step="lvm-pvc-snapshot"} 0' "$WORK_METRICS" && ok "the failed step is reported" || bad "step metric: $(cat "$WORK_METRICS")"
grep -q 'nightly_chain_last_success_timestamp' "$WORK_METRICS" && bad "failed night recorded success" || ok "a failed night does not record success"

out=$(NIGHTLY_CHAIN_DOW=3 FAIL_JOB=backup-etcd run_chain)
grep -q 'nightly_chain_step_ok{step="default/backup-etcd"} 0' "$WORK_METRICS" && ok "a failed dump is reported" || bad "dump metric: $(cat "$WORK_METRICS")"
grep -q 'systemctl start --wait nfs-mirror' "$CALLS" && ok "host steps still run after a failed dump" || bad "after dump fail: $(cat "$CALLS")"

out=$(NIGHTLY_CHAIN_DOW=3 LOCK_RC=75 run_chain)
grep -q 'create job' "$CALLS" && grep -q 'systemctl start --wait offsite' "$CALLS" \
  && ok "lock still held after the wait: the night runs anyway" || bad "lock timeout: $(cat "$CALLS")"
grep -q 'nightly_chain_lock_acquired 0' "$WORK_METRICS" && ok "running without the lock is reported" || bad "lock metric: $(cat "$WORK_METRICS")"
grep -q 'lock release' "$CALLS" && bad "released a lock it never took" || ok "no release without the lock"

out=$(NIGHTLY_CHAIN_DOW=3 API_DOWN=1 run_chain)
grep -q 'create job' "$CALLS" && bad "created Jobs with the API down" || ok "API down: no dumps"
grep -q 'systemctl start --wait daily-backup' "$CALLS" && ok "API down: host backups still run" || bad "api down host: $(cat "$CALLS")"
[ "$(tail -1 <<<"$out")" = "rc=1" ] && ok "API down counts as a failed night" || bad "api down rc: $out"

out=$(NIGHTLY_CHAIN_DOW=3 run_chain --only backup-etcd,daily-backup)
grep -q 'postgresql-backup' "$CALLS" && bad "--only ran another dump" || ok "--only limits the dumps"
steps=$(grep -o 'systemctl start --wait [a-z0-9.-]*' "$CALLS" | awk '{print $4}' | tr '\n' ' ')
[ "$steps" = "daily-backup.service " ] && ok "--only limits the host steps" || bad "--only steps: [$steps]"
grep -q 'nightly_chain_last_success_timestamp' "$WORK_METRICS" && bad "--only recorded a full-night success" || ok "--only does not record a full-night success"

# Many backup CronJobs set ttlSecondsAfterFinished: 10, so the Job is deleted
# before the next 30 s poll sees it finish (2026-11-11: mysql, drone-logbook
# and mailserver succeeded and the first live run waited on them for an hour).
# A Job that is gone counts as done when its CronJob's lastSuccessfulTime is
# after the dump started, and as failed otherwise.
out=$(NIGHTLY_CHAIN_DOW=3 GONE_JOB=backup-etcd GONE_OK=1 run_chain)
grep -q 'nightly_chain_step_ok{step="default/backup-etcd"} 1' "$WORK_METRICS" && ok "a Job deleted by its TTL after succeeding counts as done" || bad "gone ok: $(cat "$WORK_METRICS") $out"
out=$(NIGHTLY_CHAIN_DOW=3 GONE_JOB=backup-etcd GONE_OK=0 run_chain)
grep -q 'nightly_chain_step_ok{step="default/backup-etcd"} 0' "$WORK_METRICS" && ok "a Job that vanished without a success counts as failed" || bad "gone failed: $(cat "$WORK_METRICS") $out"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
