# RFC 2136 dynamic updates for viktorbarzin.lan and the Kea reverse zones.
#
# Two writers are allowed, each with its own TSIG key:
#   - external-dns (external_dns.tf) creates and deletes the A + TXT records
#     for *.viktorbarzin.lan Ingress hosts. It talks to the primary directly.
#   - Kea DHCP-DDNS on pfSense registers DHCP leases. It sends to the LB
#     10.0.20.201, so its updates can land on a replica, which checks the
#     signature with its own copy of the key and forwards to the primary.
#
# Zone options and TSIG keys are per-instance settings that AXFR does not
# carry, and a replica zone recreated by technitium-zone-sync starts at
# update=Deny. Until 2026-10-14 they were set by hand, and by then every
# instance had drifted back to Deny. This CronJob sets them on all three
# instances every hour so a rebuild converges on its own.
#
# The full TSIG key list is built here: settings/set replaces the whole list,
# so a read-modify-write that misparsed the live list could drop kea-ddns.

variable "kea_ddns_tsig_secret" {
  type      = string
  sensitive = true
}

# 32 random bytes, base64: the shared secret external-dns signs with.
resource "random_id" "external_dns_tsig" {
  byte_length = 32
}

locals {
  # pfSense addresses Kea's updates come from (ETP Local on the LB keeps them).
  kea_update_sources = "10.0.20.1,10.0.10.1,192.168.1.2"
  # Pod network: external-dns, and replicas forwarding Kea updates to the primary.
  pod_cidr = "10.10.0.0/16"
  # "<zone> <updateSecurityPolicies>" per line; set on the primary only, since
  # Technitium accepts policies on primary zones only.
  dynamic_update_zones = join("\n", [
    "viktorbarzin.lan kea-ddns|*.viktorbarzin.lan|ANY|external-dns|*.viktorbarzin.lan|A,AAAA,CNAME,TXT",
    "10.0.10.in-addr.arpa kea-ddns|*.10.0.10.in-addr.arpa|ANY",
    "20.0.10.in-addr.arpa kea-ddns|*.20.0.10.in-addr.arpa|ANY",
    "1.168.192.in-addr.arpa kea-ddns|*.1.168.192.in-addr.arpa|ANY",
  ])
}

resource "kubernetes_secret_v1" "dynamic_updates" {
  metadata {
    name      = "technitium-dynamic-updates"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  data = {
    TECH_USER = var.technitium_username
    TECH_PASS = var.technitium_password
    KEA_TSIG  = var.kea_ddns_tsig_secret
    EDNS_TSIG = random_id.external_dns_tsig.b64_std
  }
}

resource "kubernetes_cron_job_v1" "technitium_dynamic_updates" {
  metadata {
    name      = "technitium-dynamic-updates"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    schedule                      = "40 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            container {
              name  = "dynamic-updates"
              image = "curlimages/curl:latest"
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "32Mi"
                }
              }
              dynamic "env" {
                for_each = toset(["TECH_USER", "TECH_PASS", "KEA_TSIG", "EDNS_TSIG"])
                content {
                  name = env.value
                  value_from {
                    secret_key_ref {
                      name = kubernetes_secret_v1.dynamic_updates.metadata[0].name
                      key  = env.value
                    }
                  }
                }
              }
              env {
                name  = "ZONES"
                value = local.dynamic_update_zones
              }
              env {
                name  = "KEA_SOURCES"
                value = local.kea_update_sources
              }
              env {
                name  = "POD_CIDR"
                value = local.pod_cidr
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -u
                PUSHGW="http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/technitium-dynamic-updates"
                RC=0
                printf '%s\n' "$$ZONES" > /tmp/zones
                KEYS="kea-ddns|$$KEA_TSIG|hmac-sha256|external-dns|$$EDNS_TSIG|hmac-sha256"

                for INST in primary secondary tertiary; do
                  case "$$INST" in
                    primary) URL="http://technitium-primary.technitium.svc.cluster.local:5380" ;;
                    *)       URL="http://technitium-$$INST-web.technitium.svc.cluster.local:5380" ;;
                  esac
                  TOKEN=$$(curl -sf "$$URL/api/user/login?user=$$TECH_USER&pass=$$TECH_PASS" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
                  if [ -z "$$TOKEN" ]; then echo "$$INST: login FAILED"; RC=1; continue; fi

                  # TSIG keys: write only when the live list differs from the
                  # two declared keys (compared without printing secrets).
                  LIVE=$$(curl -sf -G "$$URL/api/settings/get" --data-urlencode "token=$$TOKEN" | tr -d ' \n' | sed -n 's/.*"tsigKeys":\[\([^]]*\)\].*/\1/p')
                  N=$$(printf '%s' "$$LIVE" | grep -o '"keyName"' | wc -l)
                  if [ "$$N" -eq 2 ] \
                    && printf '%s' "$$LIVE" | grep -qF "\"keyName\":\"kea-ddns\",\"sharedSecret\":\"$$KEA_TSIG\"" \
                    && printf '%s' "$$LIVE" | grep -qF "\"keyName\":\"external-dns\",\"sharedSecret\":\"$$EDNS_TSIG\""; then
                    echo "$$INST: tsig keys ok"
                  else
                    R=$$(curl -sf -X POST "$$URL/api/settings/set" --data-urlencode "token=$$TOKEN" --data-urlencode "tsigKeys=$$KEYS")
                    if printf '%s' "$$R" | grep -q '"status":"ok"'; then echo "$$INST: tsig keys set"; else echo "$$INST: tsig keys FAILED"; RC=1; fi
                  fi

                  while read -r ZONE POLICIES; do
                    [ -z "$$ZONE" ] && continue
                    if [ "$$INST" = primary ]; then
                      R=$$(curl -sf -X POST "$$URL/api/zones/options/set" --data-urlencode "token=$$TOKEN" --data-urlencode "zone=$$ZONE" \
                        --data-urlencode "update=UseSpecifiedNetworkACL" --data-urlencode "updateNetworkACL=$$KEA_SOURCES,$$POD_CIDR" \
                        --data-urlencode "updateSecurityPolicies=$$POLICIES")
                    else
                      R=$$(curl -sf -X POST "$$URL/api/zones/options/set" --data-urlencode "token=$$TOKEN" --data-urlencode "zone=$$ZONE" \
                        --data-urlencode "update=UseSpecifiedNetworkACL" --data-urlencode "updateNetworkACL=$$KEA_SOURCES")
                    fi
                    if printf '%s' "$$R" | grep -q '"status":"ok"'; then echo "$$INST: $$ZONE update policy set"; else echo "$$INST: $$ZONE FAILED -- $$R"; RC=1; fi
                  done < /tmp/zones

                  curl -sf -G "$$URL/api/user/logout" --data-urlencode "token=$$TOKEN" > /dev/null || true
                done

                printf 'technitium_dynamic_updates_status %s\ntechnitium_dynamic_updates_last_run %s\n' "$$RC" "$$(date +%s)" \
                  | curl -sf --data-binary @- "$$PUSHGW" > /dev/null || echo "WARN: pushgateway push failed"
                exit $$RC
              EOT
              ]
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].job_template[0].spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}
