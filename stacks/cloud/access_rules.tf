# What Cloud's reconciler may do in Kubernetes, and what may run in a Project
# namespace (Cloud v1 plan in the cloud repo, "Configuration": reconciler
# Kubernetes; the M2 contract, whose rendered names are in the cloud repo's
# docs/build/m2-contract-rendered.md). Locals only, so
# tests/cloud-access.test.sh applies exactly these rules and policies to a kind
# cluster, applies Cloud's real modules through them, and checks them. main.tf
# turns them into resources.
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
#   cloud-reconciler-scope  writes only in namespaces named p-* and labelled
#     cloud.viktorbarzin.me/managed=true; namespaces it creates, changes or
#     deletes must be named p-*, carry that label, tier=4-aux, Pod Security
#     enforce=restricted and both resource-governance/custom-* labels, and no
#     label outside a short allowlist; RoleBindings it writes may bind only
#     the project role to itself; the ResourceQuota and LimitRange it writes
#     are cloud-quota and cloud-limits, labelled
#     app.kubernetes.io/managed-by=cloud, and the quota counts every pod.
# and, for anyone, in managed namespaces:
#   cloud-externalsecret-store  an ExternalSecret may use only a namespaced
#     SecretStore, never the vault-kv or vault-database ClusterSecretStore
#     (which read all of secret/*).
#   cloud-managed-service  a Kubernetes Service is ClusterIP with no
#     externalIPs, and a port named edge targets the container port named
#     edge. Traefik follows ExternalName Kubernetes Services
#     (allowExternalNameServices in stacks/traefik), so an ExternalName
#     Kubernetes Service plus an Ingress would
#     publish any internal host; LoadBalancer, NodePort and externalIPs open
#     the node or the LAN.
#   cloud-managed-ingress  class traefik; every host is one label under
#     viktorbarzin.me (no wildcard, no host-less rule, no defaultBackend), not
#     a reserved App name from the Cloud v1 plan ("Configuration": reserved
#     App names) and not a host the homelab already routes (its parameter,
#     ConfigMap cloud/cloud-taken-hosts from taken_hosts.tf); every backend is
#     a Kubernetes Service port named edge. No tls.secretName: Traefik's default TLSStore serves the
#     wildcard, and a Project certificate would go into Traefik's global
#     store, where an exact SAN match beats the wildcard for every host. The
#     only annotations are the two Cloud renders: router.entrypoints
#     (websecure) and router.middlewares, which may name only the shared
#     homelab middlewares listed below. Every other annotation key is
#     refused, because cluster-wide controllers act on them: external-dns
#     (namespace technitium) writes viktorbarzin.lan records from
#     external-dns.alpha.kubernetes.io/*, homepage reads gethomepage.dev/*,
#     external-monitor-sync reads uptime.viktorbarzin.me/*.
#   cloud-managed-middleware  no Traefik Middleware at all. Cloud renders
#     none, and Traefik runs with allowCrossNamespace=true, so a Middleware
#     (errors, chain, plugin, forwardAuth, buffering) could reach another
#     namespace or hold request bodies in Traefik's memory.
#   cloud-managed-pod and cloud-managed-deployment  a pod, and a Deployment's
#     pod template, uses only emptyDir, configMap, secret, projected and
#     downwardAPI volumes; sets no runtimeClassName, nodeName, nodeSelector,
#     affinity, extra tolerations, host network, PID or IPC, init
#     containers, service account other than default, or priority class
#     other than tier-4-aux; requests no GPU or other extended resource; and
#     only a container named cookie-strip running the pinned Caddy image may
#     declare a port named edge. cookie-strip runs exactly as Cloud renders
#     it: the fixed args and env, no command, envFrom, lifecycle hook or exec
#     probe, a strip-* ConfigMap at /etc/caddy and its own emptyDir at
#     /run/caddy, and its own runAsUser, which no other container shares. No
#     shared process namespace. Every Deployment is a Cloud App or an App's
#     oauth2-proxy (label cloud.viktorbarzin.me/component), and an App's pod
#     template holds the cookie-strip container with port edge.
#   cloud-managed-strip-config  a ConfigMap named strip-* holds only the key
#     Caddyfile, and that file is the one Cloud renders (local
#     cloud_caddyfile_lines): only the App port, the host, the cookie list and
#     the App's own oauth2-proxy vary, and the list strips at least the
#     homelab's cookies.
#   cloud-managed-secretstore  a SecretStore is the in-cluster Vault, KV v2 at
#     secret/, Kubernetes auth role cloud-project as service account
#     cloud-secrets, and nothing else. Any other provider would let the ESO
#     controller fetch a URL or a secret store of the reconciler's choosing
#     and write the answer into a Project Secret.
#
# The edge chain. The homelab's forward-auth cookies (authentik_proxy_*,
# tsgate, anubis) are scoped to viktorbarzin.me, so every Project host
# receives them. Cloud's cookie-strip container removes them before a
# request reaches the App. The policies above make it the only way in:
# Traefik reaches a Project only through an Ingress, the Ingress names only a
# Kubernetes Service port named edge, that port targets the container port
# named edge, and only cookie-strip may have one. What cookie-strip does is
# fixed too: cloud-managed-pod and cloud-managed-deployment fix how it runs
# and what it mounts, and cloud-managed-strip-config fixes its Caddyfile.
# Cloud's own test (cookie-strip.test.ts) runs that Caddyfile in the pinned
# image; M4's live cookie test checks it end to end.
#
# Network. Calico tier "cloud" (main.tf) sits before the default tier and
# holds one infra-owned GlobalNetworkPolicy for every managed namespace,
# local.cloud_project_egress_floor below. The reconciler has no right in that
# tier, so a Project policy it writes in the default tier can only narrow
# access, never open the LAN, Vault or another namespace's Kubernetes
# Service.
#
# Pod Security. The reconciler must label each namespace
# pod-security.kubernetes.io/enforce=restricted, so the built-in, fail-closed
# PSA controller refuses privileged pods, host namespaces and ports, added
# capabilities, root and hostPath. Kyverno's privileged and host-namespace
# policies fail open (failurePolicy Ignore), so PSA is the boundary for
# those. Restricted still allows csi, ephemeral and persistentVolumeClaim
# volumes, which cloud-managed-pod refuses: no PersistentVolumeClaim on any
# storage class, and no in-tree nfs, iscsi or rbd volume, which the kubelet
# mounts from the node's network.
#
# Taken hosts. A ValidatingAdmissionPolicy sees only the object in the
# request, its namespace and a parameter object; it cannot list other
# Ingresses or IngressRoutes. So taken_hosts.tf writes the homelab's hosts
# into a ConfigMap at plan time, and cloud-managed-ingress refuses them. A
# host added after the last cloud apply is missing until the next one; the
# reconciler checks taken hosts itself before it applies, with its
# cluster-wide read on both kinds.
#
# Calico NetworkPolicies are served by the Calico API server, an aggregated
# API, so kube-apiserver admission policies do not see them. For those, the
# RoleBinding is the boundary: the reconciler can write them only in a
# namespace where it has bound the project role, and only in the default
# tier, which Calico evaluates after tier "cloud".
#
# Kyverno (stacks/kyverno, generate-conditions.tf) does not copy tls-secret
# (the *.viktorbarzin.me private key) or registry-credentials (the Forgejo
# cluster-puller token) into managed namespaces, so the reconciler's Secret
# read in a Project never reaches either. Kyverno's strip-cpu-limits also
# skips managed namespaces, because Cloud's ResourceQuota counts limits.cpu
# and would refuse every pod whose CPU limit Kyverno removed.

