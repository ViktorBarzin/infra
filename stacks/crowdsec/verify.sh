# shellcheck shell=bash
# Verify checks for stacks/crowdsec (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="crowdsec"
VERIFY_ALERTNAMES="^CrowdSec"

_waf_blocks_xss() {
  # ci.viktorbarzin.me is on the bouncer's appsecCrsHosts list.
  local ok bad
  ok=$(via_traefik ci.viktorbarzin.me /)
  bad=$(via_traefik ci.viktorbarzin.me '/?q=%3Cscript%3Ealert(1)%3C/script%3E')
  echo "plain request -> $ok, XSS probe -> $bad"
  [[ "$ok" =~ ^(200|302)$ ]] && [ "$bad" = "403" ]
}

verify_component() {
  check "LAPI converged" retry 300 10 workload_ready crowdsec deployment/crowdsec-lapi
  check "AppSec converged" retry 300 10 workload_ready crowdsec deployment/crowdsec-appsec
  check "agents converged on every node" retry 300 10 workload_ready crowdsec daemonset/crowdsec-agent
  check "firewall bouncers converged" retry 300 10 workload_ready crowdsec daemonset/crowdsec-firewall-bouncer
  check "every CrowdSec scrape target is up" expect_prom 'min(up{job=~"crowdsec.*"})' -eq 1
  check "CAPI blocklist decisions loaded (> 10k)" expect_prom 'sum(cs_active_decisions)' -gt 10000
  check "Traefik bouncers are polling LAPI" expect_prom 'count(count by (bouncer) (rate(cs_lapi_bouncer_requests_total{bouncer=~"traefik.*"}[10m]) > 0))' -ge 1
  check "agents are parsing logs" expect_prom 'sum(rate(cs_parser_hits_ok_total[10m]))' -gt 0
  check "AppSec is inspecting requests" expect_prom 'sum(rate(cs_appsec_reqs_total[10m]))' -gt 0
  check "WAF returns 403 to an XSS probe on a CRS host" _waf_blocks_xss
  check "no fatal or hub errors in the last 15m" expect_no_log_errors crowdsec k8s-app=crowdsec 'level=fatal|hub.*error|migration.*fail'
}
