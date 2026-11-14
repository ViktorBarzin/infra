# external-dns: *.viktorbarzin.lan records straight from the kube API.
#
# Watches Ingress objects and, for every host under viktorbarzin.lan, keeps an
# A record (the Ingress status address, i.e. Traefik's LB IP) plus a TXT
# ownership record "edns-a-<host>" in the Technitium primary, over RFC 2136
# with the external-dns TSIG key (dynamic_updates.tf sets the key and the zone
# policy). It reacts to Ingress events within seconds; replicas and pfSense's
# copy of the zone pick changes up on their own refresh (up to ~30 min).
#
# policy=sync deletes a record when its Ingress goes away, but only records
# carrying this instance's TXT ownership (owner k8s-lan). Names held by any
# record it does not own (DHCP leases, phpipam-import, static_records.tf, hand
# records) are skipped entirely: no create, update or delete. Only .lan is in
# scope; internal viktorbarzin.me records stay with technitium-ingress-dns-sync,
# except Cloud App hosts, which external-dns-cloud (below) writes.
#
# Since app v0.23.0 a failed zone transfer is a soft error: the loop skips
# that cycle and external_dns_controller_consecutive_soft_errors rises. Up to
# v0.22.0 it read as an empty zone, which is why the record-count alert in the
# monitoring stack exists; it still catches a key or policy that shrinks the zone.

resource "kubernetes_secret_v1" "external_dns_tsig" {
  metadata {
    name      = "external-dns-tsig"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  data = {
    secret = random_id.external_dns_tsig.b64_std
  }
}

resource "helm_release" "external_dns" {
  namespace        = kubernetes_namespace.technitium.metadata[0].name
  create_namespace = false
  name             = "external-dns"
  atomic           = true
  cleanup_on_fail  = true

  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.23.0" # app v0.23.0

  values = [yamlencode({
    provider           = { name = "rfc2136" }
    sources            = ["ingress"] # chart default also includes service
    domainFilters      = ["viktorbarzin.lan"]
    policy             = "sync"
    registry           = "txt"
    txtOwnerId         = "k8s-lan"
    txtPrefix          = "edns-"
    interval           = "1m"
    triggerLoopOnEvent = true
    env = [{
      name = "EXTERNAL_DNS_RFC2136_TSIG_SECRET"
      valueFrom = { secretKeyRef = {
        name = kubernetes_secret_v1.external_dns_tsig.metadata[0].name
        key  = "secret"
      } }
    }]
    extraArgs = [
      "--rfc2136-host=technitium-primary.technitium.svc.cluster.local",
      "--rfc2136-port=53",
      "--rfc2136-zone=viktorbarzin.lan",
      "--rfc2136-tsig-keyname=external-dns",
      "--rfc2136-tsig-secret-alg=hmac-sha256",
      "--rfc2136-axfr",
      "--rfc2136-min-ttl=300s",
    ]
    podAnnotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "7979"
      "prometheus.io/path"   = "/metrics"
    }
    resources = {
      requests = { cpu = "10m", memory = "48Mi" }
      limits   = { memory = "128Mi" }
    }
  })]

  depends_on = [kubernetes_cron_job_v1.technitium_dynamic_updates]
}

# external-dns-cloud: internal viktorbarzin.me records for Cloud App hosts.
#
# Cloud Apps (Forgejo viktor/cloud) get hosts <name>.viktorbarzin.me through
# Ingresses in p-* namespaces. Publicly they ride the Cloudflare wildcard, but
# internal clients resolve viktorbarzin.me at Technitium, which until
# 2026-11-14 learned a new host only from the hourly
# technitium-ingress-dns-sync (main.tf), so a new App NXDOMAINed on the LAN
# for up to an hour. This instance writes the record within seconds of the
# Ingress appearing, and deletes it when the Ingress goes away.
#
# Scope and safety:
#   - Only Ingresses labelled cloud.viktorbarzin.me/managed=true. Cloud's
#     module (modules/app/main.tf, local.labels) puts that label on every
#     Ingress it renders. The hourly sync skips those Ingresses, so this
#     instance is the only writer of their records.
#   - The record has the shape the hourly sync writes: CNAME <host> ->
#     viktorbarzin.me, so it follows the apex A record (Traefik's LB IP). The
#     Ingress status IP is ignored (--force-default-targets).
#   - Ownership TXT records edns-cname-<host> with owner k8s-cloud. external-dns
#     updates and deletes only records carrying its own owner, and creates
#     nothing at a name that already holds a record it does not own, so a Cloud
#     host can never replace a homelab record. The admission policy
#     cloud-managed-ingress (stacks/cloud) also refuses hosts the homelab
#     routes, and refuses every external-dns.alpha.kubernetes.io/* annotation.
#   - Its TSIG key (dynamic_updates.tf) may write only CNAME and TXT under
#     *.viktorbarzin.me, and the two instances' keys and owner ids differ.

resource "kubernetes_secret_v1" "external_dns_cloud_tsig" {
  metadata {
    name      = "external-dns-cloud-tsig"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  data = {
    secret = random_id.external_dns_cloud_tsig.b64_std
  }
}

resource "helm_release" "external_dns_cloud" {
  namespace        = kubernetes_namespace.technitium.metadata[0].name
  create_namespace = false
  name             = "external-dns-cloud"
  atomic           = true
  cleanup_on_fail  = true

  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.23.0" # app v0.23.0, same pin as external-dns above

  values = [yamlencode({
    provider           = { name = "rfc2136" }
    sources            = ["ingress"]
    labelFilter        = "cloud.viktorbarzin.me/managed=true"
    domainFilters      = ["viktorbarzin.me"]
    policy             = "sync"
    registry           = "txt"
    txtOwnerId         = "k8s-cloud"
    txtPrefix          = "edns-"
    interval           = "1m"
    triggerLoopOnEvent = true
    env = [{
      name = "EXTERNAL_DNS_RFC2136_TSIG_SECRET"
      valueFrom = { secretKeyRef = {
        name = kubernetes_secret_v1.external_dns_cloud_tsig.metadata[0].name
        key  = "secret"
      } }
    }]
    extraArgs = [
      "--rfc2136-host=technitium-primary.technitium.svc.cluster.local",
      "--rfc2136-port=53",
      "--rfc2136-zone=viktorbarzin.me",
      "--rfc2136-tsig-keyname=external-dns-cloud",
      "--rfc2136-tsig-secret-alg=hmac-sha256",
      "--rfc2136-axfr",
      "--rfc2136-min-ttl=300s",
      "--default-targets=viktorbarzin.me",
      "--force-default-targets",
    ]
    podAnnotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "7979"
      "prometheus.io/path"   = "/metrics"
    }
    resources = {
      requests = { cpu = "10m", memory = "48Mi" }
      limits   = { memory = "128Mi" }
    }
  })]

  depends_on = [kubernetes_cron_job_v1.technitium_dynamic_updates]
}
