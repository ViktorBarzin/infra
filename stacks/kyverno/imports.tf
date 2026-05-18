# Import existing live Kyverno resources into kubectl_manifest state.
# Created during code-e2dp fix (kubernetes_manifest → kubectl_manifest swap).
# Once applied successfully, these import blocks can be deleted in a cleanup commit.

import {
  to = module.kyverno.kubectl_manifest.cleanup_failed_pods
  id = "kyverno.io/v2beta1//ClusterCleanupPolicy//cleanup-failed-pods"
}
import {
  to = module.kyverno.kubectl_manifest.generate_limitrange_by_tier
  id = "kyverno.io/v1//ClusterPolicy//generate-limitrange-by-tier"
}
import {
  to = module.kyverno.kubectl_manifest.generate_resourcequota_by_tier
  id = "kyverno.io/v1//ClusterPolicy//generate-resourcequota-by-tier"
}
import {
  to = module.kyverno.kubectl_manifest.inject_dependency_init_containers
  id = "kyverno.io/v1//ClusterPolicy//inject-dependency-init-containers"
}
import {
  to = module.kyverno.kubectl_manifest.mutate_gpu_priority
  id = "kyverno.io/v1//ClusterPolicy//mutate-gpu-priority"
}
import {
  to = module.kyverno.kubectl_manifest.mutate_ndots
  id = "kyverno.io/v1//ClusterPolicy//mutate-ndots"
}
import {
  to = module.kyverno.kubectl_manifest.mutate_priority_from_tier
  id = "kyverno.io/v1//ClusterPolicy//mutate-priority-from-tier"
}
import {
  to = module.kyverno.kubectl_manifest.mutate_strip_cpu_limits
  id = "kyverno.io/v1//ClusterPolicy//mutate-strip-cpu-limits"
}
import {
  to = module.kyverno.kubectl_manifest.mutate_tier_from_namespace
  id = "kyverno.io/v1//ClusterPolicy//mutate-tier-from-namespace"
}
import {
  to = module.kyverno.kubectl_manifest.policy_deny_host_namespaces
  id = "kyverno.io/v1//ClusterPolicy//deny-host-namespaces"
}
import {
  to = module.kyverno.kubectl_manifest.policy_deny_privileged
  id = "kyverno.io/v1//ClusterPolicy//deny-privileged-containers"
}
import {
  to = module.kyverno.kubectl_manifest.policy_inject_keel_annotations
  id = "kyverno.io/v1//ClusterPolicy//inject-keel-annotations"
}
import {
  to = module.kyverno.kubectl_manifest.policy_require_trusted_registries
  id = "kyverno.io/v1//ClusterPolicy//require-trusted-registries"
}
import {
  to = module.kyverno.kubectl_manifest.policy_restrict_capabilities
  id = "kyverno.io/v1//ClusterPolicy//restrict-sys-admin"
}
import {
  to = module.kyverno.kubectl_manifest.policy_set_image_pull_policy
  id = "kyverno.io/v1//ClusterPolicy//set-image-pull-policy"
}
import {
  to = module.kyverno.kubectl_manifest.sync_registry_credentials
  id = "kyverno.io/v1//ClusterPolicy//sync-registry-credentials"
}
import {
  to = module.kyverno.kubectl_manifest.sync_tls_secret
  id = "kyverno.io/v1//ClusterPolicy//sync-tls-secret"
}
