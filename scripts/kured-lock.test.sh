#!/bin/bash
# Tests for scripts/kured-lock.sh. kubectl is a stub that keeps the kured
# DaemonSet's annotations and resourceVersion in a file and refuses an
# annotate whose --resource-version is stale, like the API server does.
# Run: bash scripts/kured-lock.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

STATE=$WORK/ds.json
cat >"$WORK/kubectl" <<'STUB'
#!/bin/bash
# Stub: get ds kured -n kured -o json | annotate ds/kured ... key=value|key-
STATE=${STUB_STATE:?}
case "$1" in
  get) cat "$STATE" ;;
  annotate)
    shift
    rv="" kv=""
    for a in "$@"; do
      case "$a" in
        --resource-version=*) rv=${a#--resource-version=} ;;
        -*|ds/kured|kured) ;;
        *) kv=$a ;;
      esac
    done
    cur=$(jq -r '.metadata.resourceVersion' "$STATE")
    if [ -n "$rv" ] && [ "$rv" != "$cur" ]; then
      echo 'Error from server (Conflict): the object has been modified' >&2
      exit 1
    fi
    next=$((cur + 1))
    if [ "${kv%-}" != "$kv" ] && [ "${kv#*=}" = "$kv" ]; then
      jq --arg k "${kv%-}" --arg rv "$next" 'del(.metadata.annotations[$k]) | .metadata.resourceVersion=$rv' "$STATE" >"$STATE.new"
    else
      jq --arg k "${kv%%=*}" --arg v "${kv#*=}" --arg rv "$next" '.metadata.annotations[$k]=$v | .metadata.resourceVersion=$rv' "$STATE" >"$STATE.new"
    fi
    mv "$STATE.new" "$STATE"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WORK/kubectl"

reset() { # [annotation-json]
  if [ -n "${1:-}" ]; then
    jq -n --arg v "$1" '{metadata:{resourceVersion:"10",annotations:{"weave.works/kured-node-lock":$v}}}' >"$STATE"
  else
    echo '{"metadata":{"resourceVersion":"10","annotations":{}}}' >"$STATE"
  fi
}
holder() { jq -r '.metadata.annotations["weave.works/kured-node-lock"] // "" | if . == "" then "" else (fromjson | .nodeID) end' "$STATE"; }

run() { # <function and args...> -> rc
  (
    export KUBECTL="$WORK/kubectl" STUB_STATE="$STATE" KURED_LOCK_POLL=0
    # shellcheck source=kured-lock.sh
    . "$HERE/kured-lock.sh"
    "$@"
  )
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%S.123456789Z)
OLD=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)
KURED_HELD="{\"nodeID\":\"k8s-node3\",\"metadata\":{\"unschedulable\":false},\"created\":\"$NOW\",\"TTL\":0}"
STALE="{\"nodeID\":\"pve-nightly-chain\",\"metadata\":{\"unschedulable\":false},\"created\":\"$OLD\",\"TTL\":3600000000000}"

reset
run kured_lock_try k8s-upgrade-chain 3600 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ "$(holder)" = k8s-upgrade-chain ] && ok "free lock is taken" || bad "free lock: rc=$rc holder=$(holder)"
jq -e '.metadata.annotations["weave.works/kured-node-lock"] | fromjson | .TTL == 3600000000000 and (.created | test("Z$")) and .metadata.unschedulable == false' "$STATE" >/dev/null \
  && ok "annotation uses kured's format (TTL in ns, RFC3339 created)" || bad "annotation format: $(cat "$STATE")"

run kured_lock_try k8s-upgrade-chain 3600 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "taking a lock you already hold succeeds" || bad "re-entrant: rc=$rc"

reset "$KURED_HELD"
out=$(run kured_lock_try pve-nightly-chain 3600); rc=$?
[ "$rc" -eq 1 ] && [ "$(holder)" = k8s-node3 ] && ok "a lock kured holds (TTL 0) is not taken" || bad "kured-held: rc=$rc holder=$(holder)"
grep -q k8s-node3 <<<"$out" && ok "a refused try names the holder" || bad "refused output: $out"

reset "$STALE"
run kured_lock_try k8s-upgrade-chain 3600 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ "$(holder)" = k8s-upgrade-chain ] && ok "an expired lock is taken over" || bad "expired: rc=$rc holder=$(holder)"

reset
run kured_lock_try_at_rv k8s-upgrade-chain 3600 9 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ -z "$(holder)" ] && ok "a write at a stale resourceVersion loses" || bad "conflict: rc=$rc holder=$(holder)"

reset "$KURED_HELD"
out=$(run kured_lock_acquire pve-nightly-chain 3600 0); rc=$?
[ "$rc" -eq 75 ] && ok "acquire gives up with 75 when the wait runs out" || bad "acquire timeout: rc=$rc $out"

reset "$KURED_HELD"
run kured_lock_release pve-nightly-chain >/dev/null; rc=$?
[ "$(holder)" = k8s-node3 ] && ok "release never removes someone else's lock" || bad "foreign release: holder=$(holder)"

reset
run kured_lock_try pve-nightly-chain 3600 >/dev/null
run kured_lock_release pve-nightly-chain >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ -z "$(holder)" ] && ok "release removes your own lock" || bad "own release: rc=$rc holder=$(holder)"

reset
run kured_lock_release pve-nightly-chain >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "releasing a free lock is a no-op" || bad "free release: rc=$rc"

# upgrade-step.sh runs under set -euo pipefail. A busy lock must come back as
# a return code there, not kill the script from inside the retry loop.
reset "$KURED_HELD"
out=$(KUBECTL="$WORK/kubectl" STUB_STATE="$STATE" KURED_LOCK_POLL=0 bash -euo pipefail -s "$HERE/kured-lock.sh" <<'SCRIPT'
. "$1"
rc=0
kured_lock_acquire k8s-upgrade-chain 3600 0 || rc=$?
echo "survived rc=$rc"
SCRIPT
)
grep -q "survived rc=75" <<<"$out" && ok "acquire is safe under set -e (upgrade-step.sh runs with it)" || bad "set -e: [$out]"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
