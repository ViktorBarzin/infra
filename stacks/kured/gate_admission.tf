# What the kured-sentinel-gate's token may write, beyond its RBAC. Locals
# only, so tests/kured-gate-admission.test.sh reads them with `terraform
# console`; main.tf applies them.
#
# The gate's ClusterRole needs Deployments patch and Nodes patch everywhere
# for the Cloud drain handoff (scripts/cloud-drain-handoff.sh), and RBAC can
# name neither a namespace pattern nor a field. This policy narrows both to
# what the handoff does:
#   - a Deployment only in namespace `cloud` or a p-* namespace labelled
#     cloud.viktorbarzin.me/managed=true, and only a rollout restart: the
#     object equals the one it replaces except the pod template annotation
#     kubectl.kubernetes.io/restartedAt;
#   - only the Node the gate's pod runs on (the token's
#     authentication.kubernetes.io/node-name), and only spec.unschedulable
#     (cordon) and the cloud.viktorbarzin.me/drain label.
# Creates and deletes are refused outright (RBAC grants neither).
locals {
  kured_gate_user          = "system:serviceaccount:kured:kured-sentinel-gate"
  kured_gate_restart_key   = "kubectl.kubernetes.io/restartedAt"
  kured_gate_drain_label   = "cloud.viktorbarzin.me/drain"
  kured_gate_drain_values  = ["pending", "handed-off", "done"]
  kured_gate_managed_label = "cloud.viktorbarzin.me/managed"

  # "<path> is unchanged", including present-or-absent, for object and oldObject.
  kured_gate_same = "(has(object.%[1]s) == has(oldObject.%[1]s) && (!has(object.%[1]s) || object.%[1]s == oldObject.%[1]s))"

  kured_gate_deployment_same = [
    "metadata.labels", "metadata.annotations",
    "spec.replicas", "spec.selector", "spec.strategy", "spec.minReadySeconds",
    "spec.revisionHistoryLimit", "spec.paused", "spec.progressDeadlineSeconds",
    "spec.template.metadata.labels", "spec.template.spec",
  ]
  kured_gate_node_same = [
    "metadata.annotations",
    "spec.taints", "spec.podCIDR", "spec.podCIDRs", "spec.providerID", "spec.configSource", "spec.externalID",
  ]

  kured_gate_admission = {
    policy = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "kured-sentinel-gate-scope" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [
            { apiGroups = ["apps"], apiVersions = ["*"], operations = ["CREATE", "UPDATE", "DELETE"], resources = ["deployments"], scope = "Namespaced" },
            { apiGroups = [""], apiVersions = ["*"], operations = ["CREATE", "UPDATE", "DELETE"], resources = ["nodes"], scope = "Cluster" },
          ]
        }
        matchConditions = [{
          name       = "is-kured-sentinel-gate"
          expression = "request.userInfo.username == '${local.kured_gate_user}'"
        }]
        variables = [
          { name = "isNode", expression = "request.resource.resource == 'nodes'" },
          { name = "tAnns", expression = "request.operation == 'UPDATE' && !variables.isNode && has(object.spec.template.metadata.annotations) ? object.spec.template.metadata.annotations : {}" },
          { name = "oAnns", expression = "request.operation == 'UPDATE' && !variables.isNode && has(oldObject.spec.template.metadata.annotations) ? oldObject.spec.template.metadata.annotations : {}" },
          { name = "labels", expression = "request.operation == 'UPDATE' && has(object.metadata.labels) ? object.metadata.labels : {}" },
          { name = "oLabels", expression = "request.operation == 'UPDATE' && has(oldObject.metadata.labels) ? oldObject.metadata.labels : {}" },
        ]
        validations = [
          {
            expression = "request.operation == 'UPDATE'"
            message    = "kured-sentinel-gate may only update a Deployment or a Node, never create or delete one"
            reason     = "Forbidden"
          },
          {
            expression = "variables.isNode || request.namespace == 'cloud' || (request.namespace.startsWith('p-') && namespaceObject != null && has(namespaceObject.metadata.labels) && '${local.kured_gate_managed_label}' in namespaceObject.metadata.labels && namespaceObject.metadata.labels['${local.kured_gate_managed_label}'] == 'true')"
            message    = "kured-sentinel-gate may write Deployments only in namespace cloud or a p-* namespace labelled ${local.kured_gate_managed_label}=true"
            reason     = "Forbidden"
          },
          {
            expression = "variables.isNode || request.operation != 'UPDATE' || (${join(" && ", [for p in local.kured_gate_deployment_same : format(local.kured_gate_same, p)])} && variables.tAnns.all(k, k == '${local.kured_gate_restart_key}' || (k in variables.oAnns && variables.oAnns[k] == variables.tAnns[k])) && variables.oAnns.all(k, k == '${local.kured_gate_restart_key}' || k in variables.tAnns))"
            message    = "kured-sentinel-gate may only rollout-restart a Deployment: nothing but the pod template annotation ${local.kured_gate_restart_key} may change"
            reason     = "Forbidden"
          },
          {
            expression = "!variables.isNode || (has(request.userInfo.extra) && 'authentication.kubernetes.io/node-name' in request.userInfo.extra && request.userInfo.extra['authentication.kubernetes.io/node-name'].exists(n, n == request.name))"
            message    = "kured-sentinel-gate may write only the Node its own pod runs on"
            reason     = "Forbidden"
          },
          {
            expression = "!variables.isNode || request.operation != 'UPDATE' || (${join(" && ", [for p in local.kured_gate_node_same : format(local.kured_gate_same, p)])} && variables.labels.all(k, k == '${local.kured_gate_drain_label}' || (k in variables.oLabels && variables.oLabels[k] == variables.labels[k])) && variables.oLabels.all(k, k == '${local.kured_gate_drain_label}' || k in variables.labels) && (!('${local.kured_gate_drain_label}' in variables.labels) || variables.labels['${local.kured_gate_drain_label}'] in ${jsonencode(local.kured_gate_drain_values)}))"
            message    = "kured-sentinel-gate may change only spec.unschedulable and the label ${local.kured_gate_drain_label} (${join(", ", local.kured_gate_drain_values)}) on its Node"
            reason     = "Forbidden"
          },
        ]
      }
    }
    binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "kured-sentinel-gate-scope" }
      spec = {
        policyName        = "kured-sentinel-gate-scope"
        validationActions = ["Deny"]
      }
    }
  }
}
