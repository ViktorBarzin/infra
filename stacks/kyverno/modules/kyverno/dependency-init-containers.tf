
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
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "inject-dependency-init-containers"
      annotations = {
        "policies.kyverno.io/title"       = "Inject Dependency Init Containers"
        "policies.kyverno.io/description" = "Injects wait-for init containers based on dependency.kyverno.io/wait-for pod annotation. Each comma-separated host:port entry becomes a busybox init container that blocks until the dependency is reachable via nc -z."
      }
    }
    spec = {
      rules = [
        {
          name = "wait-for-dependencies"
          match = {
            any = [
              {
                resources = {
                  kinds      = ["Pod"]
                  operations = ["CREATE"]
                }
              }
            ]
          }
          preconditions = {
            all = [
              {
                key      = "{{ request.object.metadata.annotations.\"dependency.kyverno.io/wait-for\" || '' }}"
                operator = "NotEquals"
                value    = ""
              }
            ]
          }
          mutate = {
            foreach = [
              {
                list = "request.object.metadata.annotations.\"dependency.kyverno.io/wait-for\" | split(@, ',')"
                patchStrategicMerge = {
                  spec = {
                    initContainers = [
                      {
                        name    = "wait-for-{{ element | split(@, ':') | [0] | replace_all(@, '.', '-') }}"
                        image   = "busybox:1.37"
                        command = ["sh", "-c", "until nc -z {{ element | split(@, ':') | [0] }} {{ element | split(@, ':') | [1] }}; do echo waiting for {{ element }}; sleep 2; done"]
                        # Without its own resources this container took the
                        # namespace LimitRange default, 1Gi in immich. A pod's
                        # scheduling request is the larger of its biggest init
                        # container and the sum of its containers, so the three
                        # immich-frame pods each reserved 1Gi for an nc loop:
                        # 2.63 GiB of the scheduler's view on 2026-09-27. No
                        # LimitRange here sets a min or a limit/request ratio,
                        # so these values are admissible in every namespace.
                        resources = {
                          requests = { cpu = "5m", memory = "16Mi" }
                          limits   = { memory = "32Mi" }
                        }
                      }
                    ]
                  }
                }
              }
            ]
          }
        }
      ]
    }
  })
}
