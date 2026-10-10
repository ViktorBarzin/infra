# shellcheck shell=bash
# Verify checks for stacks/authentik (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="authentik"
VERIFY_ALERTNAMES="^Authentik"

A="http://goauthentik-server.authentik.svc.cluster.local"

_forward_auth_redirect() {
  # A forward-auth route sends an anonymous browser to the Authentik flow.
  local loc
  loc=$(curl -sk -A "$VERIFY_UA" -o /dev/null -w '%{redirect_url}' --max-time 20 --resolve "grafana.viktorbarzin.me:443:$(traefik_ip)" https://grafana.viktorbarzin.me/)
  echo "grafana redirects to: $loc"
  grep -q 'authentik.viktorbarzin.me' <<<"$loc"
}

_flow_executor() {
  # The default authentication flow renders (database, cache and worker-built
  # flow plan all involved).
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "$A/api/v3/flows/executor/default-authentication-flow/?query=")
  echo "flow executor -> $code"
  [[ "$code" =~ ^(200|302)$ ]]
}

verify_component() {
  local d
  # ak-outpost-postgres-ldap and ak-outpost-rac are parked at 0 replicas;
  # the floor counts them as converged.
  for d in goauthentik-server goauthentik-worker pgbouncer ak-outpost-public; do
    check "$d converged" retry 300 10 workload_ready authentik "deployment/$d"
  done
  check "server ready probe" expect_http "$A/-/health/ready/" '200|204'
  check "server live probe" expect_http "$A/-/health/live/" '200|204'
  check "API answers root config" expect_body "$A/api/v3/root/config/" '"capabilities"'
  check "default authentication flow renders" _flow_executor
  check "forward-auth routes redirect to Authentik" _forward_auth_redirect
  check "public proxy outpost answers its ping" expect_http http://ak-outpost-public.authentik.svc.cluster.local:9000/outpost.goauthentik.io/ping '200|204'
  check "every Authentik scrape target is up" expect_prom 'min(up{job=~".*authentik.*"})' -eq 1
}
