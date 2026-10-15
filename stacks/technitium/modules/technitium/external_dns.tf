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
# scope; internal viktorbarzin.me records stay with technitium-ingress-dns-sync.
#
# A failed zone transfer is logged and read as an empty zone rather than as an
# error, so the record-count alert in the monitoring stack is what catches a
# broken key or zone-transfer policy.

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
  version    = "1.23.0" # app v0.22.0

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
