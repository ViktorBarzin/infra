# shellcheck shell=bash
# Verify checks for stacks/osm_routing (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="app"
VERIFY_NAMESPACES="osm-routing"

# Bank to Westminster, inside the Greater London extract. A route comes back
# only when osrm-routed has loaded a graph built by its own osrm version.
ROUTE_COORDS="-0.0886,51.5133;-0.1246,51.5007"

_route() {
  local profile=$1 out dist
  out=$(curl -sS -A "$VERIFY_UA" --max-time 20 \
    "http://osrm-$profile.osm-routing.svc.cluster.local:5000/route/v1/$profile/$ROUTE_COORDS?overview=false") || {
    echo "request to osrm-$profile failed"
    return 1
  }
  dist=$(jq -r 'select(.code == "Ok") | .routes[0].distance' <<<"$out" 2>/dev/null)
  echo "osrm-$profile Bank->Westminster distance=${dist:-none}m"
  # The real distance is about 3.6 km; anything far off means a broken graph.
  [ -n "$dist" ] && awk -v d="$dist" 'BEGIN { exit !(d > 2000 && d < 8000) }'
}

_build_matches_serve() {
  # Build and serve must use one osrm version, or the next refresh writes a
  # graph the serving pods cannot read.
  local build serve
  build=$(kubectl -n osm-routing get cronjob osrm-refresh -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}')
  serve=$(kubectl -n osm-routing get deployment osrm-foot osrm-bicycle -o jsonpath='{.items[*].spec.template.spec.containers[0].image}')
  echo "build=$build serve=$serve"
  [ -n "$build" ] && [ "$serve" = "$build $build" ]
}

verify_component() {
  local p
  for p in foot bicycle; do
    check "osrm-$p converged" retry 300 10 workload_ready osm-routing "deployment/osrm-$p"
    check "osrm-$p answers a London route" retry 120 10 _route "$p"
  done
  check "osrm-refresh builds with the serving image" _build_matches_serve
}
