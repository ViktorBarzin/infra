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
#     name from the Cloud v1 plan ("Configuration": reserved App names). No
#     tls.secretName: Traefik's default TLSStore serves the wildcard, and a
#     Project certificate would go into Traefik's global store, where an exact
#     SAN match beats the wildcard for every host. Traefik annotations are
#     limited to router.middlewares, router.entrypoints and router.tls, and
#     every middleware is the Ingress's own (<namespace>-<name>@kubernetescrd)
#     or one of the shared homelab middlewares listed below. Without that, an
#     Ingress could name another namespace's Middleware, for example one that
#     adds a shared secret header, and its own pod would receive the secret.
#   cloud-managed-middleware  Traefik runs with allowCrossNamespace=true, so a
#     Middleware can reach outside its namespace. errors, chain, plugin and
#     tap are refused (errors and tap name a Service in any namespace; chain
#     and plugin pull in other middlewares and plugins). forwardAuth may call
#     only a Service in its own namespace. Traefik makes those calls from its
#     own pods, so the Project's egress policy would not stop them. The name
#     has no dash, because Traefik joins namespace and name with a dash: with
#     dashes, p-a's Middleware "b-c" and p-a-b's Middleware "c" share the
#     reference p-a-b-c@kubernetescrd.
#   cloud-managed-pod-priority  a pod has no priorityClassName or tier-4-aux.
#     Kyverno's inject-priority-class-from-tier fills in the class only when
#     a pod has none, so without this a pod could ask for tier-0-core or
#     system-node-critical and preempt homelab workloads.
#   cloud-managed-secretstore  a SecretStore is the in-cluster Vault, KV v2 at
#     secret/, Kubernetes auth role cloud-project as service account
#     cloud-secrets, and nothing else. Any other provider would let the ESO
#     controller fetch a URL or a secret store of the reconciler's choosing
#     and write the answer into a Project Secret.
#
# Network. Calico tier "cloud" (main.tf) sits before the default tier and
# holds one infra-owned GlobalNetworkPolicy for every managed namespace: it
# denies egress to private and homelab addresses, except DNS, Postgres on
# pg-cluster-v18 and other managed namespaces, and passes the rest to the
# default tier. The reconciler has no right in that tier, so a Project policy
# it writes in the default tier can only narrow access, never open the LAN,
# Vault or another namespace's Service.
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
# namespace where it has bound the project role, and only in the default
# tier, which Calico evaluates after tier "cloud".
#
# Kyverno (stacks/kyverno, registry-credentials.tf) does not copy tls-secret
# (the *.viktorbarzin.me private key) or registry-credentials (the Forgejo
# cluster-puller token) into managed namespaces, so the reconciler's Secret
# read in a Project never reaches either.

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

  # The Traefik Ingress annotations a Project may set, and the shared homelab
  # middlewares (stacks/traefik) it may name besides its own. Each of these
  # strips or adds response headers, limits rates or compresses; none holds a
  # secret, calls another service with the request or returns another
  # service's response.
  cloud_ingress_middlewares_annotation = "traefik.ingress.kubernetes.io/router.middlewares"
  cloud_ingress_traefik_annotations = [
    local.cloud_ingress_middlewares_annotation,
    "traefik.ingress.kubernetes.io/router.entrypoints",
    "traefik.ingress.kubernetes.io/router.tls",
  ]
  cloud_ingress_shared_middlewares = [
    "traefik-strip-client-identity@kubernetescrd",
    "traefik-strip-auth-headers@kubernetescrd",
    "traefik-crowdsec@kubernetescrd",
    "traefik-rate-limit@kubernetescrd",
    "traefik-security-headers@kubernetescrd",
    "traefik-anti-ai-headers@kubernetescrd",
    "traefik-compress@kubernetescrd",
    "traefik-redirect-https@kubernetescrd",
    "traefik-retry@kubernetescrd",
  ]

  # Every field of the Traefik Middleware spec (chart 42.4.0, the version
  # stacks/traefik pins), sorted into allowed and refused. forwardAuth is
  # allowed only to a Service in the Middleware's own namespace.
  # tests/cloud-access.test.sh fails when the CRD gains a field that is in
  # neither list, so a Traefik upgrade cannot add an unchecked type.
  cloud_middleware_types_allowed = [
    "addPrefix", "basicAuth", "buffering", "circuitBreaker", "compress", "contentType", "digestAuth",
    "encodedCharacters", "forwardAuth", "grpcWeb", "headers", "inFlightReq", "ipAllowList", "ipWhiteList",
    "passTLSClientCert", "rateLimit", "redirectRegex", "redirectScheme", "replacePath", "replacePathRegex",
    "retry", "stripPrefix", "stripPrefixRegex",
  ]
  cloud_middleware_types_refused = ["chain", "errors", "plugin", "tap"]

  # The only priority class a Project pod may carry; Kyverno injects it from
  # the namespace's tier=4-aux label when a pod has none.
  cloud_priority_class = "tier-4-aux"

  # The SecretStore every Project uses: stacks/vault cloud.tf, role
  # cloud-project. ESO's vault provider tries the first auth method that is
  # set, so every other method is refused.
  cloud_secretstore_vault_server   = "http://vault-active.vault.svc.cluster.local:8200"
  cloud_secretstore_auth_refused   = ["appRole", "cert", "gcp", "iam", "jwt", "ldap", "namespace", "tokenSecretRef", "userPass"]
  cloud_secretstore_project_role   = "cloud-project"
  cloud_secretstore_project_sa     = "cloud-secrets"
  cloud_secretstore_project_mount  = "kubernetes"
  cloud_secretstore_project_kvpath = "secret"

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
            # The name check too: a homelab namespace someone labels by
            # mistake must not become reconciler-writable.
            expression = "variables.isNamespace || (namespaceObject != null && namespaceObject.metadata.name.startsWith('p-') && ${format(local.cloud_label_is_true, "namespaceObject", "namespaceObject", "namespaceObject")})"
            message    = "cloud-reconciler may write only in namespaces named p-* labelled ${local.cloud_managed_label}=true"
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
        variables = [
          { name = "anns", expression = "has(object.metadata.annotations) ? object.metadata.annotations : {}" },
        ]
        validations = [
          {
            expression = "variables.anns.all(k, !k.startsWith('traefik.ingress.kubernetes.io/') || k in ${jsonencode(local.cloud_ingress_traefik_annotations)})"
            message    = "in a Cloud namespace, the only Traefik annotations an Ingress may set are ${join(", ", local.cloud_ingress_traefik_annotations)}"
            reason     = "Forbidden"
          },
          {
            # A dash-free name after "<namespace>-" keeps the reference from
            # resolving to a Middleware in a namespace whose name extends this
            # one (cloud-managed-middleware refuses dashes in the name).
            expression = "!('${local.cloud_ingress_middlewares_annotation}' in variables.anns) || variables.anns['${local.cloud_ingress_middlewares_annotation}'].split(',').all(m, m.trim() in ${jsonencode(local.cloud_ingress_shared_middlewares)} || m.trim().matches('^' + request.namespace + '-[a-z0-9]+@kubernetescrd$'))"
            message    = "in a Cloud namespace, router.middlewares may name only this namespace's Middlewares (<namespace>-<name>@kubernetescrd) or ${join(", ", local.cloud_ingress_shared_middlewares)}"
            reason     = "Forbidden"
          },
          {
            expression = "!('traefik.ingress.kubernetes.io/router.entrypoints' in variables.anns) || variables.anns['traefik.ingress.kubernetes.io/router.entrypoints'].split(',').all(e, e.trim() in ['web', 'websecure'])"
            message    = "in a Cloud namespace, router.entrypoints may be only web or websecure"
            reason     = "Forbidden"
          },
          {
            expression = "!has(object.spec.tls) || object.spec.tls.all(t, !has(t.secretName))"
            message    = "in a Cloud namespace, an Ingress may not set tls.secretName (Traefik's default TLSStore serves the wildcard certificate)"
            reason     = "Forbidden"
          },
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
    managed_middleware = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-middleware" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["traefik.io"]
            apiVersions = ["*"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["middlewares"]
          }]
        }
        validations = [
          {
            expression = "object.metadata.name.matches('^[a-z0-9]+$')"
            message    = "in a Cloud namespace, a Middleware name is lowercase letters and digits only (Traefik joins namespace and name with a dash)"
            reason     = "Forbidden"
          },
          {
            expression = "!has(object.spec) || (${join(" && ", [for t in local.cloud_middleware_types_refused : "!has(object.spec.${t})"])})"
            message    = "in a Cloud namespace, a Middleware may not be of type ${join(", ", local.cloud_middleware_types_refused)}"
            reason     = "Forbidden"
          },
          {
            # Userinfo, another host or another namespace cannot fit: the host
            # is <service>.<this namespace>.svc[.cluster.local], then an
            # optional port, then an optional path.
            expression = "!has(object.spec) || !has(object.spec.forwardAuth) || (has(object.spec.forwardAuth.address) && object.spec.forwardAuth.address.matches('^http://[a-z0-9]([a-z0-9-]*[a-z0-9])?[.]' + request.namespace + '[.]svc([.]cluster[.]local)?(:[0-9]+)?(/[^@]*)?$'))"
            message    = "in a Cloud namespace, forwardAuth.address must be http://<service>.<this namespace>.svc[.cluster.local][:port][/path]"
            reason     = "Forbidden"
          },
        ]
      }
    }
    managed_middleware_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-middleware" }
      spec = {
        policyName        = "cloud-managed-middleware"
        validationActions = ["Deny"]
        matchResources = {
          namespaceSelector = { matchLabels = { (local.cloud_managed_label) = "true" } }
        }
      }
    }
    managed_pod_priority = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-pod-priority" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = [""]
            apiVersions = ["v1"]
            operations  = ["CREATE"]
            resources   = ["pods"]
          }]
        }
        # The class name is enough: the Priority admission plugin refuses a
        # pod whose priority or preemptionPolicy differs from its class.
        validations = [
          {
            expression = "!has(object.spec.priorityClassName) || object.spec.priorityClassName == '' || object.spec.priorityClassName == '${local.cloud_priority_class}'"
            message    = "in a Cloud namespace, a pod may use only priority class ${local.cloud_priority_class}"
            reason     = "Forbidden"
          },
        ]
      }
    }
    managed_pod_priority_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-pod-priority" }
      spec = {
        policyName        = "cloud-managed-pod-priority"
        validationActions = ["Deny"]
        matchResources = {
          namespaceSelector = { matchLabels = { (local.cloud_managed_label) = "true" } }
        }
      }
    }
    managed_secretstore = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-secretstore" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["external-secrets.io"]
            apiVersions = ["*"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["secretstores"]
          }]
        }
        # ESO uses one provider per store and refuses a store with two, so
        # requiring vault rules out every other provider.
        validations = [
          {
            expression = "has(object.spec.provider) && has(object.spec.provider.vault) && has(object.spec.provider.vault.server) && object.spec.provider.vault.server == '${local.cloud_secretstore_vault_server}' && has(object.spec.provider.vault.path) && object.spec.provider.vault.path == '${local.cloud_secretstore_project_kvpath}' && has(object.spec.provider.vault.version) && object.spec.provider.vault.version == 'v2' && !has(object.spec.provider.vault.namespace)"
            message    = "in a Cloud namespace, a SecretStore must use provider vault with server ${local.cloud_secretstore_vault_server}, path ${local.cloud_secretstore_project_kvpath} and version v2"
            reason     = "Forbidden"
          },
          {
            expression = "has(object.spec.provider) && has(object.spec.provider.vault) && has(object.spec.provider.vault.auth) && has(object.spec.provider.vault.auth.kubernetes) && ${join(" && ", [for a in local.cloud_secretstore_auth_refused : "!has(object.spec.provider.vault.auth.${a})"])}"
            message    = "in a Cloud namespace, a SecretStore may authenticate to Vault only with Kubernetes auth"
            reason     = "Forbidden"
          },
          {
            expression = "!has(object.spec.provider) || !has(object.spec.provider.vault) || !has(object.spec.provider.vault.auth) || !has(object.spec.provider.vault.auth.kubernetes) || (has(object.spec.provider.vault.auth.kubernetes.role) && object.spec.provider.vault.auth.kubernetes.role == '${local.cloud_secretstore_project_role}' && (!has(object.spec.provider.vault.auth.kubernetes.mountPath) || object.spec.provider.vault.auth.kubernetes.mountPath == '${local.cloud_secretstore_project_mount}') && !has(object.spec.provider.vault.auth.kubernetes.secretRef) && has(object.spec.provider.vault.auth.kubernetes.serviceAccountRef) && object.spec.provider.vault.auth.kubernetes.serviceAccountRef.name == '${local.cloud_secretstore_project_sa}' && (!has(object.spec.provider.vault.auth.kubernetes.serviceAccountRef.namespace) || object.spec.provider.vault.auth.kubernetes.serviceAccountRef.namespace == request.namespace))"
            message    = "in a Cloud namespace, a SecretStore must log in to Vault mount ${local.cloud_secretstore_project_mount} with role ${local.cloud_secretstore_project_role} as service account ${local.cloud_secretstore_project_sa}"
            reason     = "Forbidden"
          },
        ]
      }
    }
    managed_secretstore_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-secretstore" }
      spec = {
        policyName        = "cloud-managed-secretstore"
        validationActions = ["Deny"]
        matchResources = {
          namespaceSelector = { matchLabels = { (local.cloud_managed_label) = "true" } }
        }
      }
    }
  }
}
