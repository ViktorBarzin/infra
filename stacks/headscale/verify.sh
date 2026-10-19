# shellcheck shell=bash
# Verify checks for stacks/headscale (docs/runbooks/verify-jobs.md). The floor
# covers headscale itself. The tailscale and curl images of the
# tailscale-subnet-router-probe CronJob run nowhere else, so a full run starts
# that CronJob once: it joins the tailnet as an ephemeral node, requests three
# LAN addresses through the subnet router, logs out and pushes the result to
# Pushgateway, the same thing its 6-hourly schedule does.
VERIFY_GROUP="app"
VERIFY_NAMESPACES="headscale"
VERIFY_ALERTNAMES="^(Headscale.*|Tailscale.*)$"

verify_component() {
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    check "tailscale-subnet-router-probe Job completes" run_cronjob headscale tailscale-subnet-router-probe 600
    check "the probe's push reached Prometheus" retry 180 15 expect_prom 'time() - max(tailscale_subnet_router_probe_last_run_timestamp{job="tailscale-subnet-router-probe"})' -lt 900
    check "the probe sees the subnet router up" expect_prom 'min(tailscale_subnet_router_up{job="tailscale-subnet-router-probe"})' -eq 1
  fi
}
