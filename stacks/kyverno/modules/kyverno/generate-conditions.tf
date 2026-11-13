# Which namespaces the cloned-secret GeneratingPolicies skip (registry-credentials
# and tls-secret). Locals only, so tests/cloud-access.test.sh can read it with
# `terraform console` and check the expression on a real API server.
#
# Skipped:
#   kube-system, kube-public, kube-node-lease.
#   Cloud's Project namespaces (label cloud.viktorbarzin.me/managed=true, set
#   when the reconciler creates the namespace; stacks/cloud). tls-secret holds
#   the *.viktorbarzin.me private key and registry-credentials the Forgejo
#   cluster-puller token, and the reconciler may read Secrets in a Project
#   namespace while invited Users' pods run there. Project Ingresses get the
#   wildcard from Traefik's default TLSStore (traefik/default), and Project
#   images come from ghcr with their own pull secret.
#
# The expression sits in single quotes in policies/generate-clone-secret.yaml,
# so it uses double-quoted CEL strings only.
locals {
  generate_skip_system_namespaces = "!(object.metadata.name in [\"kube-system\", \"kube-public\", \"kube-node-lease\"]) && !(has(object.metadata.labels) && \"cloud.viktorbarzin.me/managed\" in object.metadata.labels && object.metadata.labels[\"cloud.viktorbarzin.me/managed\"] == \"true\")"
}
