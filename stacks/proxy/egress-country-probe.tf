# Standing detector for infra#97 — "proxy-egress-uk exits in the wrong country".
#
# The failure this guards is silent by construction: gluetun's tunnel is fully
# healthy, readiness is green and VPNEgressGatewayDown stays quiet — only the
# EXIT COUNTRY is wrong (observed: Rio de Janeiro, AS7738 "V tal", while the
# frozen server list still labelled the server "United Kingdom"). UPDATER_PERIOD
# on the gluetun container (egress.tf) is the root-cause mitigation; this probe
# is the belt-and-braces that catches the residual case and any future
# regression (a peer rotation, a bad refresh, SERVER_COUNTRIES drifting).
#
# It curls two independent geo sources THROUGH proxy-egress-uk and pushes the
# result to Pushgateway. Two sources on purpose: infra#97's own "verify the fix"
# used ifconfig.co, whose MaxMind DB currently mislocates the live GB exit
# (194.88.100.141) to US/Virginia — a single stale DB must not page us. The rule
# is "GB if ANY reliable source says GB", which errs toward NOT alarming; a
# genuine relocation shows the same wrong country across every DB, so the real
# case still trips it. The ProxyEgressWrongCountry alert (warning, for: 30m,
# stacks/monitoring/.../prometheus_chart_values.tpl) needs two consecutive
# non-GB reads before firing.
#
# Verify by hand:
#   kubectl -n proxy port-forward svc/proxy-egress-uk 18888:8888 &
#   curl -s -x http://127.0.0.1:18888 https://ipinfo.io/country   # -> GB
resource "kubernetes_cron_job_v1" "egress_country_probe" {
  metadata {
    name      = "egress-country-probe"
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "*/15 * * * *"
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 600
        template {
          metadata {
            labels = local.labels
          }
          spec {
            container {
              name  = "egress-country-probe"
              image = "docker.io/library/alpine:3.20"
              env {
                name  = "PROXY"
                value = "http://proxy-egress-uk.proxy.svc.cluster.local:8888"
              }
              env {
                name  = "PUSHGATEWAY"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/egress-country-probe"
              }
              env {
                name  = "EXPECT"
                value = "GB"
              }
              # All shell $ are escaped to $$ for the Terraform heredoc.
              command = ["/bin/sh", "-c", <<-EOT
                set -eu
                apk add --no-cache curl jq >/dev/null

                valid() { echo "$$1" | grep -Eq '^[A-Z]{2}$$'; }

                # ipinfo.io/country returns a bare 2-letter code (reliable here).
                C1=$$(curl -sf -x "$$PROXY" --max-time 25 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]' | tr 'a-z' 'A-Z' || true)
                # ip-api.com — independent DB, corroborates C1 to suppress a
                # single stale source. HTTP-only on the free tier; the request is
                # re-originated from the UK exit by the proxy.
                C2=$$(curl -sf -x "$$PROXY" --max-time 25 "http://ip-api.com/json/?fields=countryCode" 2>/dev/null | jq -r '.countryCode // empty' | tr -d '[:space:]' | tr 'a-z' 'A-Z' || true)

                echo "ipinfo=$$C1 ip-api=$$C2 expect=$$EXPECT"

                UP=0
                IS_EXPECTED=0
                COUNTRY="unknown"
                if valid "$$C1"; then UP=1; COUNTRY="$$C1"; fi
                if valid "$$C2" && [ "$$COUNTRY" = "unknown" ]; then UP=1; COUNTRY="$$C2"; fi
                # "expected if ANY reliable source confirms it" — errs toward not
                # paging on a lone stale DB.
                if valid "$$C1" && [ "$$C1" = "$$EXPECT" ]; then IS_EXPECTED=1; fi
                if valid "$$C2" && [ "$$C2" = "$$EXPECT" ]; then IS_EXPECTED=1; fi

                NOW=$$(date +%s)
                curl -sf --max-time 10 --data-binary @- "$$PUSHGATEWAY" >/dev/null 2>&1 <<METRICS || true
                # TYPE proxy_egress_probe_up gauge
                proxy_egress_probe_up $$UP
                # TYPE proxy_egress_exit_is_expected_country gauge
                proxy_egress_exit_is_expected_country $$IS_EXPECTED
                # TYPE proxy_egress_exit_country_info gauge
                proxy_egress_exit_country_info{country="$$COUNTRY",expected="$$EXPECT"} 1
                # TYPE proxy_egress_probe_last_run_timestamp gauge
                proxy_egress_probe_last_run_timestamp $$NOW
                METRICS

                echo "up=$$UP is_expected=$$IS_EXPECTED country=$$COUNTRY"
              EOT
              ]
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "48Mi"
                }
                limits = {
                  memory = "96Mi"
                }
              }
            }
            restart_policy = "OnFailure"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
