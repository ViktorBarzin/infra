# shellcheck shell=bash
# Verify checks for stacks/woodpecker (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="woodpecker"
# Pipeline step pods come and go in this namespace; judge only the server and
# agents.
VERIFY_ROLLOUT_SKIP="^woodpecker/Deployment/wp-"

W="http://woodpecker-server.woodpecker.svc.cluster.local"

_version() {
  local out
  out=$(curl -sS --max-time 10 "$W/version")
  echo "version: $out"
  [ -n "$(jq -r '.version // empty' <<<"$out")" ]
}

_agents_connected() {
  # Agents log 'starting Woodpecker agent' and then poll; an auth or protocol
  # mismatch shows up as errors in the last 15 minutes.
  expect_no_log_errors woodpecker app.kubernetes.io/name=agent 'unauthenticated|permission denied|rpc error.*Unavailable|grpc.*version'
}

verify_component() {
  check "server converged" retry 300 10 workload_ready woodpecker statefulset/woodpecker-server
  check "agents converged" retry 300 10 workload_ready woodpecker statefulset/woodpecker-agent
  check "server reports its version" _version
  check "server healthz" expect_http "$W/healthz" '200|204'
  check "UI answers through Traefik" expect_ingress ci.viktorbarzin.me / '200'
  check "agents connected without auth or protocol errors" _agents_connected
  check "no migration or fatal errors in server logs (15m)" expect_no_log_errors woodpecker app.kubernetes.io/name=server 'level=fatal|migration.*fail|could not load config from forge'
}
