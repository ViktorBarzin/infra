# shellcheck shell=bash
# Verify checks for stacks/nextcloud (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="nextcloud"
VERIFY_ALERTNAMES="^Nextcloud"

_status() {
  local ip out
  ip=$(traefik_ip)
  out=$(curl -sk --max-time 20 --resolve "nextcloud.viktorbarzin.me:443:$ip" https://nextcloud.viktorbarzin.me/status.php)
  echo "status.php: $out"
  # status.php answers 200 even in maintenance mode, so read the fields.
  [ "$(jq -r '.installed' <<<"$out")" = true ] &&
    [ "$(jq -r '.maintenance' <<<"$out")" = false ] &&
    [ "$(jq -r '.needsDbUpgrade' <<<"$out")" = false ]
}

_watchdog_recent() {
  local t age
  t=$(kubectl get cronjob -n nextcloud nextcloud-watchdog -o jsonpath='{.status.lastSuccessfulTime}')
  age=$(age_seconds "$t")
  echo "nextcloud-watchdog last success $t (${age}s ago)"
  [ "$age" -lt 3600 ]
}

verify_component() {
  check "nextcloud deployment converged" retry 300 10 workload_ready nextcloud deployment/nextcloud
  check "status.php: installed, not in maintenance, no pending DB upgrade" retry 300 20 _status
  check "login page renders" expect_ingress nextcloud.viktorbarzin.me /login '200'
  check "WebDAV asks for credentials (not 5xx)" expect_ingress nextcloud.viktorbarzin.me /remote.php/dav/ '401' -X PROPFIND
  check "health watchdog succeeded within the hour" _watchdog_recent
  check "no startup exceptions in the last 15m" expect_no_log_errors nextcloud app.kubernetes.io/name=nextcloud "Can't start|Fatal error|Uncaught"
}
