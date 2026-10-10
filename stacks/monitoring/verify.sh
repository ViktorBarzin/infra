# shellcheck shell=bash
# Verify checks for stacks/monitoring: Prometheus, Alertmanager, Grafana, Loki
# and Alloy (docs/runbooks/verify-jobs.md). Read-only: nothing here may
# restart prometheus-server (its WAL is tmpfs).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="monitoring"
VERIFY_ALERTNAMES="^(Prometheus.*|Alertmanager.*|Loki.*|RuntimeJournalSilent|Grafana.*)$"

P="http://prometheus-server.monitoring.svc.cluster.local"
L="http://loki.monitoring.svc.cluster.local:3100"

_rules_healthy() {
  local out
  out=$(curl -sS --max-time 20 "$P/api/v1/rules" | jq -r '
    [.data.groups[].rules[]] as $r | [$r[] | select(.health != "ok") | .name] as $bad
    | "rules=\($r|length) unhealthy=\($bad)", (if ($r|length) > 100 and ($bad|length)==0 then 0 else 1 end)')
  head -1 <<<"$out"
  [ "$(tail -1 <<<"$out")" = 0 ]
}

_history() {
  # 26 weeks of retention: a sample from 25 weeks ago is still queryable.
  local t v
  t=$(( $(date +%s) - 25*7*86400 ))
  v=$(curl -sS --max-time 30 "$P/api/v1/query" --data-urlencode 'query=count(up)' --data-urlencode "time=$t" | jq -r '.data.result[0].value[1] // empty')
  echo "count(up) 25 weeks ago = ${v:-none}"
  [ -n "$v" ]
}

_alertmanager() {
  local out
  out=$(curl -sS --max-time 10 http://prometheus-alertmanager.monitoring.svc.cluster.local:9093/api/v2/status)
  echo "alertmanager cluster=$(jq -r .cluster.status <<<"$out") version=$(jq -r .versionInfo.version <<<"$out")"
  [ "$(jq -r .cluster.status <<<"$out")" = ready ]
}

_grafana() {
  local out
  out=$(curl -sS --max-time 10 http://grafana.monitoring.svc.cluster.local/api/health)
  echo "grafana: $(tr -d '\n ' <<<"$out")"
  [ "$(jq -r .database <<<"$out")" = ok ]
}

_loki_query() {
  # Pod logs written in the last 5 minutes are queryable.
  local out n
  out=$(curl -sS --max-time 30 -G "$L/loki/api/v1/query" --data-urlencode 'query=sum(count_over_time({namespace="monitoring"}[5m]))')
  n=$(jq -r '.data.result[0].value[1] // 0' <<<"$out")
  echo "log lines from monitoring in the last 5m: $n"
  [ "${n%.*}" -gt 0 ]
}

_loki_rules() {
  local n
  n=$(curl -sS --max-time 20 "$L/prometheus/api/v1/rules" | jq '[.data.groups[].rules[]] | length')
  echo "loki ruler rules=$n"
  [ "${n:-0}" -gt 10 ]
}

verify_component() {
  check "prometheus-server converged" retry 300 10 workload_ready monitoring deployment/prometheus-server
  check "Prometheus ready" expect_http "$P/-/ready" '200'
  check "rules loaded, none unhealthy" _rules_healthy
  check "over 95% of scrape targets up" expect_prom 'count(up == 1) / count(up)' -gt 0.95
  check "26-week history still queryable" _history
  check "Alertmanager cluster ready" _alertmanager
  check "Grafana database ok" _grafana
  check "Loki ready" expect_body "$L/ready" '^ready'
  check "Loki is ingesting" expect_prom 'sum(rate(loki_distributor_lines_received_total[5m]))' -gt 10
  check "recent logs are queryable in Loki" _loki_query
  check "Loki ruler has its rules" _loki_rules
  check "Alloy runs on every node plus syslog" expect_prom 'count(alloy_build_info)' -ge 7
  check "Alloy configs loaded" expect_prom 'min(alloy_config_last_load_successful)' -eq 1
  check "Alloy drops no log entries" expect_prom '(sum(rate(loki_write_dropped_entries_total[15m])) or vector(0))' -lt 1
}
