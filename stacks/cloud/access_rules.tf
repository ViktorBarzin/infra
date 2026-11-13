# What Cloud's reconciler may do in Kubernetes (Cloud v1 plan in the cloud
# repo, "Configuration": reconciler Kubernetes). Locals only, so
# tests/cloud-access.test.sh applies exactly these rules and policies to a kind
# cluster and checks them. main.tf turns them into resources.
#
# Two layers, because neither is enough alone:
#
# RBAC. A ClusterRoleBinding on Secrets, ConfigMaps and the rest would let the
# reconciler READ every Secret in the cluster, and no admission policy sees a
# read. So the cluster-wide role holds only what has to be cluster-wide:
# namespaces, RoleBindings (to wire up a new namespace), `bind` on the project
# role and nothing else, and read on Ingresses and IngressRoutes (to find hosts
# already taken). Everything a Project contains is in the project role, which
# the reconciler binds to itself with a RoleBinding inside each Project
# namespace it creates. RBAC lets it bind that role and no other: `bind` is
# limited to that name, and it holds none of the rights of admin or edit.
#
# Admission. ValidatingAdmissionPolicies (built in since Kubernetes 1.30; this
# cluster runs 1.35) then limit every write the reconciler makes:
#   cloud-reconciler-scope  writes only in namespaces labelled
#     cloud.viktorbarzin.me/managed=true; namespaces it creates, changes or
#     deletes must be named p-*, carry that label, tier=4-aux and Pod Security
#     enforce=baseline or restricted, and no label outside a short allowlist;
#     RoleBindings it writes may bind only the project role to itself.
# and, for anyone, in managed namespaces:
#   cloud-externalsecret-store  an ExternalSecret may use only a namespaced
#     SecretStore, never the vault-kv or vault-database ClusterSecretStore
#     (which read all of secret/*).
#   cloud-managed-service  a Service is ClusterIP with no externalIPs. Traefik
#     follows ExternalName Services (allowExternalNameServices in
#     stacks/traefik), so an ExternalName Service plus an Ingress would
#     publish any internal host; LoadBalancer, NodePort and externalIPs open
#     the node or the LAN.
#   cloud-managed-ingress  every host is one label under viktorbarzin.me (no
#     wildcard, no host-less rule, no defaultBackend) and not a reserved App
#     name from the Cloud v1 plan ("Configuration": reserved App names).
#
# Pod Security. The reconciler's pods could otherwise mount the node's / with
# hostPath: Kyverno's privileged and host-namespace policies fail open
# (failurePolicy Ignore) and no Kyverno policy covers hostPath. The Pod
# Security Admission label the reconciler must set makes the built-in,
# fail-closed PSA controller refuse those pods. Baseline blocks hostPath,
# host namespaces, host ports, privileged and added capabilities; restricted
# also requires non-root. The reconciler chooses per Project.
#
# Not here, by necessity: "an Ingress host in a managed namespace must not equal
# a host routed outside managed namespaces". A ValidatingAdmissionPolicy sees
# only the object in the request, its namespace and fixed parameter objects; it
# cannot list other Ingresses or IngressRoutes. The reconciler checks this
# before it applies, using its cluster-wide read on both. The static part of
# the rule (host shape, reserved names) is cloud-managed-ingress.
#
# Calico NetworkPolicies are served by the Calico API server, an aggregated
# API, so kube-apiserver admission policies may not see them. For those, the
# RoleBinding is the boundary: the reconciler can write them only in a
# namespace where it has bound the project role.

