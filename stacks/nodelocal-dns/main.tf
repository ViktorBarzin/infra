module "nodelocal_dns" {
  source = "./modules/nodelocal-dns"

  # Canonical link-local IP from upstream NodeLocal DNSCache docs.
  link_local_ip = "169.254.20.10"

  # kube-dns ClusterIP — co-listened so transparent interception works
  # without mutating kubelet clusterDNS on every node.
  kube_dns_ip = "10.96.0.10"

  # Technitium ClusterIP — upstream for .viktorbarzin.lan.
  technitium_ip = "10.96.0.53"

  image = "registry.k8s.io/dns/k8s-dns-node-cache:1.23.1"
  tier  = local.tiers.core
}
