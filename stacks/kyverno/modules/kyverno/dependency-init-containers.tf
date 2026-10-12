
# =============================================================================
# Pod Dependency Init Container Injection
# =============================================================================
# Reads the annotation dependency.kyverno.io/wait-for from pods and injects
# init containers that wait for each listed dependency to be reachable.
#
# Usage:
#   annotations:
#     dependency.kyverno.io/wait-for: "postgresql.dbaas:5432,redis-master.redis:6379"
#
# Each comma-separated entry becomes a busybox init container that runs
# `nc -z <host> <port>` in a loop until the dependency is reachable.
# Existing init containers are preserved — Kyverno appends to the array.

resource "kubectl_manifest" "inject_dependency_init_containers" {
  yaml_body = file("${path.module}/policies/inject-dependency-init-containers.yaml")

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }
}
