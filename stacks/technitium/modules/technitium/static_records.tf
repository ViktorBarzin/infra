# Internal-only static A records for the viktorbarzin.me zone.
#
# The internal zone is AUTHORITATIVE for viktorbarzin.me (the superset rule in
# main.tf), so a name that exists only in public DNS NXDOMAINs for every client
# using Technitium. The ingress sync next door covers ingress hosts; names that
# are served by a LoadBalancer Service instead of an Ingress have nothing
# creating them, which is what this reconciles.
#
# Declarative and idempotent, matching the mx2/valia ensure-or-update idiom in
# main.tf: adopt the correct value, replace a stale one, leave a matching record
# alone. Lives in its own file so adding a record is a one-line change that
# doesn't touch the large sync heredocs.
#
# Records are written to the PRIMARY only; the secondary and tertiary pull the
# zone by AXFR.

locals {
  # name (relative to the zone) => IPv4 address.
  #
  # turn: coturn's DEDICATED MetalLB address (stacks/coturn local.lb_ip — keep in
  # step with it and with the pfSense `coturn_lb` alias). Public DNS resolves
  # turn.viktorbarzin.me to the WAN IP, but Technitium had no record at all, so a
  # client on LAN DNS received NXDOMAIN for the STUN/TURN hostname and a WebRTC
  # display (the neko views in stacks/chrome-service and stacks/proxy) got no
  # usable ICE candidates. Verified 2026-08-11:
  #   dig @10.0.20.201 turn.viktorbarzin.me  ->  NXDOMAIN (flags: qr aa)
  #   dig @1.1.1.1     turn.viktorbarzin.me  ->  176.12.22.76
  # Note this record only helps clients that USE Technitium; London resolves via
  # its own dnsmasq and gets the public answer, reaching coturn over the WAN.
  static_a_records = {
    turn = "10.0.20.205"
  }
}

resource "kubernetes_cron_job_v1" "technitium_static_records" {
  metadata {
    name      = "technitium-static-records"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    schedule                      = "35 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            container {
              name  = "sync"
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
              env {
                name  = "TECH_USER"
                value = var.technitium_username
              }
              env {
                name  = "TECH_PASS"
                value = var.technitium_password
              }
              # "<name> <ip>" per line — the shell reads it without needing jq.
              env {
                name  = "RECORDS"
                value = join("\n", [for name, ip in local.static_a_records : "${name} ${ip}"])
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -e
                ZONE="viktorbarzin.me"
                TECH_API="http://technitium-web:5380"

                TOKEN=$$(curl -sf "$$TECH_API/api/user/login?user=$$TECH_USER&pass=$$TECH_PASS" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
                if [ -z "$$TOKEN" ]; then echo "ERROR: Technitium login failed"; exit 1; fi

                # Feed the loop by REDIRECTION, not a pipe: a piped `while` runs
                # in a subshell, so an RC set inside it would be lost and the job
                # would report success while failing to write a record.
                printf '%s\n' "$$RECORDS" > /tmp/records
                RC=0
                while read -r NAME IP; do
                  [ -z "$$NAME" ] && continue
                  FQDN="$$NAME.$$ZONE"
                  REC=$$(curl -sf "$$TECH_API/api/zones/records/get?token=$$TOKEN&zone=$$ZONE&domain=$$FQDN" || true)
                  CUR_A=$$(printf '%s' "$$REC" | grep -o '"ipAddress":"[^"]*"' | head -1 | cut -d'"' -f4)

                  if [ "$$CUR_A" = "$$IP" ]; then
                    echo "static-records: $$FQDN ok ($$IP)"
                    continue
                  fi

                  # A CNAME from the ingress sync (or an older A) would shadow the
                  # record we want, so clear whatever is there first.
                  CUR_C=$$(printf '%s' "$$REC" | grep -o '"cname":"[^"]*"' | head -1 | cut -d'"' -f4)
                  if [ -n "$$CUR_C" ]; then
                    curl -sf -G "$$TECH_API/api/zones/records/delete" --data-urlencode "token=$$TOKEN" --data-urlencode "zone=$$ZONE" --data-urlencode "domain=$$FQDN" --data-urlencode "type=CNAME" --data-urlencode "cname=$$CUR_C" > /dev/null || true
                    echo "static-records: removed stale CNAME $$FQDN -> $$CUR_C"
                  fi
                  if [ -n "$$CUR_A" ]; then
                    curl -sf -G "$$TECH_API/api/zones/records/delete" --data-urlencode "token=$$TOKEN" --data-urlencode "zone=$$ZONE" --data-urlencode "domain=$$FQDN" --data-urlencode "type=A" --data-urlencode "ipAddress=$$CUR_A" > /dev/null || true
                    echo "static-records: removed stale A $$FQDN -> $$CUR_A"
                  fi

                  R=$$(curl -sf -G "$$TECH_API/api/zones/records/add" --data-urlencode "token=$$TOKEN" --data-urlencode "zone=$$ZONE" --data-urlencode "domain=$$FQDN" --data-urlencode "type=A" --data-urlencode "ipAddress=$$IP" --data-urlencode "ttl=3600") || true
                  if echo "$$R" | grep -q '"status":"ok"'; then
                    echo "static-records: set $$FQDN -> $$IP"
                  else
                    echo "static-records: FAILED $$FQDN -- $$R"
                    RC=1
                  fi
                done < /tmp/records
                exit $$RC
              EOT
              ]
            }
            restart_policy = "OnFailure"
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
