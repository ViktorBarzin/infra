# shellcheck shell=bash
# Verify checks for stacks/traefik (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="traefik"
# Not IngressTTFBCritical: it is per upstream service, and a slow app is not
# a Traefik regression (it fired for tripit during the first full run).
VERIFY_ALERTNAMES="^Traefik.*$"

verify_component() {
  check "traefik deployment converged" retry 300 10 workload_ready traefik deployment/traefik
  check "LoadBalancer IP on svc/traefik" bash -c '
    ip=$(kubectl get svc -n traefik traefik -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
    echo "traefik LB ip=$ip"; [ -n "$ip" ]'
  check "UDP 443 Service has the same LB IP" bash -c '
    a=$(kubectl get svc -n traefik traefik -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
    b=$(kubectl get svc -n traefik traefik-udp -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
    echo "tcp=$a udp=$b"; [ -n "$b" ] && [ "$a" = "$b" ]'
  # Real routes through Traefik: Forgejo (public, no auth) and Authentik
  # (forward-auth endpoint itself).
  check "forgejo answers 200 through Traefik" expect_ingress forgejo.viktorbarzin.me / '200'
  check "authentik answers through Traefik" expect_ingress authentik.viktorbarzin.me / '200|302'
  check "a forward-auth route redirects to Authentik" expect_ingress grafana.viktorbarzin.me / '302|401'
  # The LoadBalancer path itself (MetalLB VIP -> Traefik).
  check "ingress VIP 10.0.20.203:443 accepts TCP" tcp_open 10.0.20.203 443
  check "Traefik serves metrics to Prometheus" expect_prom 'sum(up{job=~".*traefik.*"})' -ge 1
  check "websecure requests are flowing" expect_prom 'sum(rate(traefik_entrypoint_requests_total{entrypoint="websecure"}[5m]))' -gt 0
  check "websecure 5xx share under 5%" expect_prom '(sum(rate(traefik_entrypoint_requests_total{entrypoint="websecure",code=~"5.."}[5m])) or vector(0)) / sum(rate(traefik_entrypoint_requests_total{entrypoint="websecure"}[5m]))' -lt 0.05
  check "no plugin load or fatal errors in the last 15m" expect_no_log_errors traefik app.kubernetes.io/name=traefik 'plugin.*(error|fail)|level=fatal'
  # A new Traefik pod can log "middleware ... does not exist" for every router
  # in its first second: the Ingress provider builds routers before the CRD
  # provider has listed the Middlewares. Loki 2026-10-05..12: 2 of 24 pod
  # starts did it (271 lines each, all within 1s, none later), and it reverted
  # two unrelated bumps (pipeline #2282). A Middleware that is really missing
  # is logged again on every config rebuild, so it still fails after 60s.
  check "no middleware 'does not exist' errors past 60s after pod start (15m)" expect_no_log_errors_after_start traefik app.kubernetes.io/name=traefik 'middleware.*does not exist' 60
}
