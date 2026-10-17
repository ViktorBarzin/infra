# shellcheck shell=bash
# Verify checks for stacks/technitium (docs/runbooks/verify-jobs.md).
# A chart stack since external-dns joined it (2026-10-14), so without this file
# every external-dns bump failed closed and reverted (pipeline #2502).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="technitium"
VERIFY_ALERTNAMES="^(Technitium|ExternalDNSLan).*$"

verify_component() {
  check "technitium primary converged" retry 300 10 workload_ready technitium deployment/technitium
  check "technitium secondary converged" retry 300 10 workload_ready technitium deployment/technitium-secondary
  check "technitium tertiary converged" retry 300 10 workload_ready technitium deployment/technitium-tertiary
  check "external-dns converged" retry 300 10 workload_ready technitium deployment/external-dns
  check "DNS VIP 10.0.20.201:53 accepts TCP" tcp_open 10.0.20.201 53
  # external-dns syncs every 1m; a new pod needs one loop before the gauge moves.
  check "external-dns synced .lan in the last 5m" retry 180 15 expect_prom 'time() - max(external_dns_controller_last_sync_timestamp_seconds)' -lt 300
  # Its zone transfer from the primary works (134 records on 2026-10-15). Up to
  # app v0.22.0 an AXFR that failed read as an empty zone, not an error.
  check "external-dns sees the .lan zone (>= 20 records)" retry 180 15 expect_prom 'max(external_dns_registry_endpoints_total)' -ge 20
  check "external-dns has no consecutive soft errors" retry 120 15 expect_prom 'max(external_dns_controller_consecutive_soft_errors)' -eq 0
}