locals {
  cloud_namespace         = "cloud"
  cloud_managed_label     = "cloud.viktorbarzin.me/managed"
  cloud_reconciler_sa     = "cloud-reconciler"
  cloud_reconciler_user   = "system:serviceaccount:cloud:cloud-reconciler"
  cloud_project_role_name = "cloud-reconciler-project"

  cloud_base_domain_re = "viktorbarzin[.]me"

  cloud_write_verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]

  # The only label keys the reconciler may set on a namespace. A key someone
  # else already set (Kyverno, an admin) may stay as it is. Anything else is
  # refused: labels select NetworkPolicies and Kyverno policies, for example
  # chrome-service.viktorbarzin.me/client=true opens Chrome DevTools (port
  # 9222) and resource-governance/custom-quota=true drops the tier quota.
  cloud_namespace_label_keys = [
    local.cloud_managed_label,
    "tier",
    "kubernetes.io/metadata.name",
    "pod-security.kubernetes.io/enforce",
    "pod-security.kubernetes.io/warn",
    "pod-security.kubernetes.io/audit",
  ]

  # One DNS label under the base domain (ADR-0004 in the cloud repo: the free
  # certificate covers one level), and the plan's reserved App names.
  cloud_ingress_host_re     = "^[a-z0-9]([a-z0-9-]*[a-z0-9])?[.]${local.cloud_base_domain_re}$"
  cloud_ingress_reserved_re = "^(auth[a-z0-9-]*|login|sso|account|mail|vault|admin|api|www|status|cloud)[.]${local.cloud_base_domain_re}$"

  # Bound cluster-wide (ClusterRoleBinding cloud-reconciler).
  cloud_reconciler_cluster_rules = [
    { api_groups = [""], resources = ["namespaces"], verbs = local.cloud_write_verbs, resource_names = [] },
    # Create the RoleBinding to the project role in each new Project
    # namespace. Admission keeps these writes in managed namespaces.
    { api_groups = ["rbac.authorization.k8s.io"], resources = ["rolebindings"], verbs = local.cloud_write_verbs, resource_names = [] },
    { api_groups = ["rbac.authorization.k8s.io"], resources = ["clusterroles"], verbs = ["bind"], resource_names = [local.cloud_project_role_name] },
    # Hosts already routed, so a Project cannot take one.
    { api_groups = ["networking.k8s.io"], resources = ["ingresses"], verbs = ["get", "list", "watch"], resource_names = [] },
    { api_groups = ["traefik.io"], resources = ["ingressroutes"], verbs = ["get", "list", "watch"], resource_names = [] },
    # Calico requires `get` on a tier to manage policies in it. Project
    # policies live in the default tier.
    { api_groups = ["projectcalico.org"], resources = ["tiers"], verbs = ["get"], resource_names = ["default"] },
  ]

  # Bound per Project namespace by a RoleBinding the reconciler creates there.
  cloud_reconciler_project_rules = [
    { api_groups = [""], resources = ["resourcequotas", "limitranges", "serviceaccounts", "services", "secrets", "configmaps"], verbs = local.cloud_write_verbs, resource_names = [] },
    { api_groups = ["apps"], resources = ["deployments"], verbs = local.cloud_write_verbs, resource_names = [] },
    { api_groups = ["networking.k8s.io"], resources = ["ingresses"], verbs = local.cloud_write_verbs, resource_names = [] },
    { api_groups = ["external-secrets.io"], resources = ["externalsecrets", "secretstores"], verbs = local.cloud_write_verbs, resource_names = [] },
    { api_groups = ["traefik.io"], resources = ["middlewares"], verbs = local.cloud_write_verbs, resource_names = [] },
    # Calico checks both the plain resource and its per-tier pseudo-resource.
    { api_groups = ["projectcalico.org"], resources = ["networkpolicies"], verbs = local.cloud_write_verbs, resource_names = [] },
    { api_groups = ["projectcalico.org"], resources = ["tier.networkpolicies"], verbs = local.cloud_write_verbs, resource_names = ["default.*"] },
  ]

  cloud_label_is_true = "has(%s.metadata.labels) && '${local.cloud_managed_label}' in %s.metadata.labels && %s.metadata.labels['${local.cloud_managed_label}'] == 'true'"

  cloud_admission_policies = {
    reconciler_scope = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-reconciler-scope" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["*"]
            apiVersions = ["*"]
            operations  = ["CREATE", "UPDATE", "DELETE"]
            resources   = ["*/*"]
            scope       = "*"
          }]
        }
        matchConditions = [{
          name       = "is-cloud-reconciler"
          expression = "request.userInfo.username == '${local.cloud_reconciler_user}'"
        }]
        variables = [
          { name = "isNamespace", expression = "request.resource.group == '' && request.resource.resource == 'namespaces'" },
          { name = "ns", expression = "request.operation == 'DELETE' ? oldObject : object" },
          { name = "nsLabels", expression = "has(variables.ns.metadata.labels) ? variables.ns.metadata.labels : {}" },
          { name = "isRoleBinding", expression = "request.resource.group == 'rbac.authorization.k8s.io' && request.resource.resource == 'rolebindings'" },
        ]
        validations = [
          {
            expression = "variables.isNamespace || (namespaceObject != null && ${format(local.cloud_label_is_true, "namespaceObject", "namespaceObject", "namespaceObject")})"
            message    = "cloud-reconciler may write only in namespaces labelled ${local.cloud_managed_label}=true"
            reason     = "Forbidden"
          },
          {
            expression = "!variables.isNamespace || (variables.ns.metadata.name.startsWith('p-') && ${format(local.cloud_label_is_true, "variables.ns", "variables.ns", "variables.ns")} && 'tier' in variables.nsLabels && variables.nsLabels['tier'] == '4-aux')"
            message    = "cloud-reconciler may manage only namespaces named p-* labelled ${local.cloud_managed_label}=true and tier=4-aux"
            reason     = "Forbidden"
          },
          {
            expression = "!variables.isNamespace || request.operation == 'DELETE' || ('pod-security.kubernetes.io/enforce' in variables.nsLabels && variables.nsLabels['pod-security.kubernetes.io/enforce'] in ['baseline', 'restricted'])"
            message    = "cloud-reconciler namespaces must carry pod-security.kubernetes.io/enforce=baseline or restricted"
            reason     = "Forbidden"
          },
          {
            expression = "!variables.isNamespace || request.operation == 'DELETE' || variables.nsLabels.all(k, k in ${jsonencode(local.cloud_namespace_label_keys)} || (request.operation == 'UPDATE' && has(oldObject.metadata.labels) && k in oldObject.metadata.labels && oldObject.metadata.labels[k] == variables.nsLabels[k]))"
            message    = "cloud-reconciler may set only these namespace labels: ${join(", ", local.cloud_namespace_label_keys)}"
            reason     = "Forbidden"
          },
          {
            # RBAC already stops it binding a role stronger than its own; this
            # stops it handing the project role to anyone else, such as
            # another Project's service account or system:authenticated.
            expression = "!variables.isRoleBinding || request.operation == 'DELETE' || (object.roleRef.kind == 'ClusterRole' && object.roleRef.name == '${local.cloud_project_role_name}' && has(object.subjects) && size(object.subjects) == 1 && object.subjects.all(s, s.kind == 'ServiceAccount' && s.name == '${local.cloud_reconciler_sa}' && has(s.namespace) && s.namespace == '${local.cloud_namespace}'))"
            message    = "cloud-reconciler may bind only ClusterRole ${local.cloud_project_role_name}, and only to service account ${local.cloud_namespace}/${local.cloud_reconciler_sa}"
            reason     = "Forbidden"
          },
          {
            # Name and label checks above cover the new object; this stops an
            # update that adopts a namespace someone else created.
            expression = "!variables.isNamespace || request.operation != 'UPDATE' || (${format(local.cloud_label_is_true, "oldObject", "oldObject", "oldObject")})"
            message    = "cloud-reconciler may not label an existing namespace as managed"
            reason     = "Forbidden"
          },
        ]
      }
    }
    reconciler_scope_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-reconciler-scope" }
      spec = {
        policyName        = "cloud-reconciler-scope"
        validationActions = ["Deny"]
      }
    }
    externalsecret_store = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-externalsecret-store" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["external-secrets.io"]
            apiVersions = ["*"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["externalsecrets"]
          }]
        }
        validations = [
          {
            expression = "!has(object.spec.secretStoreRef) || !has(object.spec.secretStoreRef.kind) || object.spec.secretStoreRef.kind == 'SecretStore'"
            message    = "in a Cloud namespace, spec.secretStoreRef must be a SecretStore, not a ClusterSecretStore"
            reason     = "Forbidden"
          },
          {
            expression = "!has(object.spec.data) || object.spec.data.all(d, !has(d.sourceRef) || !has(d.sourceRef.storeRef) || !has(d.sourceRef.storeRef.kind) || d.sourceRef.storeRef.kind == 'SecretStore')"
            message    = "in a Cloud namespace, spec.data[].sourceRef.storeRef must be a SecretStore"
            reason     = "Forbidden"
          },
          {
            expression = "!has(object.spec.dataFrom) || object.spec.dataFrom.all(d, !has(d.sourceRef) || ((!has(d.sourceRef.storeRef) || !has(d.sourceRef.storeRef.kind) || d.sourceRef.storeRef.kind == 'SecretStore') && (!has(d.sourceRef.generatorRef) || !has(d.sourceRef.generatorRef.kind) || d.sourceRef.generatorRef.kind != 'ClusterGenerator')))"
            message    = "in a Cloud namespace, spec.dataFrom[].sourceRef may use only a SecretStore or a namespaced generator"
            reason     = "Forbidden"
          },
        ]
      }
    }
    externalsecret_store_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-externalsecret-store" }
      spec = {
        policyName        = "cloud-externalsecret-store"
        validationActions = ["Deny"]
        matchResources = {
          namespaceSelector = { matchLabels = { (local.cloud_managed_label) = "true" } }
        }
      }
    }
    managed_service = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-service" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = [""]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["services"]
          }]
        }
        validations = [
          {
            expression = "!has(object.spec.type) || object.spec.type == 'ClusterIP'"
            message    = "in a Cloud namespace, a Service must be type ClusterIP (no ExternalName, NodePort or LoadBalancer)"
            reason     = "Forbidden"
          },
          {
            expression = "!has(object.spec.externalIPs) || size(object.spec.externalIPs) == 0"
            message    = "in a Cloud namespace, a Service may not set externalIPs"
            reason     = "Forbidden"
          },
        ]
      }
    }
    managed_service_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-service" }
      spec = {
        policyName        = "cloud-managed-service"
        validationActions = ["Deny"]
        matchResources = {
          namespaceSelector = { matchLabels = { (local.cloud_managed_label) = "true" } }
        }
      }
    }
    managed_ingress = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-ingress" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["networking.k8s.io"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["ingresses"]
          }]
        }
        validations = [
          {
            expression = "!has(object.spec.defaultBackend)"
            message    = "in a Cloud namespace, an Ingress may not set defaultBackend (it catches every host)"
            reason     = "Forbidden"
          },
          {
            expression = "!has(object.spec.rules) || object.spec.rules.all(r, has(r.host) && r.host.matches('${local.cloud_ingress_host_re}'))"
            message    = "in a Cloud namespace, every Ingress rule needs a host of the form <name>.viktorbarzin.me (one label, no wildcard)"
            reason     = "Forbidden"
          },
          {
            expression = "!has(object.spec.tls) || object.spec.tls.all(t, !has(t.hosts) || t.hosts.all(h, h.matches('${local.cloud_ingress_host_re}')))"
            message    = "in a Cloud namespace, every Ingress TLS host must be of the form <name>.viktorbarzin.me (one label, no wildcard)"
            reason     = "Forbidden"
          },
          {
            expression = "(!has(object.spec.rules) || object.spec.rules.all(r, !has(r.host) || !r.host.matches('${local.cloud_ingress_reserved_re}'))) && (!has(object.spec.tls) || object.spec.tls.all(t, !has(t.hosts) || t.hosts.all(h, !h.matches('${local.cloud_ingress_reserved_re}'))))"
            message    = "in a Cloud namespace, an Ingress may not use a reserved name (auth*, login, sso, account, mail, vault, admin, api, www, status, cloud)"
            reason     = "Forbidden"
          },
        ]
      }
    }
    managed_ingress_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-ingress" }
      spec = {
        policyName        = "cloud-managed-ingress"
        validationActions = ["Deny"]
        matchResources = {
          namespaceSelector = { matchLabels = { (local.cloud_managed_label) = "true" } }
        }
      }
    }
  }
}