locals {
  cloud_namespace         = "cloud"
  cloud_managed_label     = "cloud.viktorbarzin.me/managed"
  cloud_component_label   = "cloud.viktorbarzin.me/component"
  cloud_reconciler_sa     = "cloud-reconciler"
  cloud_reconciler_user   = "system:serviceaccount:cloud:cloud-reconciler"
  cloud_project_role_name = "cloud-reconciler-project"

  cloud_base_domain_re = "viktorbarzin[.]me"

  cloud_write_verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]

  # The labels every namespace the reconciler creates or changes must carry,
  # with these values. The two resource-governance labels keep Kyverno from
  # generating its tier-4-aux quota and limit range; the reconciler writes
  # the namespace's only ones (cloud_governance below).
  cloud_namespace_required_labels = {
    (local.cloud_managed_label)             = "true"
    tier                                    = "4-aux"
    "pod-security.kubernetes.io/enforce"    = "restricted"
    "resource-governance/custom-quota"      = "true"
    "resource-governance/custom-limitrange" = "true"
  }

  # The only label keys the reconciler may set on a namespace. A key someone
  # else already set (Kyverno, an admin) may stay as it is. Anything else is
  # refused: labels select NetworkPolicies and Kyverno policies, for example
  # chrome-service.viktorbarzin.me/client=true opens Chrome DevTools (port
  # 9222).
  cloud_namespace_label_keys = concat(keys(local.cloud_namespace_required_labels), [
    "kubernetes.io/metadata.name",
    "pod-security.kubernetes.io/warn",
    "pod-security.kubernetes.io/audit",
  ])

  # The namespace's only ResourceQuota and LimitRange, written by the
  # reconciler. The quota must count requests and limits of CPU and memory
  # and pods, so no pod escapes it, and must allow no PersistentVolumeClaim,
  # LoadBalancer or NodePort. Kyverno's generated tier-quota and
  # tier-defaults carry no managed-by label, so the reconciler can neither
  # change nor delete them.
  cloud_governance = {
    label          = "app.kubernetes.io/managed-by"
    value          = "cloud"
    quota_name     = "cloud-quota"
    limits_name    = "cloud-limits"
    quota_required = ["requests.cpu", "requests.memory", "limits.cpu", "limits.memory", "pods"]
    quota_zero     = ["persistentvolumeclaims", "services.loadbalancers", "services.nodeports"]
  }

  # One DNS label under the base domain (ADR-0004 in the cloud repo: the free
  # certificate covers one level), and the plan's reserved App names.
  cloud_ingress_host_re     = "^[a-z0-9]([a-z0-9-]*[a-z0-9])?[.]${local.cloud_base_domain_re}$"
  cloud_ingress_reserved_re = "^(auth[a-z0-9-]*|login|sso|account|mail|vault|admin|api|www|status|cloud)[.]${local.cloud_base_domain_re}$"

  # The two Ingress annotations Cloud renders, and nothing else.
  cloud_ingress_middlewares_annotation = "traefik.ingress.kubernetes.io/router.middlewares"
  cloud_ingress_entrypoints_annotation = "traefik.ingress.kubernetes.io/router.entrypoints"
  cloud_ingress_annotations = [
    local.cloud_ingress_entrypoints_annotation,
    local.cloud_ingress_middlewares_annotation,
  ]
  cloud_ingress_class = "traefik"

  # The shared homelab middlewares (stacks/traefik) a Project Ingress may
  # name. Each is owned by this repo and passes no secret to the backend.
  # Most strip or add headers, compress, redirect or retry; crowdsec is a
  # plugin that asks CrowdSec's AppSec about the request, and rate-limit is a
  # chain of real-ip and rate-limit-per-client. Both are allowed on purpose.
  # Cloud names retry and rate-limit on public Apps (PUBLIC_MIDDLEWARES).
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

  # The App's way in (the edge chain in the header). The image is
  # IMAGES.cookieStrip in the cloud repo's src/reconciler/render.ts, which
  # renders it unchanged; tests/cloud-access.test.sh applies Cloud's real
  # modules, so a mismatch fails the test. Change both together.
  cloud_edge_port_name      = "edge"
  cloud_edge_container      = "cookie-strip"
  cloud_cookie_strip_image  = "docker.io/library/caddy:2.11.9-alpine@sha256:0bbb055bda6793c999bde78b1b5ce3e89f829fb031af2cf50056ea1246559fee"
  cloud_workload_components = ["app", "oauth2-proxy"]

  # How cookie-strip runs (the cloud repo's modules/app/main.tf). Anything
  # else would let the reconciler change what it strips without touching its
  # Caddyfile: a command or exec hook starts another process under
  # cookie-strip's uid, which can share port edge (SO_REUSEPORT) and take
  # requests unstripped; env and mounts can point Caddy at another config.
  cloud_cookie_strip_args = ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
  cloud_cookie_strip_env = {
    XDG_CONFIG_HOME = "/run/caddy/config"
    XDG_DATA_HOME   = "/run/caddy/data"
  }
  cloud_cookie_strip_config_dir = "/etc/caddy"
  cloud_cookie_strip_run_dir    = "/run/caddy"
  cloud_strip_config_prefix     = "strip-"

  # The Caddyfile cookie-strip runs (ConfigMap strip-<app>, key Caddyfile),
  # line by line, from the cloud repo's modules/app/Caddyfile.tftpl. The
  # policy cloud-managed-strip-config accepts only this file: leading comment
  # lines, then these lines in order with any indentation, a private App's
  # two oauth2-proxy blocks or neither. Placeholders:
  #   @APP@, @NS@  the App (the ConfigMap's name after strip-) and the
  #                namespace, filled in by the policy, so the only upstream
  #                besides the App is this App's own oauth2-proxy
  #   @HOST@       one label under the base domain (the sign-in redirect)
  #   @PORT@       the App's port on 127.0.0.1
  #   @COOKIES@    the cookie alternation; cloud_strip_cookies_required must
  #                each be in it
  cloud_caddyfile_lines = {
    head = [
      "{", "admin off", "auto_https off", "persist_config off", "servers {",
      "trusted_proxies static private_ranges", "}", "}", ":8080 {",
    ]
    signin = [
      "handle /oauth2/* {", "reverse_proxy auth-@APP@.@NS@.svc.cluster.local:80 {",
      "header_up X-Real-IP {client_ip}", "header_up X-Forwarded-Uri {uri}", "}", "}",
    ]
    handle = ["handle {"]
    forward_auth = [
      "forward_auth auth-@APP@.@NS@.svc.cluster.local:80 {", "uri /oauth2/auth",
      "header_up X-Real-IP {client_ip}", "@signin status 401", "handle_response @signin {",
      "redir * /oauth2/sign_in?rd=https://@HOST@{uri} 302", "}", "}",
    ]
    tail = [
      "reverse_proxy 127.0.0.1:@PORT@ {",
      "header_up Cookie `(?:^\\s*|;\\s*)(?:@COOKIES@)=[^;]*` \"\"",
      "header_up Cookie `^;\\s*` \"\"",
      "header_up -X-Authentik-*", "header_up -X_Authentik_*", "}", "}", "}",
    ]
  }
  # Each line as a regex: metacharacters escaped, any indentation, a newline.
  cloud_caddyfile_line_re = { for k, ls in local.cloud_caddyfile_lines : k => join("", [
    for l in ls : "[\\t ]*${replace(l, "/[\\\\.+*?()|\\[\\]{}^$]/", "\\$0")}\\n"
  ]) }
  # One cookie in the alternation: a name (a dot only escaped), optionally
  # followed by [^=;]* for a prefix.
  cloud_strip_cookie_re = "(?:[A-Za-z0-9_-]|\\\\[.])+(?:\\[\\^=;\\]\\*)?"
  cloud_caddyfile_re = replace(replace(replace(join("", [
    "^(?:[\\t ]*(?:#[^\\n]*)?\\n)*",
    local.cloud_caddyfile_line_re.head,
    "(?:",
    local.cloud_caddyfile_line_re.signin, local.cloud_caddyfile_line_re.handle, local.cloud_caddyfile_line_re.forward_auth,
    "|",
    local.cloud_caddyfile_line_re.handle,
    ")",
    local.cloud_caddyfile_line_re.tail,
    "(?:[\\t ]*\\n)*$",
    ]),
    "@HOST@", "[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.${local.cloud_base_domain_re}"),
    "@PORT@", "[0-9]{1,5}"),
  "@COOKIES@", "${local.cloud_strip_cookie_re}(?:\\|${local.cloud_strip_cookie_re})*")
  # The homelab's cookies scoped to viktorbarzin.me, in Cloud's strip_cookies
  # form (a trailing * is a prefix): Authentik's forward-auth session, the
  # Turnstile gate and Anubis. Cloud's list may hold more, never fewer.
  cloud_strip_cookies_required = ["authentik_proxy_*", "tsgate*", "anubis*"]
  # The same, as each appears in the Caddyfile's alternation, escaped.
  cloud_strip_cookies_required_re = [for c in local.cloud_strip_cookies_required : replace(
    endswith(c, "*") ? "${trimsuffix(c, "*")}[^=;]*" : c, "/[\\\\.+*?()|\\[\\]{}^$]/", "\\$0"
  )]

  # Hosts the homelab already routes (taken_hosts.tf collects them from every
  # Ingress and IngressRoute outside managed namespaces): one ConfigMap key
  # per host. cloud-managed-ingress reads it as its parameter and refuses a
  # Project Ingress for any of them; without it the policy refuses every
  # Ingress in managed namespaces.
  cloud_taken_hosts = {
    name      = "cloud-taken-hosts"
    namespace = local.cloud_namespace
  }

  # The only priority class a Project pod may carry; Kyverno injects it from
  # the namespace's tier=4-aux label when a pod has none.
  cloud_priority_class = "tier-4-aux"

  # Pod volumes and resources Cloud renders. Pod Security restricted already
  # refuses hostPath and the other node volumes.
  cloud_pod_volume_types = ["emptyDir", "configMap", "secret", "projected", "downwardAPI"]
  cloud_pod_resources    = ["cpu", "memory", "ephemeral-storage"]
  # The API server's DefaultTolerationSeconds plugin adds these two to every
  # pod; no other toleration is allowed.
  cloud_pod_default_tolerations = ["node.kubernetes.io/not-ready", "node.kubernetes.io/unreachable"]

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
    # The OpenTofu kubernetes provider lists CRDs to learn the type of every
    # kubernetes_manifest (SecretStore, ExternalSecret, Calico
    # NetworkPolicy); without this every plan fails. CRDs hold schemas only.
    { api_groups = ["apiextensions.k8s.io"], resources = ["customresourcedefinitions"], verbs = ["get", "list", "watch"], resource_names = [] },
    # Calico requires `get` on a tier to manage policies in it. Project
    # policies live in the default tier.
    { api_groups = ["projectcalico.org"], resources = ["tiers"], verbs = ["get"], resource_names = ["default"] },
  ]

  # Bound per Project namespace by a RoleBinding the reconciler creates there.
  # No Traefik Middlewares: Cloud renders none (cloud-managed-middleware).
  cloud_reconciler_project_rules = [
    { api_groups = [""], resources = ["resourcequotas", "limitranges", "serviceaccounts", "services", "secrets", "configmaps"], verbs = local.cloud_write_verbs, resource_names = [] },
    { api_groups = ["apps"], resources = ["deployments"], verbs = local.cloud_write_verbs, resource_names = [] },
    { api_groups = ["networking.k8s.io"], resources = ["ingresses"], verbs = local.cloud_write_verbs, resource_names = [] },
    { api_groups = ["external-secrets.io"], resources = ["externalsecrets", "secretstores"], verbs = local.cloud_write_verbs, resource_names = [] },
    # Calico checks both the plain resource and its per-tier pseudo-resource.
    { api_groups = ["projectcalico.org"], resources = ["networkpolicies"], verbs = local.cloud_write_verbs, resource_names = [] },
    { api_groups = ["projectcalico.org"], resources = ["tier.networkpolicies"], verbs = local.cloud_write_verbs, resource_names = ["default.*"] },
  ]

  # Egress from every Project (M2 contract point 2, Viktor's decision): the
  # internet directly, minus every private and special range, the home WAN
  # address and the homelab's public IPv6 prefixes. Cloud's own Project
  # policy excludes the same list (EGRESS_EXCLUDED in render.ts; the test
  # compares them).
  #   176.12.22.76/32  the home WAN IP. pfSense forwards WAN :443 to
  #     Traefik, so a pod reaching it hairpins into Traefik, and CrowdSec
  #     whitelists it (stacks/crowdsec). Same address as there.
  #   2001:470:...     Hurricane Electric prefixes; same list as the crowdsec
  #     allowlist in stacks/crowdsec.
  cloud_egress_excluded = {
    ipv4 = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "127.0.0.0/8", "176.12.22.76/32"]
    ipv6 = ["fc00::/7", "fe80::/10", "::1/128", "2001:470:5a7f::/48", "2001:470:6f:43d::/64", "2001:470:6e:43d::/64"]
  }

  # The network floor for every Project, owned by this repo (main.tf applies
  # it in Calico tier "cloud"). Calico evaluates tiers by order and the
  # first Allow or Deny wins, so a mistaken or hostile Allow-all from the
  # reconciler would otherwise open Vault, the LAN and every Kubernetes
  # Service without its own NetworkPolicy. The floor allows what every
  # Project needs, passes the internet (minus cloud_egress_excluded) and
  # other managed namespaces to the default tier, where the Project policy
  # can only narrow it, and denies the rest.
  #
  # Calico refuses a rule whose nets mix IPv4 and IPv6 (libcalico-go
  # validator, validateRule), so each family has its own rule.
  cloud_project_egress_floor = {
    apiVersion = "projectcalico.org/v3"
    kind       = "GlobalNetworkPolicy"
    metadata   = { name = "cloud.project-egress-floor" }
    spec = {
      tier              = "cloud"
      order             = 100
      selector          = "all()"
      namespaceSelector = "${local.cloud_managed_label} == 'true'"
      types             = ["Egress"]
      egress = [
        # node-local-dns answers on the kube-dns ClusterIP on every node, so
        # Calico usually sees that address. While node-local-dns restarts on
        # a node, queries reach the CoreDNS pods through kube-proxy instead
        # (stacks/calico, whisker-allow-dns-clusterip), so both are allowed.
        { action = "Allow", protocol = "UDP", destination = { nets = ["10.96.0.10/32"], ports = [53] } },
        { action = "Allow", protocol = "TCP", destination = { nets = ["10.96.0.10/32"], ports = [53] } },
        { action = "Allow", protocol = "UDP", destination = { namespaceSelector = "projectcalico.org/name == 'kube-system'", selector = "k8s-app == 'kube-dns'", ports = [53] } },
        { action = "Allow", protocol = "TCP", destination = { namespaceSelector = "projectcalico.org/name == 'kube-system'", selector = "k8s-app == 'kube-dns'", ports = [53] } },
        # Project databases live on the CNPG primary; its pg_hba keeps each
        # Project role in its own database (stacks/dbaas
        # cloud_postgres_rules.tf).
        {
          action   = "Allow"
          protocol = "TCP"
          destination = {
            namespaceSelector = "projectcalico.org/name == 'dbaas'"
            selector          = "cnpg.io/instanceRole == 'primary'"
            ports             = [5432]
          }
        },
        # A private App's oauth2-proxy redeems codes and reads keys at the
        # in-cluster Authentik server. *.viktorbarzin.me resolves inside the
        # cluster to Traefik's LoadBalancer address, which stays denied:
        # Traefik would see a 10.10.0.0/16 pod address, which the local-only
        # and home-lans-only middlewares admit.
        {
          action   = "Allow"
          protocol = "TCP"
          source   = { selector = "${local.cloud_component_label} == 'oauth2-proxy'" }
          destination = {
            namespaceSelector = "projectcalico.org/name == 'authentik'"
            selector          = "app.kubernetes.io/name == 'authentik' && app.kubernetes.io/component == 'server'"
            ports             = [9000]
          }
        },
        # Pods in a managed namespace: the Project policy allows only its own
        # namespace. A GlobalNetworkPolicy cannot say "the same namespace".
        { action = "Pass", destination = { namespaceSelector = "${local.cloud_managed_label} == 'true'" } },
        { action = "Pass", destination = { nets = ["0.0.0.0/0"], notNets = local.cloud_egress_excluded.ipv4 } },
        { action = "Pass", destination = { nets = ["::/0"], notNets = local.cloud_egress_excluded.ipv6 } },
        { action = "Deny" },
      ]
    }
  }

  cloud_governance_labelled = "has(%s.metadata.labels) && '${local.cloud_governance.label}' in %s.metadata.labels && %s.metadata.labels['${local.cloud_governance.label}'] == '${local.cloud_governance.value}'"
  cloud_label_is_true       = "has(%s.metadata.labels) && '${local.cloud_managed_label}' in %s.metadata.labels && %s.metadata.labels['${local.cloud_managed_label}'] == 'true'"

  # The pod rules, written once against @S (the pod spec) and used by
  # cloud-managed-pod (S = object.spec) and cloud-managed-deployment
  # (S = object.spec.template.spec), so a Deployment the reconciler writes
  # fails at apply time, not later in its ReplicaSet. The API server returns
  # the message of the first rule that fails, so GPU comes before priority:
  # Kyverno's inject-gpu-workload-priority gives a GPU pod priority class
  # gpu-workload before admission runs.
  cloud_pod_rules = [
    {
      expression = "!has(@S.initContainers) || size(@S.initContainers) == 0"
      message    = "in a Cloud namespace, a pod may not have init containers"
    },
    {
      expression = "@S.containers.all(c, !has(c.resources) || ((!has(dyn(c.resources).requests) || dyn(c.resources).requests.all(k, k in ${jsonencode(local.cloud_pod_resources)})) && (!has(dyn(c.resources).limits) || dyn(c.resources).limits.all(k, k in ${jsonencode(local.cloud_pod_resources)}))))"
      message    = "in a Cloud namespace, a container may request only ${join(", ", local.cloud_pod_resources)}: no GPU or other extended resource"
    },
    {
      expression = "!has(@S.volumes) || @S.volumes.all(v, ${join(" || ", [for t in local.cloud_pod_volume_types : "has(v.${t})"])})"
      message    = "in a Cloud namespace, a pod may use only ${join(", ", local.cloud_pod_volume_types)} volumes"
    },
    {
      expression = "!has(@S.runtimeClassName) || @S.runtimeClassName == ''"
      message    = "in a Cloud namespace, a pod may not set runtimeClassName"
    },
    {
      expression = "!has(@S.nodeName) || @S.nodeName == ''"
      message    = "in a Cloud namespace, a pod may not set nodeName"
    },
    {
      expression = "!has(@S.nodeSelector) || size(@S.nodeSelector) == 0"
      message    = "in a Cloud namespace, a pod may not set nodeSelector"
    },
    {
      expression = "!has(@S.affinity)"
      message    = "in a Cloud namespace, a pod may not set affinity"
    },
    {
      expression = "!has(@S.tolerations) || @S.tolerations.all(t, has(t.key) && t.key in ${jsonencode(local.cloud_pod_default_tolerations)} && has(t.effect) && t.effect == 'NoExecute')"
      message    = "in a Cloud namespace, a pod may carry only the API server's default not-ready and unreachable tolerations"
    },
    {
      expression = "!(has(@S.hostNetwork) && @S.hostNetwork) && !(has(@S.hostPID) && @S.hostPID) && !(has(@S.hostIPC) && @S.hostIPC)"
      message    = "in a Cloud namespace, a pod may not use the host network, PID or IPC namespace"
    },
    {
      # The class name is enough: the Priority admission plugin refuses a
      # pod whose priority or preemptionPolicy differs from its class.
      expression = "!has(@S.priorityClassName) || @S.priorityClassName == '' || @S.priorityClassName == '${local.cloud_priority_class}'"
      message    = "in a Cloud namespace, a pod may use only priority class ${local.cloud_priority_class}"
    },
    {
      # cloud-secrets is the SecretStore's Vault identity; a pod running as it
      # could log in to Vault itself.
      expression = "(!has(@S.serviceAccountName) || @S.serviceAccountName in ['', 'default']) && (!has(@S.serviceAccount) || @S.serviceAccount in ['', 'default'])"
      message    = "in a Cloud namespace, a pod runs as service account default"
    },
    {
      expression = "@S.containers.all(c, !has(c.ports) || c.ports.all(p, !has(p.name) || p.name != '${local.cloud_edge_port_name}') || (c.name == '${local.cloud_edge_container}' && c.image.startsWith('${local.cloud_cookie_strip_image}')))"
      message    = "in a Cloud namespace, only a container named ${local.cloud_edge_container} running ${local.cloud_cookie_strip_image} may declare a port named ${local.cloud_edge_port_name}"
    },
    {
      # The App container could otherwise see Caddy's process.
      expression = "!has(@S.shareProcessNamespace) || !@S.shareProcessNamespace"
      message    = "in a Cloud namespace, a pod may not share its process namespace"
    },
    {
      expression = "@S.containers.all(c, c.name != '${local.cloud_edge_container}' || (!has(c.command) && has(c.args) && c.args == ${jsonencode(local.cloud_cookie_strip_args)} && !has(c.envFrom) && (!has(c.env) || c.env.all(e, e.name in ${jsonencode(local.cloud_cookie_strip_env)} && has(e.value) && !has(e.valueFrom) && e.value == ${jsonencode(local.cloud_cookie_strip_env)}[e.name])) && !has(c.lifecycle) && (!has(c.livenessProbe) || !has(c.livenessProbe.exec)) && (!has(c.readinessProbe) || !has(c.readinessProbe.exec)) && (!has(c.startupProbe) || !has(c.startupProbe.exec))))"
      message    = "in a Cloud namespace, the ${local.cloud_edge_container} container runs as Cloud renders it: args ${join(" ", local.cloud_cookie_strip_args)}, env only ${join(" and ", keys(local.cloud_cookie_strip_env))}, and no command, envFrom, lifecycle hook or exec probe"
    },
    {
      expression = "@S.containers.all(c, c.name != '${local.cloud_edge_container}' || (has(c.volumeMounts) && size(c.volumeMounts) == 2 && c.volumeMounts.exists(m, m.mountPath == '${local.cloud_cookie_strip_config_dir}') && c.volumeMounts.exists(m, m.mountPath == '${local.cloud_cookie_strip_run_dir}') && c.volumeMounts.all(m, (!has(m.subPath) || m.subPath == '') && (!has(m.subPathExpr) || m.subPathExpr == '') && has(@S.volumes) && ((m.mountPath == '${local.cloud_cookie_strip_config_dir}' && has(m.readOnly) && m.readOnly && @S.volumes.exists(v, v.name == m.name && has(v.configMap) && has(v.configMap.name) && v.configMap.name.startsWith('${local.cloud_strip_config_prefix}') && !has(v.configMap.items))) || (m.mountPath == '${local.cloud_cookie_strip_run_dir}' && @S.volumes.exists(v, v.name == m.name && has(v.emptyDir)) && @S.containers.all(o, o.name == c.name || !has(o.volumeMounts) || o.volumeMounts.all(om, om.name != m.name)))))))"
      message    = "in a Cloud namespace, the ${local.cloud_edge_container} container mounts only a ${local.cloud_strip_config_prefix}* ConfigMap, read-only and whole, at ${local.cloud_cookie_strip_config_dir}, and an emptyDir no other container mounts at ${local.cloud_cookie_strip_run_dir}"
    },
    {
      # Two sockets share a port (SO_REUSEPORT) only under the same effective
      # uid, so App code under cookie-strip's uid could take a share of port
      # edge unstripped. Each container's uid is its own runAsUser, else the
      # pod's; an image's USER is invisible here, so every container sets one.
      expression = "@S.containers.all(c, c.name != '${local.cloud_edge_container}' || (has(c.securityContext) && has(c.securityContext.runAsUser) && @S.containers.all(o, o.name == c.name || (has(o.securityContext) && has(o.securityContext.runAsUser) ? o.securityContext.runAsUser : (has(@S.securityContext) && has(@S.securityContext.runAsUser) ? @S.securityContext.runAsUser : c.securityContext.runAsUser)) != c.securityContext.runAsUser)))"
      message    = "in a Cloud namespace, the ${local.cloud_edge_container} container sets its own runAsUser, and every other container runs as another uid, set on the container or the pod"
    },
  ]

  cloud_managed_binding = {
    validationActions = ["Deny"]
    matchResources = {
      namespaceSelector = { matchLabels = { (local.cloud_managed_label) = "true" } }
    }
  }

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
          # The object as written, or as it was for a DELETE.
          { name = "target", expression = "request.operation == 'DELETE' ? oldObject : object" },
          { name = "nsLabels", expression = "has(variables.target.metadata.labels) ? variables.target.metadata.labels : {}" },
          { name = "isRoleBinding", expression = "request.resource.group == 'rbac.authorization.k8s.io' && request.resource.resource == 'rolebindings'" },
          { name = "isQuota", expression = "request.resource.group == '' && request.resource.resource == 'resourcequotas'" },
          { name = "isLimitRange", expression = "request.resource.group == '' && request.resource.resource == 'limitranges'" },
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
            expression = "!variables.isNamespace || (variables.target.metadata.name.startsWith('p-') && ${format(local.cloud_label_is_true, "variables.target", "variables.target", "variables.target")} && 'tier' in variables.nsLabels && variables.nsLabels['tier'] == '4-aux')"
            message    = "cloud-reconciler may manage only namespaces named p-* labelled ${local.cloud_managed_label}=true and tier=4-aux"
            reason     = "Forbidden"
          },
          {
            expression = "!variables.isNamespace || request.operation == 'DELETE' || (${join(" && ", [for k, v in local.cloud_namespace_required_labels : "'${k}' in variables.nsLabels && variables.nsLabels['${k}'] == '${v}'"])})"
            message    = "cloud-reconciler namespaces must carry ${join(", ", [for k, v in local.cloud_namespace_required_labels : "${k}=${v}"])}"
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
          {
            # Both the object written and, on UPDATE and DELETE, the one it
            # replaces carry the label, so Kyverno's tier-quota and
            # tier-defaults (no label) cannot be changed, relabelled or
            # deleted. One name each keeps it to one quota and one range.
            expression = "!(variables.isQuota || variables.isLimitRange) || (${format(local.cloud_governance_labelled, "variables.target", "variables.target", "variables.target")} && (request.operation == 'CREATE' || (${format(local.cloud_governance_labelled, "oldObject", "oldObject", "oldObject")})) && variables.target.metadata.name == (variables.isQuota ? '${local.cloud_governance.quota_name}' : '${local.cloud_governance.limits_name}'))"
            message    = "cloud-reconciler may write only ResourceQuota ${local.cloud_governance.quota_name} and LimitRange ${local.cloud_governance.limits_name}, labelled ${local.cloud_governance.label}=${local.cloud_governance.value}"
            reason     = "Forbidden"
          },
          {
            # Scopes would let the quota skip pods (Terminating, BestEffort,
            # a priority class); a missing key would let pods skip it.
            expression = "!variables.isQuota || request.operation == 'DELETE' || (!has(object.spec.scopes) && !has(object.spec.scopeSelector) && has(object.spec.hard) && ${join(" && ", [for k in local.cloud_governance.quota_required : "'${k}' in object.spec.hard"])} && ${join(" && ", [for k in local.cloud_governance.quota_zero : "'${k}' in object.spec.hard && string(object.spec.hard['${k}']) == '0'"])})"
            message    = "cloud-reconciler's ResourceQuota must have no scopes, set ${join(", ", local.cloud_governance.quota_required)}, and set ${join(", ", local.cloud_governance.quota_zero)} to 0"
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
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-externalsecret-store" })
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
            message    = "in a Cloud namespace, a Kubernetes Service must be type ClusterIP (no ExternalName, NodePort or LoadBalancer)"
            reason     = "Forbidden"
          },
          {
            expression = "!has(object.spec.externalIPs) || size(object.spec.externalIPs) == 0"
            message    = "in a Cloud namespace, a Kubernetes Service may not set externalIPs"
            reason     = "Forbidden"
          },
          {
            expression = "!has(object.spec.ports) || object.spec.ports.all(p, !has(p.name) || p.name != '${local.cloud_edge_port_name}' || (has(p.targetPort) && string(p.targetPort) == '${local.cloud_edge_port_name}'))"
            message    = "in a Cloud namespace, a Kubernetes Service port named ${local.cloud_edge_port_name} must target the container port named ${local.cloud_edge_port_name}"
            reason     = "Forbidden"
          },
        ]
      }
    }
    managed_service_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-service" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-service" })
    }
    managed_ingress = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-ingress" }
      spec = {
        failurePolicy = "Fail"
        # local.cloud_taken_hosts, bound below.
        paramKind = { apiVersion = "v1", kind = "ConfigMap" }
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
            expression = "variables.anns.all(k, k in ${jsonencode(local.cloud_ingress_annotations)})"
            message    = "in a Cloud namespace, the only annotations an Ingress may set are ${join(", ", local.cloud_ingress_annotations)}"
            reason     = "Forbidden"
          },
          {
            expression = "'${local.cloud_ingress_entrypoints_annotation}' in variables.anns && variables.anns['${local.cloud_ingress_entrypoints_annotation}'] == 'websecure'"
            message    = "in a Cloud namespace, an Ingress sets ${local.cloud_ingress_entrypoints_annotation}: websecure"
            reason     = "Forbidden"
          },
          {
            expression = "!('${local.cloud_ingress_middlewares_annotation}' in variables.anns) || variables.anns['${local.cloud_ingress_middlewares_annotation}'].split(',').all(m, m.trim() in ${jsonencode(local.cloud_ingress_shared_middlewares)})"
            message    = "in a Cloud namespace, router.middlewares may name only ${join(", ", local.cloud_ingress_shared_middlewares)}"
            reason     = "Forbidden"
          },
          {
            expression = "has(object.spec.ingressClassName) && object.spec.ingressClassName == '${local.cloud_ingress_class}'"
            message    = "in a Cloud namespace, an Ingress sets ingressClassName ${local.cloud_ingress_class}"
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
          {
            # Traefik ranks routers by rule length, so a Project rule for a
            # homelab host with a longer path would win on that path.
            expression = "!has(params.data) || ((!has(object.spec.rules) || object.spec.rules.all(r, !has(r.host) || !(r.host in params.data))) && (!has(object.spec.tls) || object.spec.tls.all(t, !has(t.hosts) || t.hosts.all(h, !(h in params.data)))))"
            message    = "in a Cloud namespace, an Ingress may not use a host the homelab already routes (ConfigMap ${local.cloud_taken_hosts.namespace}/${local.cloud_taken_hosts.name})"
            reason     = "Forbidden"
          },
          {
            expression = "!has(object.spec.rules) || object.spec.rules.all(r, !has(r.http) || r.http.paths.all(p, has(p.backend.service) && has(p.backend.service.port) && has(p.backend.service.port.name) && p.backend.service.port.name == '${local.cloud_edge_port_name}' && !has(p.backend.service.port.number)))"
            message    = "in a Cloud namespace, every Ingress backend is a Kubernetes Service port named ${local.cloud_edge_port_name}"
            reason     = "Forbidden"
          },
        ]
      }
    }
    managed_ingress_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-ingress" }
      spec = merge(local.cloud_managed_binding, {
        policyName = "cloud-managed-ingress"
        # Fail closed: without the list, every Ingress in managed namespaces
        # is refused.
        paramRef = {
          name                    = local.cloud_taken_hosts.name
          namespace               = local.cloud_taken_hosts.namespace
          parameterNotFoundAction = "Deny"
        }
      })
    }
    managed_strip_config = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-strip-config" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = [""]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["configmaps"]
          }]
        }
        matchConditions = [{
          name       = "is-strip-config"
          expression = "object.metadata.name.startsWith('${local.cloud_strip_config_prefix}')"
        }]
        variables = [
          { name = "caddyfile", expression = "has(object.data) && 'Caddyfile' in object.data ? object.data['Caddyfile'] : ''" },
          # The one header_up Cookie line that strips cookies (a comment line
          # starts with #, so it cannot match).
          { name = "cookieLine", expression = "size(variables.caddyfile) <= 8192 ? variables.caddyfile.find(r'\\n[\\t ]*header_up Cookie `[^`\\n]*`') : ''" },
        ]
        validations = [
          {
            expression = "has(object.data) && size(object.data) == 1 && 'Caddyfile' in object.data && !has(object.binaryData)"
            message    = "in a Cloud namespace, a ${local.cloud_strip_config_prefix}* ConfigMap holds only the key Caddyfile"
            reason     = "Forbidden"
          },
          {
            expression = "size(variables.caddyfile) <= 8192 && variables.caddyfile.matches(r'${local.cloud_caddyfile_re}'.replace('@APP@', object.metadata.name.substring(${length(local.cloud_strip_config_prefix)})).replace('@NS@', request.namespace))"
            message    = "in a Cloud namespace, a ${local.cloud_strip_config_prefix}<app> Caddyfile is the one Cloud renders (modules/app/Caddyfile.tftpl), with only the App port, the host, the strip list and this App's oauth2-proxy filled in"
            reason     = "Forbidden"
          },
          {
            expression = "${join(" && ", [for c in local.cloud_strip_cookies_required_re : "variables.cookieLine.matches(r'[:|]${c}[|)]')"])}"
            message    = "in a Cloud namespace, a ${local.cloud_strip_config_prefix}<app> Caddyfile strips at least ${join(", ", local.cloud_strip_cookies_required)}"
            reason     = "Forbidden"
          },
        ]
      }
    }
    managed_strip_config_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-strip-config" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-strip-config" })
    }
    managed_middleware = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-middleware" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["traefik.io", "traefik.containo.us"]
            apiVersions = ["*"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["middlewares", "middlewaretcps"]
          }]
        }
        validations = [
          {
            expression = "false"
            message    = "in a Cloud namespace, no Traefik Middleware may exist (Cloud renders none; an Ingress names only the shared homelab middlewares)"
            reason     = "Forbidden"
          },
        ]
      }
    }
    managed_middleware_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-middleware" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-middleware" })
    }
    managed_pod = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-pod" }
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
        validations = [for r in local.cloud_pod_rules : {
          expression = replace(r.expression, "@S", "object.spec")
          message    = r.message
          reason     = "Forbidden"
        }]
      }
    }
    managed_pod_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-pod" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-pod" })
    }
    managed_deployment = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-deployment" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["apps"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["deployments"]
          }]
        }
        variables = [
          { name = "podLabels", expression = "has(object.spec.template.metadata) && has(object.spec.template.metadata.labels) ? object.spec.template.metadata.labels : {}" },
          { name = "component", expression = "'${local.cloud_component_label}' in variables.podLabels ? variables.podLabels['${local.cloud_component_label}'] : ''" },
        ]
        validations = concat(
          [
            {
              expression = "variables.component in ${jsonencode(local.cloud_workload_components)}"
              message    = "in a Cloud namespace, a Deployment's pods are labelled ${local.cloud_component_label} ${join(" or ", local.cloud_workload_components)}"
              reason     = "Forbidden"
            },
            {
              expression = "variables.component != 'app' || object.spec.template.spec.containers.exists(c, c.name == '${local.cloud_edge_container}' && c.image.startsWith('${local.cloud_cookie_strip_image}') && has(c.ports) && c.ports.exists(p, has(p.name) && p.name == '${local.cloud_edge_port_name}'))"
              message    = "in a Cloud namespace, an App Deployment holds a container named ${local.cloud_edge_container} running ${local.cloud_cookie_strip_image} with a port named ${local.cloud_edge_port_name}"
              reason     = "Forbidden"
            },
          ],
          [for r in local.cloud_pod_rules : {
            expression = replace(r.expression, "@S", "object.spec.template.spec")
            message    = r.message
            reason     = "Forbidden"
          }],
        )
      }
    }
    managed_deployment_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-deployment" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-deployment" })
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
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-secretstore" })
    }
  }
}
