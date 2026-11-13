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
#     app.kubernetes.io/managed-by=cloud, and the quota counts every pod's
#     CPU, memory and ephemeral storage.
# and, for anyone, in managed namespaces:
#   cloud-externalsecret-store  an ExternalSecret may use only a namespaced
#     SecretStore, never the vault-kv or vault-database ClusterSecretStore
#     (which read all of secret/*).
#   cloud-managed-service  a Kubernetes Service is ClusterIP with no
#     externalIPs and no prometheus.io/* annotation. An edge Service (edge-*)
#     selects only that App's edge pods and has one port, edge, targeting the
#     container port edge; an oauth2-proxy Service (auth-*) selects only that
#     App's oauth2-proxy pods on port http. Traefik follows ExternalName
#     Kubernetes Services (allowExternalNameServices in stacks/traefik), so an
#     ExternalName Kubernetes Service plus an Ingress would publish any
#     internal host; LoadBalancer, NodePort and externalIPs open the node or
#     the LAN.
#   cloud-managed-ingress  class traefik; every host is one label under
#     viktorbarzin.me (no wildcard, no host-less rule, no defaultBackend), not
#     a reserved App name from the Cloud v1 plan ("Configuration": reserved
#     App names) and not a host the homelab already routes (written into the
#     policy itself, see "Taken hosts" below); every backend is
#     an edge Service on port edge or an oauth2-proxy Service on port http,
#     by port name. No tls.secretName: Traefik's default TLSStore serves the
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
#     pod template, uses only emptyDir (each with a sizeLimit), configMap,
#     secret, projected and downwardAPI volumes; sets no runtimeClassName,
#     nodeName, nodeSelector, affinity, extra tolerations, host network, PID
#     or IPC, init containers, shared process namespace, service account other
#     than default, priority class other than tier-4-aux, or prometheus.io/*
#     annotation; requests no GPU or other extended resource; and limits the
#     ephemeral storage of every container. Every pod is labelled
#     cloud.viktorbarzin.me/component app, edge or oauth2-proxy. An edge pod
#     runs exactly the edge Cloud renders and an oauth2-proxy pod exactly the
#     oauth2-proxy Cloud renders (local.cloud_edge, local.cloud_oauth2_proxy):
#     one container, the pinned image, fixed args and env, no command, hook or
#     exec probe, fixed ports and mounts, and for the edge its readiness
#     probe. App pods are free, within the rules above.
#   cloud-managed-edge-config  a ConfigMap named edge-* holds only the key
#     Caddyfile, and that file is the one Cloud renders (local
#     cloud_caddyfile_lines): only the cookie list and the App's own
#     upstream vary, and the list strips at least the homelab's cookies.
#   cloud-managed-secretstore  a SecretStore is the in-cluster Vault, KV v2 at
#     secret/, Kubernetes auth role cloud-project as service account
#     cloud-secrets, and nothing else. Any other provider would let the ESO
#     controller fetch a URL or a secret store of the reconciler's choosing
#     and write the answer into a Project Secret.
#
# The edge chain (M2 contract, Addendum v2 point 8). The homelab's
# forward-auth cookies (authentik_proxy_*, tsgate, Anubis's
# techaro.lol-anubis-auth) are scoped to viktorbarzin.me, so every Project
# host receives them. Cloud's edge, a pinned Caddy in its own Deployment
# edge-<app>, removes them before a request reaches the App, and removes every
# Set-Cookie with a Domain attribute on the way back. The policies above make
# it the only way in:
#   public:  Traefik -> Service edge-<app>:edge -> edge pod -> App
#   private: Traefik -> Service auth-<app>:http -> oauth2-proxy pod, whose
#            only upstream is http://edge-<app>.<ns>.svc.cluster.local:80/
#            -> edge pod -> App
# Traefik reaches a Project only through an Ingress; the Ingress names only
# an edge-* or auth-* Service; those Services select only edge or
# oauth2-proxy pods; and those pods run only Cloud's pinned images, args and
# config. No App code runs in an edge or oauth2-proxy pod, so App code can
# never own the edge's socket. The Calico floor below lets App pods accept
# connections only from edge pods, edge pods only from Traefik and
# oauth2-proxy pods, and oauth2-proxy pods only from Traefik; Cloud's Project
# policy narrows that to the App's own pods. Cloud's edge.test.ts runs the
# Caddyfile in the pinned image; M4's live cookie test checks it end to end.
#
# Network. Calico tier "cloud" (main.tf) sits before the default tier and
# holds two infra-owned GlobalNetworkPolicies for every managed namespace,
# local.cloud_project_egress_floor and local.cloud_project_ingress_floor
# below. The reconciler has no right in that tier, so a Project policy it
# writes in the default tier can only narrow access, never open the LAN,
# Vault or another namespace's Kubernetes Service, and never let Traefik reach
# App pods directly.
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
# Disk and metrics. Every container limits its ephemeral storage and every
# emptyDir has a sizeLimit, and the quota counts ephemeral storage, so a
# Project cannot fill a worker's disk and push it into DiskPressure. No
# Service or pod may carry a prometheus.io/* annotation: the homelab's
# annotation-driven scrape jobs keep the target's own labels (honor_labels),
# so a Project endpoint could otherwise write series under homelab labels.
#
# Taken hosts. A ValidatingAdmissionPolicy sees only the object in the
# request, its namespace and a parameter object; it cannot list other
# Ingresses or IngressRoutes. So taken_hosts.tf collects the homelab's hosts
# at plan time, and local.cloud_admission_policies_applied writes them into
# cloud-managed-ingress as a CEL map literal in place of
# local.cloud_taken_hosts_marker. A host added after the last cloud apply is
# missing until the next one; the reconciler checks taken hosts itself
# before it applies, with its cluster-wide read on both kinds.
#
# No policy here takes a parameter (paramKind). calico-apiserver, the
# aggregated API server for projectcalico.org, is built on k8s.io/apiserver
# and runs the ValidatingAdmissionPolicy plugin itself, over every policy in
# the cluster. A policy with paramKind makes it start a cluster-wide informer
# for that kind; calico-apiserver's service account may not list ConfigMaps,
# so the informer never synced, its readyz failed and v3.projectcalico.org
# went unavailable (found 2026-11-13 in kind with the real Calico). That
# stops every Calico policy write and leaves deleted namespaces Terminating,
# cluster-wide, and deleting the policy does not heal it: calico-apiserver
# keeps the informer until its pods restart. tests/cloud-access.test.sh runs
# on the real Calico and checks the APIService after every step.
#
# Calico NetworkPolicies are served by calico-apiserver. For the same reason
# the policies above apply to them there: cloud-reconciler-scope keeps the
# reconciler's Calico writes in managed p-* namespaces (the test checks it).
# The RoleBinding is the boundary too: the reconciler can write them only in
# a namespace where it has bound the project role, and only in the default
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
  cloud_service_label     = "cloud.viktorbarzin.me/service"
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
  # reconciler. The quota must count requests and limits of CPU, memory and
  # ephemeral storage, and pods, so no pod escapes it (quota admission then
  # refuses a pod without those limits), and must allow no PersistentVolumeClaim,
  # LoadBalancer or NodePort. Kyverno's generated tier-quota and
  # tier-defaults carry no managed-by label, so the reconciler can neither
  # change nor delete them.
  cloud_governance = {
    label          = "app.kubernetes.io/managed-by"
    value          = "cloud"
    quota_name     = "cloud-quota"
    limits_name    = "cloud-limits"
    quota_required = ["requests.cpu", "requests.memory", "requests.ephemeral-storage", "limits.cpu", "limits.memory", "limits.ephemeral-storage", "pods"]
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

  # The edge and the oauth2-proxy, as Cloud renders them (the cloud repo's
  # modules/app/edge.tf and auth.tf; names in its
  # docs/build/m2-contract-rendered.md). The images are IMAGES.edge and
  # IMAGES.oauth2Proxy in its src/reconciler/render.ts;
  # tests/cloud-access.test.sh applies Cloud's real modules, so a mismatch
  # fails the test. Change both repos together.
  cloud_workload_components = ["app", "edge", "oauth2-proxy"]

  # Anything looser would let the reconciler change what the edge strips
  # without touching its Caddyfile: a command or exec hook runs another
  # program, env and mounts can point Caddy at another config, another port
  # number lets the Service's targetPort name reach a socket Caddy does not
  # own.
  cloud_edge = {
    component    = "edge"
    container    = "edge"
    image        = "docker.io/library/caddy:2.11.9-alpine@sha256:0bbb055bda6793c999bde78b1b5ce3e89f829fb031af2cf50056ea1246559fee"
    prefix       = "edge-"
    port_name    = "edge"
    port         = 8080
    service_port = 80
    args         = ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
    env = {
      XDG_CONFIG_HOME = "/run/caddy/config"
      XDG_DATA_HOME   = "/run/caddy/data"
    }
    config_dir = "/etc/caddy"
    run_dir    = "/run/caddy"
  }

  # The shared Authentik client (stacks/authentik cloud-apps.tf, the same
  # literal there). Pinned so an oauth2-proxy pod signs in only through it.
  cloud_apps_client_id = "cloud-apps"

  # The oauth2-proxy pins its upstream to the App's own edge Service, so a
  # signed-in request never reaches App code unstripped, and fixes every
  # other flag: the issuer, the endpoints, the email allowlist file as the
  # only gate, no --skip-jwt-bearer-tokens, no --email-domain, a cookie bound
  # to the App's host. @APP@ is the pod's cloud.viktorbarzin.me/service
  # label and @NS@ its namespace, filled in by the policy; the App's host is
  # @APP@.viktorbarzin.me. Its component label is also the Calico source
  # selector that reaches the Authentik server pods, so nothing but this
  # program may carry it.
  cloud_oauth2_proxy = {
    component  = "oauth2-proxy"
    container  = "oauth2-proxy"
    image      = "quay.io/oauth2-proxy/oauth2-proxy:v7.15.6@sha256:c3415e8660af553f5e18f5d90db050614c02493c0ac6260ac59442f6d9b12048"
    prefix     = "auth-"
    port_name  = "http"
    port       = 4180
    emails_dir = "/etc/oauth2-proxy"
    args = [
      "--provider=oidc",
      "--client-id=${local.cloud_apps_client_id}",
      "--redirect-url=https://@APP@.viktorbarzin.me/oauth2/callback",
      "--oidc-issuer-url=http://goauthentik-server.authentik.svc.cluster.local/application/o/cloud-apps/",
      "--skip-oidc-discovery=true",
      "--login-url=https://authentik.viktorbarzin.me/application/o/authorize/",
      "--redeem-url=http://goauthentik-server.authentik.svc.cluster.local/application/o/token/",
      "--oidc-jwks-url=http://goauthentik-server.authentik.svc.cluster.local/application/o/cloud-apps/jwks/",
      "--profile-url=http://goauthentik-server.authentik.svc.cluster.local/application/o/userinfo/",
      "--scope=openid profile email",
      "--code-challenge-method=S256",
      "--authenticated-emails-file=/etc/oauth2-proxy/emails",
      "--insecure-oidc-allow-unverified-email=true",
      "--upstream=http://edge-@APP@.@NS@.svc.cluster.local:80/",
      "--pass-basic-auth=false",
      "--pass-user-headers=false",
      "--pass-access-token=false",
      "--whitelist-domain=@APP@.viktorbarzin.me",
      "--http-address=0.0.0.0:4180",
      "--reverse-proxy=true",
      "--cookie-name=_oauth2_proxy",
      "--cookie-domain=@APP@.viktorbarzin.me",
      "--cookie-secure=true",
      "--cookie-expire=1h",
      "--ping-path=/oauth2/ping",
      "--ready-path=/oauth2/ready",
      "--skip-provider-button=true",
      "--silence-ping-logging=true",
    ]
  }

  # The edge's Caddyfile (ConfigMap edge-<app>, key Caddyfile), line by line,
  # from the cloud repo's modules/app/Caddyfile.tftpl. The policy
  # cloud-managed-edge-config accepts only this file: optional leading
  # comment lines, then these lines in order with any indentation.
  # Placeholders:
  #   @APP@, @NS@  the App (the ConfigMap's name after edge-) and the
  #                namespace, filled in by the policy, so the only upstream is
  #                this App's own Service app-<app>
  #   @COOKIES@    the cookie alternation; cloud_strip_cookies_required must
  #                each be in it
  # The header caps (64KB both ways) are fixed: without the response cap a
  # few App responses with huge headers OOM-kill Caddy.
  cloud_caddyfile_lines = [
    "{", "admin off", "auto_https off", "persist_config off", "servers {",
    "trusted_proxies static private_ranges", "max_header_size 64KB", "}", "}",
    ":8080 {",
    "reverse_proxy app-@APP@.@NS@.svc.cluster.local:80 {",
    "transport http {", "max_response_header 64KB", "}",
    "header_up Cookie `(?:^\\s*|;\\s*)(?:@COOKIES@)=[^;]*` \"\"",
    "header_up Cookie `^;\\s*` \"\"",
    "header_up -X-Authentik-*", "header_up -X_Authentik_*",
    "header_down Set-Cookie `(?i)^.*;\\s*domain\\s*=.*$` \"\"",
    "}", "}",
  ]
  # Each line as a regex: metacharacters escaped, any indentation, a newline.
  cloud_caddyfile_line_re = join("", [
    for l in local.cloud_caddyfile_lines : "[\\t ]*${replace(l, "/[\\\\.+*?()|\\[\\]{}^$]/", "\\$0")}\\n"
  ])
  # One cookie in the alternation: a name (a dot only escaped), optionally
  # followed by [^=;]* for a prefix.
  cloud_strip_cookie_re = "(?:[A-Za-z0-9_-]|\\\\[.])+(?:\\[\\^=;\\]\\*)?"
  cloud_caddyfile_re = replace(join("", [
    "^(?:[\\t ]*(?:#[^\\n]*)?\\n)*",
    local.cloud_caddyfile_line_re,
    "(?:[\\t ]*\\n)*$",
  ]), "@COOKIES@", "${local.cloud_strip_cookie_re}(?:\\|${local.cloud_strip_cookie_re})*")
  # The homelab's cookies scoped to viktorbarzin.me, in Cloud's strip_cookies
  # form (a trailing * is a prefix): Authentik's forward-auth session, the
  # Turnstile gate and Anubis's pass (techaro.lol-anubis-auth since
  # 2026-10-15; anubis* covers older names). Cloud's list may hold more,
  # never fewer.
  cloud_strip_cookies_required = ["authentik_proxy_*", "tsgate*", "anubis*", "techaro.lol-anubis-*"]
  # The same, as each appears in the Caddyfile's alternation (a dot escaped
  # as \., a trailing * as [^=;]*), then escaped again as a regex.
  cloud_strip_cookies_required_re = [for c in local.cloud_strip_cookies_required : replace(
    endswith(c, "*") ? "${replace(trimsuffix(c, "*"), ".", "\\.")}[^=;]*" : replace(c, ".", "\\."), "/[\\\\.+*?()|\\[\\]{}^$]/", "\\$0"
  )]

  # Hosts the homelab already routes (local.cloud_taken_hosts in
  # taken_hosts.tf, from every Ingress and IngressRoute outside managed
  # namespaces). cloud-managed-ingress holds this marker where the hosts go;
  # local.cloud_admission_policies_applied below replaces it with a CEL map
  # literal, host to router. The marker alone is not valid CEL, so the API
  # server refuses a policy applied without the hosts ("compilation failed")
  # and the apply fails.
  cloud_taken_hosts_marker = "@TAKEN_HOSTS@"

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
  # address, backup-mx and the homelab's public IPv6 prefixes. Cloud's own
  # Project policy excludes the same list (EGRESS_EXCLUDED in render.ts; the
  # test compares them).
  #   176.12.22.76/32  the home WAN IP, as a destination: pfSense forwards
  #     WAN :443 to Traefik, so a pod reaching it would hairpin into Traefik.
  #     Same address as in stacks/crowdsec.
  #     This covers the destination only. Project traffic to the internet is
  #     SNATed and leaves as 176.12.22.76 too, and homelab controls trust that
  #     source: CrowdSec whitelists it (so a Project request through
  #     Cloudflare to a homelab host, which Traefik sees by Cf-Connecting-Ip,
  #     is never banned), and backup-mx admits it (next entry). Viktor
  #     decides the CrowdSec part (docs/agents/security.md, "Open risk").
  #   92.5.132.215/32  backup-mx (mx2) on OCI, docs/runbooks/backup-mx.md. Its
  #     OCI security list (stacks/backup-mx) admits the home WAN IP on 22
  #     (break-glass SSH, key only) and 9100 (node_exporter). A Project pod
  #     leaves as that address, so without this entry it would pass both
  #     source checks: it could scrape node_exporter and try SSH logins. The
  #     cost: Project pods cannot reach status.viktorbarzin.me or the backup
  #     MX on 25, which they do not need.
  #   2001:470:...     Hurricane Electric prefixes; same list as the crowdsec
  #     allowlist in stacks/crowdsec.
  cloud_egress_excluded = {
    ipv4 = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "127.0.0.0/8", "176.12.22.76/32", "92.5.132.215/32"]
    ipv6 = ["fc00::/7", "fe80::/10", "::1/128", "2001:470:5a7f::/48", "2001:470:6f:43d::/64", "2001:470:6e:43d::/64"]
  }

  # Calico tier "cloud", which holds both floors below (main.tf applies it).
  cloud_tier = {
    apiVersion = "projectcalico.org/v3"
    kind       = "Tier"
    metadata   = { name = "cloud" }
    spec = {
      # After calico-system (100), before the admin tiers (1000) and the
      # default tier (1000000).
      order         = 500
      defaultAction = "Pass"
    }
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

  # Who may connect to a Project pod (M2 contract, Addendum v2 point 8). The
  # edge is the only way to App code, so App pods accept connections only
  # from edge pods, edge pods only from Traefik and oauth2-proxy pods, and
  # oauth2-proxy pods only from Traefik. Everything else is denied here,
  # before the default tier, so a Project policy cannot let Traefik, another
  # namespace or the LAN reach App pods directly. A GlobalNetworkPolicy
  # cannot say "the same namespace", so the edge and oauth2-proxy rules pass
  # any managed namespace's pods to the default tier, where Cloud's Project
  # policy keeps each App's own. The kubelet's probes come from the node and
  # are not subject to Calico policy.
  cloud_project_ingress_floor = {
    apiVersion = "projectcalico.org/v3"
    kind       = "GlobalNetworkPolicy"
    metadata   = { name = "cloud.project-ingress-floor" }
    spec = {
      tier              = "cloud"
      order             = 110
      selector          = "all()"
      namespaceSelector = "${local.cloud_managed_label} == 'true'"
      types             = ["Ingress"]
      ingress = [
        {
          action      = "Pass"
          source      = { namespaceSelector = "projectcalico.org/name == 'traefik'" }
          destination = { selector = "${local.cloud_component_label} in {'${local.cloud_edge.component}', '${local.cloud_oauth2_proxy.component}'}" }
        },
        {
          action      = "Pass"
          source      = { namespaceSelector = "${local.cloud_managed_label} == 'true'", selector = "${local.cloud_component_label} == '${local.cloud_oauth2_proxy.component}'" }
          destination = { selector = "${local.cloud_component_label} == '${local.cloud_edge.component}'" }
        },
        {
          action      = "Pass"
          source      = { namespaceSelector = "${local.cloud_managed_label} == 'true'", selector = "${local.cloud_component_label} == '${local.cloud_edge.component}'" }
          destination = { selector = "${local.cloud_component_label} == 'app'" }
        },
        { action = "Deny" },
      ]
    }
  }

  cloud_governance_labelled = "has(%s.metadata.labels) && '${local.cloud_governance.label}' in %s.metadata.labels && %s.metadata.labels['${local.cloud_governance.label}'] == '${local.cloud_governance.value}'"
  cloud_label_is_true       = "has(%s.metadata.labels) && '${local.cloud_managed_label}' in %s.metadata.labels && %s.metadata.labels['${local.cloud_managed_label}'] == 'true'"

  # The pod rules, written once against @S (the pod spec) and used by
  # cloud-managed-pod (S = object.spec) and cloud-managed-deployment
  # (S = object.spec.template.spec), so a Deployment the reconciler writes
  # fails at apply time, not later in its ReplicaSet. Both policies define
  # the variables component, service and podAnnotations from the pod's own
  # metadata or the template's. The API server returns the message of the
  # first rule that fails, so GPU comes before priority: Kyverno's
  # inject-gpu-workload-priority gives a GPU pod priority class gpu-workload
  # before admission runs.
  #
  # @EDGE and @AUTH below stand for "this pod is not an edge pod, or" and the
  # same for oauth2-proxy; each pinned rule applies to its component only.
  cloud_pod_rules = [for r in [
    {
      expression = "variables.component in ${jsonencode(local.cloud_workload_components)}"
      message    = "in a Cloud namespace, a pod is labelled ${local.cloud_component_label} ${join(", ", local.cloud_workload_components)}"
    },
    {
      expression = "!has(@S.initContainers) || size(@S.initContainers) == 0"
      message    = "in a Cloud namespace, a pod may not have init containers"
    },
    {
      expression = "@S.containers.all(c, !has(c.resources) || ((!has(dyn(c.resources).requests) || dyn(c.resources).requests.all(k, k in ${jsonencode(local.cloud_pod_resources)})) && (!has(dyn(c.resources).limits) || dyn(c.resources).limits.all(k, k in ${jsonencode(local.cloud_pod_resources)}))))"
      message    = "in a Cloud namespace, a container may request only ${join(", ", local.cloud_pod_resources)}: no GPU or other extended resource"
    },
    {
      # The kubelet enforces the limit, the quota counts it, and a container
      # without one could fill the node's disk.
      # dyn(): the API server's type checker has no schema for
      # resources.limits or emptyDir.sizeLimit (quantities), though both
      # evaluate.
      expression = "@S.containers.all(c, has(c.resources) && has(dyn(c.resources).limits) && 'ephemeral-storage' in dyn(c.resources).limits)"
      message    = "in a Cloud namespace, every container sets an ephemeral-storage limit"
    },
    {
      expression = "!has(@S.volumes) || @S.volumes.all(v, ${join(" || ", [for t in local.cloud_pod_volume_types : "has(v.${t})"])})"
      message    = "in a Cloud namespace, a pod may use only ${join(", ", local.cloud_pod_volume_types)} volumes"
    },
    {
      expression = "!has(@S.volumes) || @S.volumes.all(v, !has(v.emptyDir) || has(dyn(v.emptyDir).sizeLimit))"
      message    = "in a Cloud namespace, every emptyDir sets a sizeLimit"
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
      expression = "!has(@S.shareProcessNamespace) || !@S.shareProcessNamespace"
      message    = "in a Cloud namespace, a pod may not share its process namespace"
    },
    {
      # The kubelet runs probes and hooks from the node's network, past the
      # Calico floor. Pod Security restricted refuses a host on a pod (1.34+);
      # this refuses it on a Deployment at apply time too.
      expression = "@S.containers.all(c, ${join(" && ", concat(
        [for pr in ["livenessProbe", "readinessProbe", "startupProbe"] : "(!has(c.${pr}) || ((!has(c.${pr}.httpGet) || !has(c.${pr}.httpGet.host) || c.${pr}.httpGet.host == '') && (!has(c.${pr}.tcpSocket) || !has(c.${pr}.tcpSocket.host) || c.${pr}.tcpSocket.host == '')))"],
        [for h in ["postStart", "preStop"] : "(!has(c.lifecycle) || !has(c.lifecycle.${h}) || ((!has(c.lifecycle.${h}.httpGet) || !has(c.lifecycle.${h}.httpGet.host) || c.lifecycle.${h}.httpGet.host == '') && (!has(c.lifecycle.${h}.tcpSocket) || !has(c.lifecycle.${h}.tcpSocket.host) || c.lifecycle.${h}.tcpSocket.host == '')))"],
      ))})"
      message = "in a Cloud namespace, a probe or lifecycle hook may not name a host"
    },
    {
      expression = "variables.podAnnotations.all(k, !k.startsWith('prometheus.io/'))"
      message    = "in a Cloud namespace, a pod may not carry prometheus.io/* annotations"
    },
    # The edge (local.cloud_edge).
    {
      expression = "@EDGE (size(@S.containers) == 1 && @S.containers[0].name == '${local.cloud_edge.container}' && @S.containers[0].image == '${local.cloud_edge.image}')"
      message    = "in a Cloud namespace, an edge pod has one container, ${local.cloud_edge.container}, running ${local.cloud_edge.image}"
    },
    {
      expression = "@EDGE @S.containers.all(c, !has(c.command) && has(c.args) && c.args == ${jsonencode(local.cloud_edge.args)} && !has(c.envFrom) && has(c.env) && size(c.env) == ${length(local.cloud_edge.env)} && c.env.all(e, e.name in ${jsonencode(local.cloud_edge.env)} && has(e.value) && !has(e.valueFrom) && e.value == ${jsonencode(local.cloud_edge.env)}[e.name]) && !has(c.lifecycle) && !has(c.livenessProbe) && !has(c.startupProbe))"
      message    = "in a Cloud namespace, the edge runs as Cloud renders it: args ${join(" ", local.cloud_edge.args)}, env only ${join(" and ", keys(local.cloud_edge.env))}, and no command, envFrom, lifecycle hook, liveness or startup probe"
    },
    {
      expression = "@EDGE @S.containers.all(c, has(c.ports) && size(c.ports) == 1 && c.ports.all(p, has(p.name) && p.name == '${local.cloud_edge.port_name}' && p.containerPort == ${local.cloud_edge.port} && (!has(p.protocol) || p.protocol == 'TCP') && !has(p.hostPort) && !has(p.hostIP)))"
      message    = "in a Cloud namespace, the edge has one port, ${local.cloud_edge.port_name} = ${local.cloud_edge.port}/TCP, and no host port"
    },
    {
      # Only an edge that listens gets traffic. The probe checks the edge's
      # own port, which no App code can bind: it runs in another pod.
      expression = "@EDGE @S.containers.all(c, has(c.readinessProbe) && has(c.readinessProbe.tcpSocket) && string(c.readinessProbe.tcpSocket.port) in ['${local.cloud_edge.port_name}', '${local.cloud_edge.port}'])"
      message    = "in a Cloud namespace, the edge has a tcpSocket readiness probe on port ${local.cloud_edge.port_name}"
    },
    {
      expression = "@EDGE @S.containers.all(c, has(c.volumeMounts) && size(c.volumeMounts) == 2 && c.volumeMounts.exists(m, m.mountPath == '${local.cloud_edge.config_dir}') && c.volumeMounts.exists(m, m.mountPath == '${local.cloud_edge.run_dir}') && c.volumeMounts.all(m, (!has(m.subPath) || m.subPath == '') && (!has(m.subPathExpr) || m.subPathExpr == '') && has(@S.volumes) && ((m.mountPath == '${local.cloud_edge.config_dir}' && has(m.readOnly) && m.readOnly && @S.volumes.exists(v, v.name == m.name && has(v.configMap) && has(v.configMap.name) && v.configMap.name == '${local.cloud_edge.prefix}' + variables.service && !has(v.configMap.items))) || (m.mountPath == '${local.cloud_edge.run_dir}' && @S.volumes.exists(v, v.name == m.name && has(v.emptyDir))))))"
      message    = "in a Cloud namespace, the edge mounts only ConfigMap ${local.cloud_edge.prefix}<its App>, read-only and whole, at ${local.cloud_edge.config_dir}, and an emptyDir at ${local.cloud_edge.run_dir}"
    },
    # The oauth2-proxy (local.cloud_oauth2_proxy).
    {
      expression = "@AUTH (size(@S.containers) == 1 && @S.containers[0].name == '${local.cloud_oauth2_proxy.container}' && @S.containers[0].image == '${local.cloud_oauth2_proxy.image}')"
      message    = "in a Cloud namespace, an oauth2-proxy pod has one container, ${local.cloud_oauth2_proxy.container}, running ${local.cloud_oauth2_proxy.image}"
    },
    {
      expression = "@AUTH @S.containers.all(c, !has(c.command) && has(c.args) && c.args == ${jsonencode(local.cloud_oauth2_proxy.args)}.map(a, a.replace('@APP@', variables.service).replace('@NS@', request.namespace)) && !has(c.env) && has(c.envFrom) && size(c.envFrom) == 1 && c.envFrom.all(e, has(e.secretRef) && e.secretRef.name == '${local.cloud_oauth2_proxy.prefix}' + variables.service && !has(e.configMapRef) && (!has(e.prefix) || e.prefix == '')) && !has(c.lifecycle) && ${join(" && ", [for pr in ["livenessProbe", "readinessProbe", "startupProbe"] : "(!has(c.${pr}) || !has(c.${pr}.exec))"])})"
      message    = "in a Cloud namespace, the oauth2-proxy runs as Cloud renders it: the fixed args with its own App's host and edge, Secret ${local.cloud_oauth2_proxy.prefix}<its App> as its only env, and no command, lifecycle hook or exec probe"
    },
    {
      expression = "@AUTH @S.containers.all(c, has(c.ports) && size(c.ports) == 1 && c.ports.all(p, has(p.name) && p.name == '${local.cloud_oauth2_proxy.port_name}' && p.containerPort == ${local.cloud_oauth2_proxy.port} && !has(p.hostPort) && !has(p.hostIP)))"
      message    = "in a Cloud namespace, the oauth2-proxy has one port, ${local.cloud_oauth2_proxy.port_name} = ${local.cloud_oauth2_proxy.port}, and no host port"
    },
    {
      expression = "@AUTH @S.containers.all(c, has(c.volumeMounts) && size(c.volumeMounts) == 1 && c.volumeMounts.all(m, m.mountPath == '${local.cloud_oauth2_proxy.emails_dir}' && has(m.readOnly) && m.readOnly && (!has(m.subPath) || m.subPath == '') && (!has(m.subPathExpr) || m.subPathExpr == '') && has(@S.volumes) && @S.volumes.exists(v, v.name == m.name && has(v.configMap) && has(v.configMap.name) && v.configMap.name == '${local.cloud_oauth2_proxy.prefix}' + variables.service)))"
      message    = "in a Cloud namespace, the oauth2-proxy mounts only ConfigMap ${local.cloud_oauth2_proxy.prefix}<its App>, read-only, at ${local.cloud_oauth2_proxy.emails_dir}"
    },
    ] : {
    expression = replace(replace(r.expression, "@EDGE ", "variables.component != '${local.cloud_edge.component}' || "), "@AUTH ", "variables.component != '${local.cloud_oauth2_proxy.component}' || ")
    message    = r.message
  }]

  # The variables cloud_pod_rules use, from the pod's metadata (@M).
  cloud_pod_variables = [
    { name = "podLabels", expression = "has(@M.labels) ? @M.labels : {}" },
    { name = "podAnnotations", expression = "has(@M.annotations) ? @M.annotations : {}" },
    { name = "component", expression = "'${local.cloud_component_label}' in variables.podLabels ? variables.podLabels['${local.cloud_component_label}'] : ''" },
    { name = "service", expression = "'${local.cloud_service_label}' in variables.podLabels ? variables.podLabels['${local.cloud_service_label}'] : ''" },
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
        variables = [
          { name = "anns", expression = "has(object.metadata.annotations) ? object.metadata.annotations : {}" },
          { name = "selector", expression = "has(object.spec.selector) ? object.spec.selector : {}" },
        ]
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
            expression = "variables.anns.all(k, !k.startsWith('prometheus.io/'))"
            message    = "in a Cloud namespace, a Kubernetes Service may not carry prometheus.io/* annotations"
            reason     = "Forbidden"
          },
          {
            # Traefik reaches the edge through this Service, so it must select
            # only the edge pods of the App it is named after.
            expression = "!object.metadata.name.startsWith('${local.cloud_edge.prefix}') || ('${local.cloud_component_label}' in variables.selector && variables.selector['${local.cloud_component_label}'] == '${local.cloud_edge.component}' && '${local.cloud_service_label}' in variables.selector && variables.selector['${local.cloud_service_label}'] == object.metadata.name.substring(${length(local.cloud_edge.prefix)}) && has(object.spec.ports) && size(object.spec.ports) == 1 && object.spec.ports.all(p, has(p.name) && p.name == '${local.cloud_edge.port_name}' && has(p.targetPort) && string(p.targetPort) == '${local.cloud_edge.port_name}'))"
            message    = "in a Cloud namespace, a Kubernetes Service ${local.cloud_edge.prefix}<app> selects ${local.cloud_component_label}=${local.cloud_edge.component} and ${local.cloud_service_label}=<app>, with one port ${local.cloud_edge.port_name} targeting the container port ${local.cloud_edge.port_name}"
            reason     = "Forbidden"
          },
          {
            expression = "!object.metadata.name.startsWith('${local.cloud_oauth2_proxy.prefix}') || ('${local.cloud_component_label}' in variables.selector && variables.selector['${local.cloud_component_label}'] == '${local.cloud_oauth2_proxy.component}' && '${local.cloud_service_label}' in variables.selector && variables.selector['${local.cloud_service_label}'] == object.metadata.name.substring(${length(local.cloud_oauth2_proxy.prefix)}) && has(object.spec.ports) && size(object.spec.ports) == 1 && object.spec.ports.all(p, has(p.name) && p.name == '${local.cloud_oauth2_proxy.port_name}' && has(p.targetPort) && string(p.targetPort) == '${local.cloud_oauth2_proxy.port_name}'))"
            message    = "in a Cloud namespace, a Kubernetes Service ${local.cloud_oauth2_proxy.prefix}<app> selects ${local.cloud_component_label}=${local.cloud_oauth2_proxy.component} and ${local.cloud_service_label}=<app>, with one port ${local.cloud_oauth2_proxy.port_name} targeting the container port ${local.cloud_oauth2_proxy.port_name}"
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
          # Host -> router, filled in by cloud_admission_policies_applied.
          { name = "takenHosts", expression = local.cloud_taken_hosts_marker },
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
            expression = "(!has(object.spec.rules) || object.spec.rules.all(r, !has(r.host) || !(r.host in variables.takenHosts))) && (!has(object.spec.tls) || object.spec.tls.all(t, !has(t.hosts) || t.hosts.all(h, !(h in variables.takenHosts))))"
            message    = "in a Cloud namespace, an Ingress may not use a host the homelab already routes (stacks/cloud taken_hosts.tf)"
            reason     = "Forbidden"
          },
          {
            # The way in is the edge (public App) or the App's oauth2-proxy,
            # whose only upstream is the edge (private App); never App pods.
            expression = "!has(object.spec.rules) || object.spec.rules.all(r, !has(r.http) || r.http.paths.all(p, has(p.backend.service) && has(p.backend.service.port) && has(p.backend.service.port.name) && !has(p.backend.service.port.number) && ((p.backend.service.name.startsWith('${local.cloud_edge.prefix}') && p.backend.service.port.name == '${local.cloud_edge.port_name}') || (p.backend.service.name.startsWith('${local.cloud_oauth2_proxy.prefix}') && p.backend.service.port.name == '${local.cloud_oauth2_proxy.port_name}'))))"
            message    = "in a Cloud namespace, every Ingress backend is an edge Service (${local.cloud_edge.prefix}<app>, port ${local.cloud_edge.port_name}) or an oauth2-proxy Service (${local.cloud_oauth2_proxy.prefix}<app>, port ${local.cloud_oauth2_proxy.port_name}), named by port name"
            reason     = "Forbidden"
          },
        ]
      }
    }
    managed_ingress_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-ingress" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-ingress" })
    }
    managed_edge_config = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-edge-config" }
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
          name       = "is-edge-config"
          expression = "object.metadata.name.startsWith('${local.cloud_edge.prefix}')"
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
            message    = "in a Cloud namespace, a ${local.cloud_edge.prefix}* ConfigMap holds only the key Caddyfile"
            reason     = "Forbidden"
          },
          {
            expression = "size(variables.caddyfile) <= 8192 && variables.caddyfile.matches(r'${local.cloud_caddyfile_re}'.replace('@APP@', object.metadata.name.substring(${length(local.cloud_edge.prefix)})).replace('@NS@', request.namespace))"
            message    = "in a Cloud namespace, an ${local.cloud_edge.prefix}<app> Caddyfile is the one Cloud renders (modules/app/Caddyfile.tftpl), with only the strip list filled in and app-<app> in this namespace as its upstream"
            reason     = "Forbidden"
          },
          {
            expression = "${join(" && ", [for c in local.cloud_strip_cookies_required_re : "variables.cookieLine.matches(r'[:|]${c}[|)]')"])}"
            message    = "in a Cloud namespace, an ${local.cloud_edge.prefix}<app> Caddyfile strips at least ${join(", ", local.cloud_strip_cookies_required)}"
            reason     = "Forbidden"
          },
        ]
      }
    }
    managed_edge_config_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-edge-config" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-edge-config" })
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
        variables = [for v in local.cloud_pod_variables : { name = v.name, expression = replace(v.expression, "@M", "object.metadata") }]
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
        variables = [for v in local.cloud_pod_variables : { name = v.name, expression = replace(v.expression, "@M", "object.spec.template.metadata") }]
        validations = [for r in local.cloud_pod_rules : {
          expression = replace(r.expression, "@S", "object.spec.template.spec")
          message    = r.message
          reason     = "Forbidden"
        }]
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

  # What main.tf applies: the policies above with the taken hosts written
  # into cloud-managed-ingress. jsonencode twice and trim, so the CEL map
  # literal lands JSON-escaped inside the JSON string that held the marker.
  cloud_admission_policies_applied = {
    for k, p in local.cloud_admission_policies : k => jsondecode(replace(
      jsonencode(p),
      local.cloud_taken_hosts_marker,
      trim(jsonencode(jsonencode(local.cloud_taken_hosts)), "\""),
    ))
  }
}
