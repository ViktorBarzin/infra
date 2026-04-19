include "root" {
  path = find_in_parent_folders()
}

# CoreDNS ConfigMap + kube-dns Service live in the technitium stack.
# NodeLocal DNSCache co-listens on the kube-dns ClusterIP (10.96.0.10)
# via hostNetwork + iptables NOTRACK — no kubelet clusterDNS change needed.
dependency "technitium" {
  config_path  = "../technitium"
  skip_outputs = true
}
