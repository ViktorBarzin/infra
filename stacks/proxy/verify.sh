# shellcheck shell=bash
# Verify checks for stacks/proxy (docs/runbooks/verify-jobs.md). The floor
# covers proxy-broker and proxy-gw-1. These checks use the UK egress the way a
# consumer does: a request through the HTTP proxy (:8888) and one through
# SOCKS5 with proxy-side DNS (:1080) must both leave from Great Britain.
# Two geo sources per path, and GB from either counts, because a single geo
# database can mislocate the exit (egress-country-probe.tf has the history).
VERIFY_GROUP="app"
VERIFY_NAMESPACES="proxy"
VERIFY_ALERTNAMES="^(VPNEgress.*|ProxyEgress.*)$"

EGRESS=proxy-egress-uk.proxy.svc.cluster.local

# _exit_country <curl proxy URL>: prints both answers, passes when either is GB.
_exit_country() {
  local proxy=$1 c1 c2
  c1=$(curl -sf -x "$proxy" --max-time 25 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')
  c2=$(curl -sf -x "$proxy" --max-time 25 'http://ip-api.com/json/?fields=countryCode' 2>/dev/null | jq -r '.countryCode // empty' 2>/dev/null)
  echo "ipinfo=${c1:-none} ip-api=${c2:-none}"
  [ "$c1" = GB ] || [ "$c2" = GB ]
}

verify_component() {
  check "HTTP proxy :8888 exits in GB" retry 120 15 _exit_country "http://$EGRESS:8888"
  check "SOCKS5 :1080 (socks5h) exits in GB" retry 120 15 _exit_country "socks5h://$EGRESS:1080"
}
