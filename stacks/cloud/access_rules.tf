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
# role and the console's exec role (B22) and nothing else, and read on Ingresses and IngressRoutes (to find hosts
# already taken). Everything a Project contains is in the project role, which
# the reconciler binds to itself with a RoleBinding inside each Project
# namespace it creates. RBAC lets it bind that role and the console's exec
# role and no other: `bind` is limited to those names, and it holds none of
# the rights of admin or edit.
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
#     externalIPs and no prometheus.io/* annotation. Its only traefik.*
#     annotation is service.serverstransport naming Cloud's ServersTransport
#     cloud/app-edge, on an edge Service only. An edge Service (edge-*)
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
#     policy itself, see "Taken hosts" below); every backend is an edge
#     Service on port edge, by port name. No tls.secretName: Traefik's
#     default TLSStore serves the wildcard, and a Project certificate would
#     go into Traefik's global store, where an exact SAN match beats the
#     wildcard for every host. The
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
#     or IPC, shared process namespace, service account other than default,
#     priority class other than tier-4-aux, or prometheus.io/* annotation;
#     sets topologySpreadConstraints only on an App pod, and then exactly
#     one soft spread over its own App's pods on kubernetes.io/hostname;
#     requests no GPU or other extended resource; and limits the ephemeral
#     storage of every container, init containers included. Only an App pod
#     may have an init container: at most one, named migrate, with no
#     restartPolicy (no sidecar) and the image of the pod's first container
#     (Cloud's migrations, app-kit K3). Every pod is labelled
#     cloud.viktorbarzin.me/component app, edge, oauth2-proxy, worker, cron,
#     migrate, job or toolbox. An edge pod
#     runs exactly the edge Cloud renders and an oauth2-proxy pod exactly the
#     oauth2-proxy Cloud renders (local.cloud_edge, local.cloud_oauth2_proxy):
#     one container, the pinned image, fixed args and env, no command, hook or
#     exec probe, fixed ports and mounts, and for the edge its readiness
#     probe. App, worker and cron pods are free, within the rules above.
#     Only an App or a worker Deployment may run 0 replicas (a suspended
#     App, a stopped worker), and no Deployment more than 3 (an App's
#     `instances`, the cloud repo's B21). A worker Service is Deployment worker-<name>,
#     component worker (B18). A migrate pod (B16)
#     has one container migrate, an image by digest, no command, 1 to 8
#     args, restartPolicy Never, no port, probe or hook, and is made only by
#     a Job; no Deployment runs one. A one-off job pod (B20) has one
#     container job, an image by digest, a command of 1 to 64 items of at
#     most 4096 characters and no args, restartPolicy Never, no port, probe
#     or hook, and is made only by a Job; no Deployment runs one. A psql
#     toolbox pod (B22) has one container toolbox running the pinned
#     toolbox image with the command sleep <seconds>, no args, port, probe,
#     hook or envFrom, env only plain values and keys of Secret
#     pg-<its Service>, no service account token, only emptyDir volumes, a
#     read-only root, no privilege escalation and every capability
#     dropped, restartPolicy Never, and is made only by a Job; no
#     Deployment runs one.
#   cloud-managed-job  a Job's pod template passes the pod rules above; it
#     runs one pod once (backoffLimit 0) with restartPolicy Never, a
#     deadline up to 12 h and a TTL up to a day. It is a Deploy's migrations
#     (component migrate, named app-<App>-m<9 hex>, no owner, labelled
#     like its pod; the reconciler's). A Job whose pod is component cron
#     (B19's cron run) is left to cloud-managed-cron-job, and one whose pod
#     is component job to cloud-managed-one-off-job, and one whose pod is
#     component toolbox to cloud-managed-toolbox-job.
#   cloud-managed-cronjob  a CronJob (a cron Service, cron-<name>, B19)
#     meets every rule of cloud-managed-pod in its Job template's pod, and
#     that pod is component cron with no init container and restartPolicy
#     Never or OnFailure; its Job sets activeDeadlineSeconds of at most
#     43200 (12 hours).
#   cloud-managed-cron-job  a Job whose pod is component cron: the same
#     rules on its pod and deadline, exactly one ownerReference, to CronJob
#     cron-<its service>, and the name cron-<service>-<digits> (the CronJob
#     controller's) or cron-<service>-m<digits> (a manual run the reconciler
#     creates).
#   cloud-managed-one-off-job  a one-off job (B20, `cloud run`): a Job whose
#     pod is component job passes the pod rules above and runs one pod once
#     (backoffLimit 0, restartPolicy Never), with a deadline up to 4260 s
#     and a TTL up to a day. It is named job-<App>-<9 hex>, is labelled
#     like its pod and has no owner: the reconciler's.
#   cloud-managed-toolbox-job  a psql toolbox (B22, `cloud psql`): a Job
#     whose pod is component toolbox passes the pod rules above and runs
#     one pod once, with a deadline up to 3780 s and a TTL up to an hour.
#     It carries its pod's Cloud labels, a session id and a target whose
#     image it runs, is named toolbox-<the session id's first 9 hex> and
#     has no owner: the reconciler's.
#   cloud-console-exec  for the console's service account only, in every
#     namespace: a CONNECT may only be an exec (no attach, no port
#     forward), only in a namespace named p-* labelled managed, and only sh
#     in container app or psql in container toolbox (B22). RBAC gives the
#     console exec only through Cloud's RoleBinding cloud-console-exec in
#     each Project namespace.
#   cloud-managed-pdb  a PodDisruptionBudget is named app-<its App> (one
#     per App), keeps exactly one App pod (minAvailable 1, no
#     maxUnavailable) of the App its matchLabels name, selects
#     component=app pods by labels only, and lets an unready pod be evicted
#     (unhealthyPodEvictionPolicy AlwaysAllow). Cloud renders one for an App
#     with 2 or more instances, so a node drain keeps one serving. No PDB
#     holds an edge or oauth2-proxy pod. A drain still waits on an App's
#     last ready pod while its other instances are not ready (Pending,
#     starting); the drain script's rollout restart of the App (the cloud
#     repo's B10) starts a replacement on another node, which ends that
#     wait once it is ready.
#   cloud-managed-edge-config  a ConfigMap named edge-* holds only the key
#     Caddyfile, and that file is one Cloud renders (local
#     cloud_caddyfile_variants: public and private): only the cookie list
#     is free, the upstreams are the App's own Services, and the list strips
#     at least the homelab's cookies. Or it is the fixed page of a suspended
#     App or an App in maintenance (cloud_caddyfile_page): every request
#     answers 503 with that page, and nothing is proxied.
#   cloud-managed-secretstore  a SecretStore is the in-cluster Vault, KV v2 at
#     secret/, Kubernetes auth role cloud-project as service account
#     cloud-secrets, and nothing else. Any other provider would let the ESO
#     controller fetch a URL or a secret store of the reconciler's choosing
#     and write the answer into a Project Secret.
#
# The edge chain (M2 contract, Addendum v2 point 8; identity at the edge,
# app-kit K1 in the cloud repo's docs/plans/2026-11-14-cloud-app-kit.md). The
# homelab's forward-auth cookies (authentik_proxy_*, tsgate, Anubis's
# techaro.lol-anubis-auth) are scoped to viktorbarzin.me, so every Project
# host receives them. Cloud's edge, a pinned Caddy in its own Deployment
# edge-<app>, removes them and every forged identity header before a request
# reaches the App, asks the App's oauth2-proxy who is signed in, passes that
# on as X-Cloud-User-* with the App's edge secret (Secret edge-<app>), and
# removes every Set-Cookie with a Domain attribute on the way back. The
# policies above make it the only way in:
#   every App: Traefik -> Service edge-<app>:edge -> edge pod -> App, and the
#              edge asks Service auth-<app>:80 (oauth2-proxy, upstream
#              static://202) at /oauth2/auth and sends it /oauth2/*
# Traefik reaches a Project only through an Ingress; the Ingress names only
# an edge-* Service; that Service selects only edge pods, and auth-* only
# oauth2-proxy pods; and those pods run only Cloud's pinned images, args and
# config. No App code runs in an edge or oauth2-proxy pod, so App code can
# never own the edge's socket. The Calico floor below lets App pods accept
# connections only from edge pods, edge pods only from Traefik, and
# oauth2-proxy pods only from edge pods on 4180; Cloud's Project policy
# narrows that to the App's own pods. An internal App has no edge, no
# oauth2-proxy and no Ingress, so nothing outside the cluster reaches it:
# the floor also passes App pods to an internal App's pods (label
# cloud.viktorbarzin.me/access=internal) on the App port
# (local.cloud_app_port), and Cloud's Project policy admits there only the
# App pods of its own namespace whose App lists the internal App in
# connects. Cloud's edge.test.ts runs the
# Caddyfile in the pinned image against a stand-in oauth2-proxy; M4's live
# cookie test checks it end to end.
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
# missing until the next one. Kyverno ValidatingPolicy
# cloud-ingress-live-hosts (local.cloud_live_host_guard below) covers that
# gap with a live lookup at admission time, and the reconciler checks taken
# hosts itself before it applies.
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
  cloud_reconciler_user   = "system:serviceaccount:${local.cloud_namespace}:${local.cloud_reconciler_sa}"
  cloud_project_role_name = "cloud-reconciler-project"

  cloud_base_domain_re = "viktorbarzin[.]me"

  cloud_write_verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  # The most replicas any Deployment in a Project runs: an App's
  # `instances` cap (the cloud repo's MAX_INSTANCES in project-file.ts).
  cloud_max_replicas = 3

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
  # A worker Service's pods are component worker and a cron Service's pods
  # component cron (the cloud repo's B18 and B19): App code like an App pod,
  # with no init container, no edge and no way in (the ingress floor below
  # admits no connection to them).
  cloud_workload_components = ["app", "edge", "oauth2-proxy", "worker", "cron", "migrate", "job", "toolbox"]

  # A Deploy's migrations (backlog B16): a Job the reconciler starts once per
  # Deploy, before the rollout, from the App's own pod (the cloud repo's
  # src/reconciler/migrate-job.ts). Its pod is labelled component migrate,
  # so the App's Kubernetes Service, which selects component app, never
  # sends it a request.
  cloud_migrate = {
    component = "migrate"
    container = "migrate"
    # app-<App>-m<the first 9 hex digits of the Deploy id>: its pod is
    # app-<App>-m<9>-<5>, which Cloud's log query reads as the App's.
    name_re  = "^app-[a-z][a-z0-9-]*-m[0-9a-f]{9}$"
    max_args = 8
    max_arg  = 200
  }
  # A one-off job (backlog B20, `cloud run`): a Job the reconciler starts
  # when a User asks, from the App's own pod with the User's command as the
  # container's command (the cloud repo's src/reconciler/job-runs.ts). Its
  # pod is labelled component job, so no Kubernetes Service selects it.
  cloud_one_off_job = {
    component = "job"
    container = "job"
    # job-<App>-<the first 9 hex digits of the run id>.
    name_re     = "^job-[a-z][a-z0-9-]*-[0-9a-f]{9}$"
    max_command = 64
    max_arg     = 4096
    # Cloud's JOB_ACTIVE_DEADLINE_SECONDS: 10 min to start, 1 h to run and
    # a minute. tests/cloud-access.test.sh sends the Job Cloud's own code
    # builds, so a change on either side fails the test.
    max_deadline_seconds = 4260
  }
  # A Postgres task (the cloud repo's B28b and B28c: `cloud pg backups`,
  # `backup`, `export`, `restore`): a Job the reconciler starts in its own
  # namespace `cloud`, never in a Project's, from the cloud repo's
  # src/reconciler/pg-task-jobs.ts. Its pod mounts only Cloud's two dump
  # directories (pg_backups.tf): the nightly `p_*` dumps read-only, and
  # the manual ones, which only a backup Job writes. The image is pinned
  # here alone and fed to the reconciler as PG_TASK_IMAGE (deploy_rules.tf),
  # so a Renovate bump moves the Jobs and the policy together;
  # tests/cloud-access.test.sh sends the Jobs Cloud's own code builds.
  cloud_pg_task = {
    container = "pg"
    image     = "docker.io/library/postgres:18.7-trixie@sha256:e754b839f447639b7004895f4d8a4bfcb4e9dbe3a1bc035f27f646562a16fd61"
    # The image's postgres user, who owns the manual dump directory
    # (stacks/dbaas postgresql-backup makes it).
    uid = 999
    # pg-<kind>-<the first 9 hex digits of the task id>, and its Secret
    # pg-task-<the same 9>.
    kinds          = ["backups", "backup", "export", "restore"]
    name_re        = "^pg-(backups|backup|export|restore)-[0-9a-f]{9}$"
    secret_re      = "^pg-task-[0-9a-f]{9}$"
    nightly_claim  = "cloud-pg-backups-nightly"
    manual_claim   = "cloud-pg-backups-manual"
    export_port    = 8080
    task_label     = "cloud.viktorbarzin.me/postgres-task"
    secret_keys    = ["PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD", "CLOUD_EXPORT_TOKEN"]
    max_deadline   = 4200
    max_ttl        = 3600
    max_command    = 6
    max_script_len = 8000
  }
  cloud_one_off_job_component_is = "has(object.spec.template.metadata.labels) && '${local.cloud_component_label}' in object.spec.template.metadata.labels && object.spec.template.metadata.labels['${local.cloud_component_label}'] == '${local.cloud_one_off_job.component}'"

  # A psql toolbox (the cloud repo's B22, `cloud psql`): a Job the
  # reconciler starts for one session (src/reconciler/toolbox.ts
  # toolboxJob). Its pod only sleeps; the console runs psql in it through
  # pods/exec. It holds the session's Postgres role from that Postgres's
  # own Secret pg-<name>, has no Kubernetes token, a read-only root and
  # only /tmp, and reaches only DNS and the CNPG primary (the egress floor).
  # The image is the one Cloud runs (the cloud repo's TOOLBOX_IMAGES), fed
  # to the reconciler as TOOLBOX_POSTGRES_IMAGE from here (deploy_rules.tf),
  # so a Renovate bump moves both. Key Value (Batch 4) adds an image.
  cloud_toolbox = {
    component = "toolbox"
    container = "toolbox"
    # toolbox-<the first 9 hex digits of the session id>.
    name_re       = "^toolbox-[0-9a-f]{9}$"
    session_label = "cloud.viktorbarzin.me/session"
    target_label  = "cloud.viktorbarzin.me/target"
    # The Postgres Secret modules/postgres writes, pg-<its name>.
    secret_prefix = "pg-"
    images = {
      postgres = "docker.io/library/postgres:18-alpine@sha256:b6972e1115a4ff8eba5d7f7d19184926d1e16d7d1136ae1e1a7ebf286da0f015"
    }
    # Cloud's TOOLBOX_DEADLINE_SECONDS: 2 min to start, the 1 h session
    # cap and a minute.
    max_deadline_seconds = 3780
  }
  cloud_toolbox_component_is = "has(object.spec.template.metadata.labels) && '${local.cloud_component_label}' in object.spec.template.metadata.labels && object.spec.template.metadata.labels['${local.cloud_component_label}'] == '${local.cloud_toolbox.component}'"

  # Shell and psql sessions (the cloud repo's B22, Viktor's decision V4):
  # the console runs them through pods/exec as its own service account.
  # This ClusterRole is not bound here. Cloud's modules/project binds it to
  # the console in each Project namespace with RoleBinding
  # cloud-console-exec, which the reconciler may create (`bind` on this
  # role only) and cloud-reconciler-scope pins. list: the console picks a
  # ready App pod by its labels; get on pods/exec: see the rule.
  # cloud-console-exec (the admission policy) then allows exec only into
  # the app container with sh or the toolbox container with psql, in
  # managed p-* namespaces. Rollback: remove this role; sessions stop and
  # nothing else changes.
  cloud_console_exec = {
    role            = "cloud-console-exec"
    service_account = "cloud-console"
    user            = "system:serviceaccount:${local.cloud_namespace}:cloud-console"
    rules = [
      { api_groups = [""], resources = ["pods"], verbs = ["get", "list"], resource_names = [] },
      # Both verbs: Kubernetes authorizes a WebSocket exec (the console's
      # v5.channel.k8s.io client) as get on pods/exec, then checks create
      # too. With either alone the upgrade is refused. kubectl falls back to
      # SPDY, which needs create only, so `kubectl exec` passing proves less.
      { api_groups = [""], resources = ["pods/exec"], verbs = ["get", "create"], resource_names = [] },
    ]
  }

  # Every Cloud Job runs once: no retry, a deadline, and a TTL so it does
  # not pile up. B19's cron runs need the 12 h deadline and a day of TTL.
  cloud_job_max_deadline_seconds = 43200
  cloud_job_max_ttl_seconds      = 86400

  # The port App containers listen on: the cloud repo's APP_PORT, 3000 by
  # default (appPort in its src/app.config.ts). An internal App (access:
  # internal) has no edge; the Apps of its Project that connect to it call
  # its pods on this port, and the ingress floor passes App to App on this
  # port only. tests/cloud-access.test.sh compares it with Cloud's.
  cloud_app_port = 3000
  # The pod label that marks an internal App's pods (the cloud repo's
  # modules/app, app_pod_labels).
  cloud_access_label = "cloud.viktorbarzin.me/access"

  # Anything looser would let the reconciler change what the edge strips
  # without touching its Caddyfile: a command or exec hook runs another
  # program, env and mounts can point Caddy at another config, another port
  # number lets the Service's targetPort name reach a socket Caddy does not
  # own.
  cloud_edge = {
    component    = "edge"
    container    = "edge"
    image        = "docker.io/library/caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0"
    prefix       = "edge-"
    port_name    = "edge"
    port         = 8080
    service_port = 80
    args         = ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
    env = {
      XDG_CONFIG_HOME = "/run/caddy/config"
      XDG_DATA_HOME   = "/run/caddy/data"
    }
    # The one env value from a Secret: the App's edge secret, which the
    # Caddyfile adds to every request it passes to the App. Secret
    # edge-<app>, key secret (the cloud repo's modules/app/edge.tf).
    secret_env = "CLOUD_EDGE_SECRET"
    secret_key = "secret"
    config_dir = "/etc/caddy"
    run_dir    = "/run/caddy"
  }

  # The Traefik ServersTransport every edge Service names (main.tf; the
  # cloud repo's EDGE_SERVERS_TRANSPORT and modules/app edge.tf). Without
  # it Traefik uses its global responseHeaderTimeout of 30 s (stacks/traefik)
  # and answers 504 to an App request whose headers take longer. 125 s is
  # the request timeout `cloud help limits` states, Cloudflare's Proxy Read
  # Timeout (Render-parity P08, 2026-11-17). The dial and idle times and
  # the idle connection pool are the global transport's
  # (--serversTransport.* in stacks/traefik): a CRD ServersTransport without
  # them gets Traefik's defaults instead, 2 idle connections per host among
  # them. tests/cloud-access.test.sh compares them.
  cloud_edge_transport = {
    name                    = "app-edge"
    annotation              = "traefik.ingress.kubernetes.io/service.serverstransport"
    ref                     = "${local.cloud_namespace}-app-edge@kubernetescrd"
    dial_timeout            = "60s"
    response_header_timeout = "125s"
    idle_conn_timeout       = "90s"
    max_idle_conns_per_host = 100
  }
  # The object main.tf applies.
  cloud_edge_transport_manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "ServersTransport"
    metadata = {
      name      = local.cloud_edge_transport.name
      namespace = local.cloud_namespace
    }
    spec = {
      maxIdleConnsPerHost = local.cloud_edge_transport.max_idle_conns_per_host
      forwardingTimeouts = {
        dialTimeout           = local.cloud_edge_transport.dial_timeout
        responseHeaderTimeout = local.cloud_edge_transport.response_header_timeout
        idleConnTimeout       = local.cloud_edge_transport.idle_conn_timeout
      }
    }
  }

  # The shared Authentik client (stacks/authentik cloud-apps.tf, the same
  # literal there). Pinned so an oauth2-proxy pod signs in only through it.
  cloud_apps_client_id = "cloud-apps"

  # The oauth2-proxy, as Cloud renders it for every App (app-kit K1): it
  # proxies nothing (upstream static://202) and answers the edge's
  # /oauth2/auth question with X-Auth-Request-* headers (--set-xauthrequest),
  # with a 12-hour host-only session cookie: the __Host- prefix and no
  # --cookie-domain, so browsers refuse the cookie when script on a sibling
  # host sets it for viktorbarzin.me, and no App can plant a session in
  # another (a public App admits any account, so anyone holds one). Every flag is
  # fixed: the issuer, the endpoints, no --skip-jwt-bearer-tokens. The one
  # flag that differs is the gate: a private App's email allowlist file
  # (args_private, with its ConfigMap mounted) or a public App's
  # --email-domain=* (args_public, with no mount and no volume), never both.
  # @APP@ is the pod's cloud.viktorbarzin.me/service label, filled in by the
  # policy; the App's host is @APP@.viktorbarzin.me. Its
  # component label is also the Calico source selector that reaches the
  # Authentik server pods, so nothing but this program may carry it.
  cloud_oauth2_proxy_head = [
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
  ]
  cloud_oauth2_proxy_emails_file = "--authenticated-emails-file=/etc/oauth2-proxy/emails"
  cloud_oauth2_proxy_any_email   = "--email-domain=*"
  cloud_oauth2_proxy_tail = [
    "--insecure-oidc-allow-unverified-email=true",
    "--upstream=static://202",
    "--pass-basic-auth=false",
    "--pass-user-headers=false",
    "--pass-access-token=false",
    "--set-xauthrequest=true",
    "--whitelist-domain=@APP@.viktorbarzin.me",
    "--http-address=0.0.0.0:4180",
    "--reverse-proxy=true",
    "--cookie-name=__Host-oauth2_proxy",
    "--cookie-secure=true",
    "--cookie-expire=12h",
    "--ping-path=/oauth2/ping",
    "--ready-path=/oauth2/ready",
    "--skip-provider-button=true",
    "--silence-ping-logging=true",
  ]
  cloud_oauth2_proxy = {
    component    = "oauth2-proxy"
    container    = "oauth2-proxy"
    image        = "quay.io/oauth2-proxy/oauth2-proxy:v7.15.6@sha256:c3415e8660af553f5e18f5d90db050614c02493c0ac6260ac59442f6d9b12048"
    prefix       = "auth-"
    port_name    = "http"
    port         = 4180
    emails_dir   = "/etc/oauth2-proxy"
    args_private = concat(local.cloud_oauth2_proxy_head, [local.cloud_oauth2_proxy_emails_file], local.cloud_oauth2_proxy_tail)
    args_public  = concat(local.cloud_oauth2_proxy_head, [local.cloud_oauth2_proxy_any_email], local.cloud_oauth2_proxy_tail)
  }

  # The edge's Caddyfile (ConfigMap edge-<app>, key Caddyfile), line by line,
  # from the cloud repo's modules/app/Caddyfile.tftpl. The policy
  # cloud-managed-edge-config accepts only these files: optional leading
  # comment lines, then one of the line lists in order with any indentation.
  # Placeholders:
  #   @APP@, @NS@  the App (the ConfigMap's name after edge-) and the
  #                namespace, filled in by the policy, so the only upstreams
  #                are this App's own Services app-<app> and auth-<app>
  #   @COOKIES@    the cookie alternation; cloud_strip_cookies_required must
  #                each be in it
  # The header caps (64KB both ways) are fixed: without the response cap a
  # few App responses with huge headers OOM-kill Caddy.
  #
  # The file is one explicit route: it deletes forged identity headers
  # first (X-Cloud-User-*, X-Cloud-Edge-Secret, X-Auth-Request-*,
  # X-Authentik-*, both spellings), sends /oauth2/* to the oauth2-proxy (so
  # the App's server never receives a cloud-apps callback), asks the
  # oauth2-proxy at /oauth2/auth and copies its X-Auth-Request-* answer to
  # X-Cloud-User-*, then proxies to the App with the homelab cookies
  # stripped and the edge secret added. Only the 401 handler differs by
  # access: a public App passes the request on with no identity, a private
  # App redirects a page load to sign-in and answers anything else 401.
  cloud_caddyfile_head = [
    "{", "admin off", "auto_https off", "persist_config off", "servers {",
    "trusted_proxies static private_ranges", "max_header_size 64KB", "}", "}",
    ":8080 {",
  ]
  cloud_caddyfile_app_leg = [
    "transport http {", "max_response_header 64KB", "@KEEPALIVE@", "}",
    "header_up Cookie `(?:^\\s*|;\\s*)(?:@COOKIES@)=[^;]*` \"\"",
    "header_up Cookie `^;\\s*` \"\"",
  ]
  # The App leg retries a refused connection for 5 s (the cloud repo's B21:
  # with 2 or more instances, a crashed one stays in the App's Kubernetes
  # Service for a second or two). Optional while Cloud releases it: a
  # Caddyfile rendered before has no such lines. A later change makes them
  # required. @RETRY@ stands for the group in cloud_caddyfile_res.
  cloud_caddyfile_retry = ["lb_try_duration 5s", "lb_try_interval 250ms", "lb_retry_match expression false"]
  # The edge opens one connection to the App per request (the cloud repo's
  # Render-parity P08 fix): the App's Kubernetes Service balances
  # connections, and a kept connection stays on its pod through that pod's
  # preStop delay. Optional while Cloud releases it, like the retry lines.
  # @KEEPALIVE@ stands for it in cloud_caddyfile_res.
  cloud_caddyfile_keepalive  = "keepalive off"
  cloud_caddyfile_set_cookie = "header_down Set-Cookie `(?i)^.*;\\s*domain\\s*=.*$` \"\""
  cloud_caddyfile_k1 = {
    start = [
      "route {",
      "request_header -X-Cloud-User-*", "request_header -X_Cloud_User_*",
      "request_header -X-Cloud-Edge-Secret", "request_header -X_Cloud_Edge_Secret",
      "request_header -X-Auth-Request-*", "request_header -X_Auth_Request_*",
      "request_header -X-Authentik-*", "request_header -X_Authentik_*",
      "reverse_proxy /oauth2/* auth-@APP@.@NS@.svc.cluster.local:80",
      "reverse_proxy auth-@APP@.@NS@.svc.cluster.local:80 {",
      "method GET", "rewrite /oauth2/auth",
      "header_up X-Forwarded-Method {method}", "header_up X-Forwarded-Uri {uri}",
      "@signed_in status 2xx",
      "handle_response @signed_in {",
      "@user not vars {rp.header.X-Auth-Request-User} \"\"",
      "request_header @user X-Cloud-User-Id {rp.header.X-Auth-Request-User}",
      "@email not vars {rp.header.X-Auth-Request-Email} \"\"",
      "request_header @email X-Cloud-User-Email {rp.header.X-Auth-Request-Email}",
      "@username not vars {rp.header.X-Auth-Request-Preferred-Username} \"\"",
      "request_header @username X-Cloud-User-Username {rp.header.X-Auth-Request-Preferred-Username}",
      "}",
      "@anonymous status 401",
      "handle_response @anonymous {",
    ]
    public = ["request_header -X-Cloud-User-*"]
    private = [
      "@page header Sec-Fetch-Mode navigate",
      "redir @page /oauth2/start?rd={%uri} 302",
      "@old_page {", "header !Sec-Fetch-Mode", "header Accept *text/html*", "}",
      "redir @old_page /oauth2/start?rd={%uri} 302",
      "header Content-Type application/json",
      "respond `{\"error\":{\"code\":\"sign_in_required\"}}` 401",
    ]
    end = concat(
      ["}", "}", "reverse_proxy app-@APP@.@NS@.svc.cluster.local:80 {", "@RETRY@"],
      local.cloud_caddyfile_app_leg,
      ["header_up X-Cloud-Edge-Secret {env.CLOUD_EDGE_SECRET}", local.cloud_caddyfile_set_cookie],
      ["}", "}", "}"],
    )
  }
  # A suspended App, or one in maintenance (the cloud repo's B06, `state`
  # in the Project File): the edge answers every request 503 with a fixed
  # page and proxies nothing, so it has no upstream, reads no identity and
  # strips no cookie (no request reaches App code). The pages are the cloud
  # repo's modules/app/edge.tf edge_pages, byte for byte: plain HTML with no
  # quote, brace or backslash, so each fits a CEL raw string and a Caddy
  # backtick token as it is.
  cloud_edge_pages = {
    suspended   = "<!doctype html><html lang=en><meta charset=utf-8><title>Suspended</title><h1>This App is suspended</h1><p>Its owner has stopped it for now. Try again later.</p></html>"
    maintenance = "<!doctype html><html lang=en><meta charset=utf-8><title>Maintenance</title><h1>This App is down for maintenance</h1><p>Try again in a few minutes.</p></html>"
  }
  cloud_caddyfile_page = {
    for k, page in local.cloud_edge_pages : k => concat(local.cloud_caddyfile_head, [
      "route {",
      "header Content-Type text/html;charset=utf-8",
      "header Cache-Control no-store",
      "respond `${page}` 503",
      "}", "}",
    ])
  }
  cloud_caddyfile_variants = merge({
    public  = concat(local.cloud_caddyfile_head, local.cloud_caddyfile_k1.start, local.cloud_caddyfile_k1.public, local.cloud_caddyfile_k1.end)
    private = concat(local.cloud_caddyfile_head, local.cloud_caddyfile_k1.start, local.cloud_caddyfile_k1.private, local.cloud_caddyfile_k1.end)
  }, { for k, lines in local.cloud_caddyfile_page : "page_${k}" => lines })
  # One cookie in the alternation: a name (a dot only escaped), optionally
  # followed by [^=;]* for a prefix.
  cloud_strip_cookie_re = "(?:[A-Za-z0-9_-]|\\\\[.])+(?:\\[\\^=;\\]\\*)?"
  # Each variant as a regex: every line with metacharacters escaped, any
  # indentation and a newline after it, optional comment lines before, blank
  # lines after.
  cloud_caddyfile_res = {
    for k, lines in local.cloud_caddyfile_variants : k => replace(join("", concat(
      ["^(?:[\\t ]*(?:#[^\\n]*)?\\n)*"],
      [for l in lines : l == "@RETRY@" ? "(?:${join("", [for r in local.cloud_caddyfile_retry : "[\\t ]*${r}\\n"])})?" : l == "@KEEPALIVE@" ? "(?:[\\t ]*${local.cloud_caddyfile_keepalive}\\n)?" : "[\\t ]*${replace(l, "/[\\\\.+*?()|\\[\\]{}^$]/", "\\$0")}\\n"],
      ["(?:[\\t ]*\\n)*$"],
    )), "@COOKIES@", "${local.cloud_strip_cookie_re}(?:\\|${local.cloud_strip_cookie_re})*")
  }
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
    # And the console's exec role (B22), which modules/project binds to the
    # console in each Project namespace.
    { api_groups = ["rbac.authorization.k8s.io"], resources = ["clusterroles"], verbs = ["bind"], resource_names = [local.cloud_project_role_name, local.cloud_console_exec.role] },
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

  # Bound in namespace `cloud` only (main.tf, Role cloud-reconciler-tasks):
  # the Postgres task Jobs (B28b, B28c). It creates a task's Job suspended,
  # creates the Secret with the task's credentials (owned by the Job, so
  # Kubernetes deletes it with the Job), lets the Job go with a patch, reads
  # its pod and log, and deletes a Job it gave up on. It may create Secrets
  # here but not read, change or delete any, and it creates no pod: the Job
  # controller does. cloud-pg-task and cloud-pg-task-secret admit only the
  # task shapes, and cloud-reconciler-scope nothing else in this namespace.
  cloud_reconciler_cloud_rules = [
    { api_groups = ["batch"], resources = ["jobs"], verbs = ["create", "get", "list", "delete", "patch"], resource_names = [] },
    { api_groups = [""], resources = ["pods", "events"], verbs = ["get", "list"], resource_names = [] },
    # RBAC cannot narrow these to the task pods: resource_names takes exact
    # names, and a Job's pod gets a random suffix. The reconciler reads
    # only its own Jobs' pods; nothing it reads here is a Secret.
    { api_groups = [""], resources = ["pods/log"], verbs = ["get"], resource_names = [] },
    { api_groups = [""], resources = ["secrets"], verbs = ["create"], resource_names = [] },
  ]

  # Bound per Project namespace by a RoleBinding the reconciler creates there.
  # No Traefik Middlewares: Cloud renders none (cloud-managed-middleware).
  cloud_reconciler_project_rules = [
    { api_groups = [""], resources = ["resourcequotas", "limitranges", "serviceaccounts", "services", "secrets", "configmaps"], verbs = local.cloud_write_verbs, resource_names = [] },
    { api_groups = ["apps"], resources = ["deployments"], verbs = local.cloud_write_verbs, resource_names = [] },
    # An App with 2 or more instances keeps one through a drain
    # (cloud-managed-pdb).
    { api_groups = ["policy"], resources = ["poddisruptionbudgets"], verbs = local.cloud_write_verbs, resource_names = [] },
    # Read only: why a Deploy's new pods are not ready (image pull, quota,
    # exit, readiness). Cloud never writes pods or ReplicaSets itself.
    { api_groups = [""], resources = ["pods", "events"], verbs = ["get", "list"], resource_names = [] },
    { api_groups = ["apps"], resources = ["replicasets"], verbs = ["get", "list"], resource_names = [] },
    # A Deploy's migrations (backlog B16): the reconciler starts one Job per
    # Deploy before the rollout, waits for it, reads its pod's output and
    # deletes a Job it gave up on. cloud-managed-job admits only that shape.
    { api_groups = ["batch"], resources = ["jobs"], verbs = ["create", "get", "list", "delete"], resource_names = [] },
    { api_groups = [""], resources = ["pods/log"], verbs = ["get"], resource_names = [] },
    # Cron Services (the cloud repo's B19): CronJob cron-<name>. A manual run
    # is a Job cron-<name>-m<run id> the reconciler creates from its
    # jobTemplate with the jobs row above; it never changes one: its
    # ttlSecondsAfterFinished removes it, and its ownerReference removes it
    # with its CronJob. cloud-managed-cronjob checks the CronJob,
    # cloud-managed-cron-job each Job, and cloud-managed-pod the Job's pods.
    { api_groups = ["batch"], resources = ["cronjobs"], verbs = local.cloud_write_verbs, resource_names = [] },
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
  #     is never banned), and backup-mx admits it (next entry). The
  #     whitelist stays: CrowdSec cannot tell Project traffic from the
  #     household's, which arrives with the same address, so a ban scoped
  #     to Projects is not possible (docs/agents/security.md, "Open risk").
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

  # TCP ports no Project pod may reach, in either IP family (Viktor's
  # decision V8, cloud critique M1): SMTP 25, SMTPS 465, submission 587 and
  # the common alternative 2525. Project traffic leaves with the home WAN
  # address, so one App sending spam could put that address on block lists,
  # which would hurt the homelab mail server and every household service.
  # Cloud's Project policy denies the same ports (EGRESS_DENIED_TCP_PORTS in
  # render.ts; tests/cloud-access.test.sh compares them). Never empty: a
  # Calico rule with no ports matches every port.
  cloud_egress_denied_tcp_ports = [25, 465, 587, 2525]

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
  # can only narrow it, and denies the rest. Before any Pass it denies the
  # mail ports (cloud_egress_denied_tcp_ports) everywhere.
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
        # Every App's oauth2-proxy redeems codes and reads keys at the
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
        # The mail ports, to every destination: the rule names no addresses,
        # so it covers IPv4 and IPv6. It sits before every Pass, so no
        # Project policy can undo it. Rollback: revert the commit that added
        # it and apply stacks/cloud.
        { action = "Deny", protocol = "TCP", destination = { ports = local.cloud_egress_denied_tcp_ports } },
        # A psql toolbox (B22) reaches DNS and the CNPG primary above and
        # nothing else: no internet, no other pod, even its own namespace's.
        { action = "Deny", source = { selector = "${local.cloud_component_label} == '${local.cloud_toolbox.component}'" } },
        # Pods in a managed namespace: the Project policy allows only its own
        # namespace. A GlobalNetworkPolicy cannot say "the same namespace".
        { action = "Pass", destination = { namespaceSelector = "${local.cloud_managed_label} == 'true'" } },
        { action = "Pass", destination = { nets = ["0.0.0.0/0"], notNets = local.cloud_egress_excluded.ipv4 } },
        { action = "Pass", destination = { nets = ["::/0"], notNets = local.cloud_egress_excluded.ipv6 } },
        { action = "Deny" },
      ]
    }
  }

  # Who may connect to a Project pod (M2 contract, Addendum v2 point 8;
  # app-kit K1). The edge is the only way to App code from outside, so App
  # pods accept connections only from edge pods, and from App pods on the
  # App port (an internal App's callers), edge pods only from Traefik, and
  # oauth2-proxy pods only from edge pods on 4180. Everything else is denied
  # here, before the default tier, so a Project policy cannot let Traefik,
  # another namespace or the LAN reach App pods directly. A GlobalNetworkPolicy
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
          destination = { selector = "${local.cloud_component_label} == '${local.cloud_edge.component}'" }
        },
        # The edge asks the App's oauth2-proxy who is signed in and sends it
        # /oauth2/*, on its port only.
        {
          action      = "Pass"
          protocol    = "TCP"
          source      = { namespaceSelector = "${local.cloud_managed_label} == 'true'", selector = "${local.cloud_component_label} == '${local.cloud_edge.component}'" }
          destination = { selector = "${local.cloud_component_label} == '${local.cloud_oauth2_proxy.component}'", ports = [local.cloud_oauth2_proxy.port] }
        },
        {
          action      = "Pass"
          source      = { namespaceSelector = "${local.cloud_managed_label} == 'true'", selector = "${local.cloud_component_label} == '${local.cloud_edge.component}'" }
          destination = { selector = "${local.cloud_component_label} == 'app'" }
        },
        # An internal App's callers: App pods to the pods of an internal
        # App (label access=internal, which the cloud repo's modules/app
        # sets on those pods only), on the App port only, inside managed
        # namespaces. A public or private App's pods never match, so they
        # stay reachable through their edge only, even in a Project whose
        # policy is not there yet. A GlobalNetworkPolicy cannot say "the
        # same namespace": Cloud's Project policy admits only its own
        # namespace's callers (modules/project, internal_callers), and
        # modules/app starts App pods only once that policy exists. Traefik
        # and the LAN never match this rule.
        {
          action      = "Pass"
          protocol    = "TCP"
          source      = { namespaceSelector = "${local.cloud_managed_label} == 'true'", selector = "${local.cloud_component_label} == 'app'" }
          destination = { selector = "${local.cloud_component_label} == 'app' && ${local.cloud_access_label} == 'internal'", ports = [local.cloud_app_port] }
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
  # @MIG and @JOB do the same for a migrate pod and a one-off job pod.
  cloud_pod_rules = [for r in [
    {
      expression = "variables.component in ${jsonencode(local.cloud_workload_components)}"
      message    = "in a Cloud namespace, a pod is labelled ${local.cloud_component_label} ${join(", ", local.cloud_workload_components)}"
    },
    # Init containers: Cloud's migrations (app-kit K3), one container named
    # migrate in an App pod, running the App's own image before it starts. A
    # restartPolicy would make it a sidecar that runs beside the App; the
    # edge and the oauth2-proxy have none, so their pins stay whole.
    {
      expression = "!has(@S.initContainers) || size(@S.initContainers) == 0 || variables.component == 'app'"
      message    = "in a Cloud namespace, only an App pod may have an init container"
    },
    {
      expression = "!has(@S.initContainers) || size(@S.initContainers) <= 1"
      message    = "in a Cloud namespace, a pod has at most one init container"
    },
    {
      expression = "!has(@S.initContainers) || @S.initContainers.all(c, c.name == 'migrate' && !has(c.restartPolicy) && c.image == @S.containers[0].image)"
      message    = "in a Cloud namespace, the init container is named migrate, sets no restartPolicy and runs the image of the pod's first container"
    },
    # The rules with each_container check every container and every init
    # container alike.
    {
      each_container = "!has(c.resources) || ((!has(dyn(c.resources).requests) || dyn(c.resources).requests.all(k, k in ${jsonencode(local.cloud_pod_resources)})) && (!has(dyn(c.resources).limits) || dyn(c.resources).limits.all(k, k in ${jsonencode(local.cloud_pod_resources)})))"
      message        = "in a Cloud namespace, a container may request only ${join(", ", local.cloud_pod_resources)}: no GPU or other extended resource"
    },
    {
      # The kubelet enforces the limit, the quota counts it, and a container
      # without one could fill the node's disk.
      # dyn(): the API server's type checker has no schema for
      # resources.limits or emptyDir.sizeLimit (quantities), though both
      # evaluate.
      each_container = "has(c.resources) && has(dyn(c.resources).limits) && 'ephemeral-storage' in dyn(c.resources).limits"
      message        = "in a Cloud namespace, every container sets an ephemeral-storage limit"
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
      # An App's pods spread over nodes when they can (the cloud repo's
      # B21): one soft constraint on the hostname, over its own App's pods.
      # A hard one, or one over other pods, could hold pods Pending or
      # steer them by others' placement.
      expression = "!has(@S.topologySpreadConstraints) || size(@S.topologySpreadConstraints) == 0 || (variables.component == 'app' && size(@S.topologySpreadConstraints) == 1 && @S.topologySpreadConstraints.all(c, c.maxSkew == 1 && c.topologyKey == 'kubernetes.io/hostname' && c.whenUnsatisfiable == 'ScheduleAnyway' && !has(c.minDomains) && (!has(c.matchLabelKeys) || size(c.matchLabelKeys) == 0) && (!has(c.nodeAffinityPolicy) || c.nodeAffinityPolicy == 'Honor') && (!has(c.nodeTaintsPolicy) || c.nodeTaintsPolicy == 'Ignore') && has(c.labelSelector) && !has(c.labelSelector.matchExpressions) && has(c.labelSelector.matchLabels) && '${local.cloud_component_label}' in c.labelSelector.matchLabels && c.labelSelector.matchLabels['${local.cloud_component_label}'] == 'app' && '${local.cloud_service_label}' in c.labelSelector.matchLabels && c.labelSelector.matchLabels['${local.cloud_service_label}'] == variables.service))"
      message    = "in a Cloud namespace, only an App pod may set topologySpreadConstraints: one, maxSkew 1 on kubernetes.io/hostname, ScheduleAnyway, over its own App's pods by matchLabels"
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
      each_container = join(" && ", concat(
        [for pr in ["livenessProbe", "readinessProbe", "startupProbe"] : "(!has(c.${pr}) || ((!has(c.${pr}.httpGet) || !has(c.${pr}.httpGet.host) || c.${pr}.httpGet.host == '') && (!has(c.${pr}.tcpSocket) || !has(c.${pr}.tcpSocket.host) || c.${pr}.tcpSocket.host == '')))"],
        [for h in ["postStart", "preStop"] : "(!has(c.lifecycle) || !has(c.lifecycle.${h}) || ((!has(c.lifecycle.${h}.httpGet) || !has(c.lifecycle.${h}.httpGet.host) || c.lifecycle.${h}.httpGet.host == '') && (!has(c.lifecycle.${h}.tcpSocket) || !has(c.lifecycle.${h}.tcpSocket.host) || c.lifecycle.${h}.tcpSocket.host == '')))"],
      ))
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
      # The env: the fixed values, each once, plus the edge secret from the
      # App's own Secret, always.
      expression = "@EDGE @S.containers.all(c, !has(c.command) && has(c.args) && c.args == ${jsonencode(local.cloud_edge.args)} && !has(c.envFrom) && has(c.env) && size(c.env) == ${length(local.cloud_edge.env) + 1} && c.env.exists(e, e.name == '${local.cloud_edge.secret_env}') && ${jsonencode(keys(local.cloud_edge.env))}.all(k, c.env.exists(e, e.name == k)) && c.env.all(e, (e.name in ${jsonencode(local.cloud_edge.env)} && has(e.value) && !has(e.valueFrom) && e.value == ${jsonencode(local.cloud_edge.env)}[e.name]) || (e.name == '${local.cloud_edge.secret_env}' && (!has(e.value) || e.value == '') && has(e.valueFrom) && has(e.valueFrom.secretKeyRef) && !has(e.valueFrom.configMapKeyRef) && !has(e.valueFrom.fieldRef) && !has(e.valueFrom.resourceFieldRef) && e.valueFrom.secretKeyRef.name == '${local.cloud_edge.prefix}' + variables.service && e.valueFrom.secretKeyRef.key == '${local.cloud_edge.secret_key}' && (!has(e.valueFrom.secretKeyRef.optional) || !e.valueFrom.secretKeyRef.optional))) && !has(c.lifecycle) && !has(c.livenessProbe) && !has(c.startupProbe))"
      message    = "in a Cloud namespace, the edge runs as Cloud renders it: args ${join(" ", local.cloud_edge.args)}, env only ${join(" and ", keys(local.cloud_edge.env))} and ${local.cloud_edge.secret_env} from Secret ${local.cloud_edge.prefix}<its App> key ${local.cloud_edge.secret_key}, and no command, envFrom, lifecycle hook, liveness or startup probe"
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
    # A migrate pod (local.cloud_migrate): one container named migrate that
    # runs its image's entrypoint with the App's migrate args, once.
    {
      expression = "@MIG (size(@S.containers) == 1 && @S.containers[0].name == '${local.cloud_migrate.container}' && !has(@S.containers[0].command) && has(@S.containers[0].args) && size(@S.containers[0].args) >= 1 && size(@S.containers[0].args) <= ${local.cloud_migrate.max_args} && @S.containers[0].args.all(a, size(a) <= ${local.cloud_migrate.max_arg}) && @S.containers[0].image.contains('@sha256:'))"
      message    = "in a Cloud namespace, a migrate pod has one container, ${local.cloud_migrate.container}, running an image by digest with no command and 1 to ${local.cloud_migrate.max_args} args of at most ${local.cloud_migrate.max_arg} characters"
    },
    {
      expression = "@MIG (has(@S.restartPolicy) && @S.restartPolicy == 'Never' && @S.containers.all(c, !has(c.lifecycle) && !has(c.ports) && !has(c.livenessProbe) && !has(c.readinessProbe) && !has(c.startupProbe)))"
      message    = "in a Cloud namespace, a migrate pod runs once (restartPolicy Never), listens on no port and has no probe or lifecycle hook"
    },
    # A one-off job pod (local.cloud_one_off_job): one container named job
    # that runs the User's command, given as a list and never through a
    # shell, once. No args: the whole command is in command.
    {
      expression = "@JOB (size(@S.containers) == 1 && @S.containers[0].name == '${local.cloud_one_off_job.container}' && has(@S.containers[0].command) && size(@S.containers[0].command) >= 1 && size(@S.containers[0].command) <= ${local.cloud_one_off_job.max_command} && @S.containers[0].command.all(a, size(a) <= ${local.cloud_one_off_job.max_arg}) && (!has(@S.containers[0].args) || size(@S.containers[0].args) == 0) && @S.containers[0].image.contains('@sha256:'))"
      message    = "in a Cloud namespace, a one-off job pod has one container, ${local.cloud_one_off_job.container}, running an image by digest with a command of 1 to ${local.cloud_one_off_job.max_command} items of at most ${local.cloud_one_off_job.max_arg} characters and no args"
    },
    {
      expression = "@JOB (has(@S.restartPolicy) && @S.restartPolicy == 'Never' && @S.containers.all(c, !has(c.lifecycle) && !has(c.ports) && !has(c.livenessProbe) && !has(c.readinessProbe) && !has(c.startupProbe)))"
      message    = "in a Cloud namespace, a one-off job pod runs once (restartPolicy Never), listens on no port and has no probe or lifecycle hook"
    },
    # A psql toolbox pod (local.cloud_toolbox, B22): one container that only
    # sleeps, in Cloud's pinned image, with the Postgres role of its own
    # Service from Secret pg-<service>, no token, a read-only root and only
    # emptyDir volumes. The console runs psql in it through pods/exec.
    {
      expression = "@TBX (size(@S.containers) == 1 && @S.containers[0].name == '${local.cloud_toolbox.container}' && @S.containers[0].image in ${jsonencode(values(local.cloud_toolbox.images))} && has(@S.containers[0].command) && size(@S.containers[0].command) == 2 && @S.containers[0].command[0] == 'sleep' && @S.containers[0].command[1].matches('^[0-9]{1,6}$') && (!has(@S.containers[0].args) || size(@S.containers[0].args) == 0))"
      message    = "in a Cloud namespace, a toolbox pod has one container, ${local.cloud_toolbox.container}, running ${join(" or ", values(local.cloud_toolbox.images))} with the command sleep <seconds> and no args"
    },
    {
      expression = "@TBX (has(@S.restartPolicy) && @S.restartPolicy == 'Never' && has(@S.automountServiceAccountToken) && !@S.automountServiceAccountToken && (!has(@S.volumes) || @S.volumes.all(v, has(v.emptyDir))) && @S.containers.all(c, !has(c.lifecycle) && !has(c.ports) && !has(c.livenessProbe) && !has(c.readinessProbe) && !has(c.startupProbe) && !has(c.envFrom)))"
      message    = "in a Cloud namespace, a toolbox pod runs once (restartPolicy Never) with no service account token and only emptyDir volumes, and its container has no port, probe, lifecycle hook or envFrom"
    },
    {
      expression = "@TBX @S.containers.all(c, !has(c.env) || c.env.all(e, (!has(e.valueFrom) && has(e.value)) || (has(e.valueFrom) && (!has(e.value) || e.value == '') && has(e.valueFrom.secretKeyRef) && !has(e.valueFrom.configMapKeyRef) && !has(e.valueFrom.fieldRef) && !has(e.valueFrom.resourceFieldRef) && e.valueFrom.secretKeyRef.name == '${local.cloud_toolbox.secret_prefix}' + variables.service)))"
      message    = "in a Cloud namespace, a toolbox's env is plain values and keys of Secret ${local.cloud_toolbox.secret_prefix}<its Service> only"
    },
    {
      expression = "@TBX @S.containers.all(c, has(c.securityContext) && has(c.securityContext.readOnlyRootFilesystem) && c.securityContext.readOnlyRootFilesystem && has(c.securityContext.allowPrivilegeEscalation) && !c.securityContext.allowPrivilegeEscalation && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot && has(c.securityContext.capabilities) && has(c.securityContext.capabilities.drop) && 'ALL' in c.securityContext.capabilities.drop && (!has(c.securityContext.capabilities.add) || size(c.securityContext.capabilities.add) == 0))"
      message    = "in a Cloud namespace, a toolbox runs as non-root with a read-only root filesystem, no privilege escalation and every capability dropped"
    },
    # The oauth2-proxy (local.cloud_oauth2_proxy).
    {
      expression = "@AUTH (size(@S.containers) == 1 && @S.containers[0].name == '${local.cloud_oauth2_proxy.container}' && @S.containers[0].image == '${local.cloud_oauth2_proxy.image}')"
      message    = "in a Cloud namespace, an oauth2-proxy pod has one container, ${local.cloud_oauth2_proxy.container}, running ${local.cloud_oauth2_proxy.image}"
    },
    {
      expression = "@AUTH @S.containers.all(c, !has(c.command) && has(c.args) && (${join(" || ", [for k in ["args_private", "args_public"] : "c.args == ${jsonencode(local.cloud_oauth2_proxy[k])}.map(a, a.replace('@APP@', variables.service))"])}) && !has(c.env) && has(c.envFrom) && size(c.envFrom) == 1 && c.envFrom.all(e, has(e.secretRef) && e.secretRef.name == '${local.cloud_oauth2_proxy.prefix}' + variables.service && !has(e.configMapRef) && (!has(e.prefix) || e.prefix == '')) && !has(c.lifecycle) && ${join(" && ", [for pr in ["livenessProbe", "readinessProbe", "startupProbe"] : "(!has(c.${pr}) || !has(c.${pr}.exec))"])})"
      message    = "in a Cloud namespace, the oauth2-proxy runs as Cloud renders it: the fixed args with its own App's host and either its emails file or ${local.cloud_oauth2_proxy_any_email}, Secret ${local.cloud_oauth2_proxy.prefix}<its App> as its only env, and no command, lifecycle hook or exec probe"
    },
    {
      expression = "@AUTH @S.containers.all(c, has(c.ports) && size(c.ports) == 1 && c.ports.all(p, has(p.name) && p.name == '${local.cloud_oauth2_proxy.port_name}' && p.containerPort == ${local.cloud_oauth2_proxy.port} && !has(p.hostPort) && !has(p.hostIP)))"
      message    = "in a Cloud namespace, the oauth2-proxy has one port, ${local.cloud_oauth2_proxy.port_name} = ${local.cloud_oauth2_proxy.port}, and no host port"
    },
    {
      # A public App's oauth2-proxy (--email-domain=*) has no emails file:
      # no mount and no volume. Any other mounts only the allowlist.
      expression = "@AUTH @S.containers.all(c, has(c.args) && c.args.exists(a, a == '${local.cloud_oauth2_proxy_any_email}') ? ((!has(c.volumeMounts) || size(c.volumeMounts) == 0) && (!has(@S.volumes) || size(@S.volumes) == 0)) : (has(c.volumeMounts) && size(c.volumeMounts) == 1 && c.volumeMounts.all(m, m.mountPath == '${local.cloud_oauth2_proxy.emails_dir}' && has(m.readOnly) && m.readOnly && (!has(m.subPath) || m.subPath == '') && (!has(m.subPathExpr) || m.subPathExpr == '') && has(@S.volumes) && @S.volumes.exists(v, v.name == m.name && has(v.configMap) && has(v.configMap.name) && v.configMap.name == '${local.cloud_oauth2_proxy.prefix}' + variables.service))))"
      message    = "in a Cloud namespace, the oauth2-proxy mounts only ConfigMap ${local.cloud_oauth2_proxy.prefix}<its App>, read-only, at ${local.cloud_oauth2_proxy.emails_dir}, and with ${local.cloud_oauth2_proxy_any_email} nothing at all"
    },
    ] : {
    expression = replace(replace(replace(replace(replace(
      try("@S.containers.all(c, ${r.each_container}) && (!has(@S.initContainers) || @S.initContainers.all(c, ${r.each_container}))", r.expression),
    "@EDGE ", "variables.component != '${local.cloud_edge.component}' || "), "@AUTH ", "variables.component != '${local.cloud_oauth2_proxy.component}' || "), "@MIG ", "variables.component != '${local.cloud_migrate.component}' || "), "@JOB ", "variables.component != '${local.cloud_one_off_job.component}' || "), "@TBX ", "variables.component != '${local.cloud_toolbox.component}' || ")
    message = r.message
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
          # A Postgres task's Job, or its Secret, in the reconciler's own
          # namespace; cloud-pg-task and cloud-pg-task-secret check the shape.
          # A delete names a Job by its old object, which no other policy
          # checks, so the name is checked here.
          { name = "isPgTask", expression = "namespaceObject != null && namespaceObject.metadata.name == '${local.cloud_namespace}' && ((request.resource.group == 'batch' && request.resource.resource == 'jobs' && (request.operation != 'DELETE' || (oldObject != null && oldObject.metadata.name.matches('${local.cloud_pg_task.name_re}')))) || (request.resource.group == '' && request.resource.resource == 'secrets' && request.operation == 'CREATE'))" },
        ]
        validations = [
          {
            # The name check too: a homelab namespace someone labels by
            # mistake must not become reconciler-writable.
            expression = "variables.isNamespace || variables.isPgTask || (namespaceObject != null && namespaceObject.metadata.name.startsWith('p-') && ${format(local.cloud_label_is_true, "namespaceObject", "namespaceObject", "namespaceObject")})"
            message    = "cloud-reconciler may write only in namespaces named p-* labelled ${local.cloud_managed_label}=true, and Postgres task Jobs and their Secrets in ${local.cloud_namespace}"
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
            # The second shape is the console's exec binding (B22), named
            # for its role, one per namespace.
            expression = "!variables.isRoleBinding || request.operation == 'DELETE' || (object.roleRef.kind == 'ClusterRole' && object.roleRef.name == '${local.cloud_project_role_name}' && has(object.subjects) && size(object.subjects) == 1 && object.subjects.all(s, s.kind == 'ServiceAccount' && s.name == '${local.cloud_reconciler_sa}' && has(s.namespace) && s.namespace == '${local.cloud_namespace}')) || (object.metadata.name == '${local.cloud_console_exec.role}' && object.roleRef.kind == 'ClusterRole' && object.roleRef.name == '${local.cloud_console_exec.role}' && has(object.subjects) && size(object.subjects) == 1 && object.subjects.all(s, s.kind == 'ServiceAccount' && s.name == '${local.cloud_console_exec.service_account}' && has(s.namespace) && s.namespace == '${local.cloud_namespace}'))"
            message    = "cloud-reconciler may bind only ClusterRole ${local.cloud_project_role_name} to service account ${local.cloud_namespace}/${local.cloud_reconciler_sa}, and ClusterRole ${local.cloud_console_exec.role} to service account ${local.cloud_namespace}/${local.cloud_console_exec.service_account} in a RoleBinding named ${local.cloud_console_exec.role}"
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
            # Traefik reads service.* annotations from the Kubernetes
            # Service. Only the edge names a ServersTransport, and only
            # Cloud's (local.cloud_edge_transport); no other traefik.*
            # annotation, so a Service cannot pick another transport.
            expression = "variables.anns.all(k, !k.startsWith('traefik.') || (k == '${local.cloud_edge_transport.annotation}' && object.metadata.name.startsWith('${local.cloud_edge.prefix}') && variables.anns[k] == '${local.cloud_edge_transport.ref}'))"
            message    = "in a Cloud namespace, the only traefik.* annotation a Kubernetes Service may carry is ${local.cloud_edge_transport.annotation}: ${local.cloud_edge_transport.ref}, on Service ${local.cloud_edge.prefix}<app>"
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
            # The way in is the App's edge, public or private; never the
            # oauth2-proxy or App pods.
            expression = "!has(object.spec.rules) || object.spec.rules.all(r, !has(r.http) || r.http.paths.all(p, has(p.backend.service) && has(p.backend.service.port) && has(p.backend.service.port.name) && !has(p.backend.service.port.number) && p.backend.service.name.startsWith('${local.cloud_edge.prefix}') && p.backend.service.port.name == '${local.cloud_edge.port_name}'))"
            message    = "in a Cloud namespace, every Ingress backend is an edge Service (${local.cloud_edge.prefix}<app>, port ${local.cloud_edge.port_name}), named by port name"
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
          { name = "app", expression = "object.metadata.name.substring(${length(local.cloud_edge.prefix)})" },
          # The one header_up Cookie line that strips cookies (a comment line
          # starts with #, so it cannot match).
          { name = "cookieLine", expression = "size(variables.caddyfile) <= 8192 ? variables.caddyfile.find(r'\\n[\\t ]*header_up Cookie `[^`\\n]*`') : ''" },
          # A suspended App's or a maintenance page: it reaches no App, so
          # it has no cookie line to check.
          { name = "isPage", expression = "size(variables.caddyfile) <= 8192 && (${join(" || ", [for k in sort(keys(local.cloud_caddyfile_page)) : "variables.caddyfile.matches(r'${local.cloud_caddyfile_res["page_${k}"]}')"])})" },
        ]
        validations = [
          {
            expression = "has(object.data) && size(object.data) == 1 && 'Caddyfile' in object.data && !has(object.binaryData)"
            message    = "in a Cloud namespace, a ${local.cloud_edge.prefix}* ConfigMap holds only the key Caddyfile"
            reason     = "Forbidden"
          },
          {
            expression = "size(variables.caddyfile) <= 8192 && (${join(" || ", [for k in sort(keys(local.cloud_caddyfile_res)) : "variables.caddyfile.matches(r'${local.cloud_caddyfile_res[k]}'.replace('@APP@', variables.app).replace('@NS@', request.namespace))"])})"
            message    = "in a Cloud namespace, an ${local.cloud_edge.prefix}<app> Caddyfile is one Cloud renders (modules/app/Caddyfile.tftpl): with only the strip list filled in and app-<app> and auth-<app> in this namespace as its upstreams, or the fixed suspended or maintenance page"
            reason     = "Forbidden"
          },
          {
            expression = "variables.isPage || (${join(" && ", [for c in local.cloud_strip_cookies_required_re : "variables.cookieLine.matches(r'[:|]${c}[|)]')"])})"
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
        validations = concat([for r in local.cloud_pod_rules : {
          expression = replace(r.expression, "@S", "object.spec")
          message    = r.message
          reason     = "Forbidden"
          }], [{
          # Only the Job controller makes a migrate, one-off job or toolbox
          # pod, for a Job that cloud-managed-job, cloud-managed-one-off-job
          # or cloud-managed-toolbox-job admitted.
          expression = "!(variables.component in ['${local.cloud_migrate.component}', '${local.cloud_one_off_job.component}', '${local.cloud_toolbox.component}']) || (has(object.metadata.ownerReferences) && object.metadata.ownerReferences.exists(o, o.apiVersion == 'batch/v1' && o.kind == 'Job' && has(o.controller) && o.controller))"
          message    = "in a Cloud namespace, a migrate, one-off job or toolbox pod is made only by its Job"
          reason     = "Forbidden"
        }])
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
        validations = concat([for r in local.cloud_pod_rules : {
          expression = replace(r.expression, "@S", "object.spec.template.spec")
          message    = r.message
          reason     = "Forbidden"
          }], [{
          # A suspended App runs 0 replicas, and its edge serves the
          # suspended page; the edge and the oauth2-proxy always run, so the
          # App's address always answers. The deployments/scale subresource
          # is not matched: its Scale object has no pod template, so the
          # component rules cannot read it here. The reconciler's project
          # role grants no deployments/scale, so it cannot scale that way;
          # only an admin can.
          expression = "variables.component in ['app', 'worker'] || !has(object.spec.replicas) || object.spec.replicas >= 1"
          message    = "in a Cloud namespace, only an App or a worker Deployment may run 0 replicas (a suspended App, a stopped worker); the edge and the oauth2-proxy run at least one"
          reason     = "Forbidden"
          }, {
          expression = "!(variables.component in ['${local.cloud_migrate.component}', '${local.cloud_one_off_job.component}', '${local.cloud_toolbox.component}'])"
          message    = "in a Cloud namespace, a migrate, one-off job or toolbox pod runs only from a Job"
          reason     = "Forbidden"
          }, {
          # An App runs 1 to 3 instances (the Project File's `instances`),
          # the most its Postgres role's connection limit takes; the edge
          # and the oauth2-proxy run one.
          expression = "!has(object.spec.replicas) || object.spec.replicas <= ${local.cloud_max_replicas}"
          message    = "in a Cloud namespace, a Deployment runs at most ${local.cloud_max_replicas} replicas (an App's instances)"
          reason     = "Forbidden"
        }])
      }
    }
    managed_pdb = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-pdb" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["policy"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["poddisruptionbudgets"]
          }]
        }
        variables = [
          { name = "labels", expression = "has(object.spec.selector) && has(object.spec.selector.matchLabels) ? object.spec.selector.matchLabels : {}" },
        ]
        validations = [
          {
            # An int 1, never a percentage: "100%" would hold every pod.
            expression = "has(object.spec.minAvailable) && type(object.spec.minAvailable) == int && object.spec.minAvailable == 1 && !has(object.spec.maxUnavailable)"
            message    = "in a Cloud namespace, a PodDisruptionBudget sets minAvailable 1 and no maxUnavailable"
            reason     = "Forbidden"
          },
          {
            expression = "has(object.spec.unhealthyPodEvictionPolicy) && object.spec.unhealthyPodEvictionPolicy == 'AlwaysAllow'"
            message    = "in a Cloud namespace, a PodDisruptionBudget sets unhealthyPodEvictionPolicy AlwaysAllow, so an unready App pod never holds a drain"
            reason     = "Forbidden"
          },
          {
            # One PDB per App, named for it, so two cannot add up.
            expression = "'${local.cloud_service_label}' in variables.labels && object.metadata.name == 'app-' + variables.labels['${local.cloud_service_label}']"
            message    = "in a Cloud namespace, a PodDisruptionBudget is named app-<its App>, one per App"
            reason     = "Forbidden"
          },
          {
            # Labels only: matchExpressions could select every pod of the
            # namespace, edge and oauth2-proxy pods included.
            expression = "has(object.spec.selector) && !has(object.spec.selector.matchExpressions) && '${local.cloud_component_label}' in variables.labels && variables.labels['${local.cloud_component_label}'] == 'app' && '${local.cloud_service_label}' in variables.labels && variables.labels['${local.cloud_service_label}'] != ''"
            message    = "in a Cloud namespace, a PodDisruptionBudget selects the pods of one App by matchLabels only: ${local.cloud_component_label}=app and ${local.cloud_service_label}=<its App>"
            reason     = "Forbidden"
          },
        ]
      }
    }
    managed_pdb_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-pdb" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-pdb" })
    }
    managed_deployment_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-deployment" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-deployment" })
    }
    # A Job's pod template passes the pod rules at write time, so a Job that
    # could never make its pod is refused at once. Every Job runs once, with
    # a deadline and a TTL. It is a Deploy's migrations (B16): the
    # reconciler's own, named for its Deploy and owned by nothing. A cron
    # run (B19, pod component cron) is cloud-managed-cron-job's and a
    # one-off job (B20, pod component job) cloud-managed-one-off-job's and a
    # psql toolbox (B22, pod component toolbox) cloud-managed-toolbox-job's,
    # so this policy skips all three; every other Job is refused here.
    managed_job = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-job" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["batch"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["jobs"]
          }]
        }
        matchConditions = [{
          name       = "not-a-cron-run"
          expression = "!(has(object.spec.template.metadata.labels) && '${local.cloud_component_label}' in object.spec.template.metadata.labels && object.spec.template.metadata.labels['${local.cloud_component_label}'] == 'cron')"
          }, {
          name       = "not-a-one-off-job"
          expression = "!(${local.cloud_one_off_job_component_is})"
          }, {
          name       = "not-a-toolbox"
          expression = "!(${local.cloud_toolbox_component_is})"
        }]
        variables = concat(
          [for v in local.cloud_pod_variables : { name = v.name, expression = replace(v.expression, "@M", "object.spec.template.metadata") }],
          [{ name = "owners", expression = "has(object.metadata.ownerReferences) ? object.metadata.ownerReferences : []" }],
        )
        validations = concat([for r in local.cloud_pod_rules : {
          expression = replace(r.expression, "@S", "object.spec.template.spec")
          message    = r.message
          reason     = "Forbidden"
          }], [
          {
            expression = "has(object.spec.backoffLimit) && object.spec.backoffLimit == 0 && (!has(object.spec.parallelism) || object.spec.parallelism <= 1) && (!has(object.spec.completions) || object.spec.completions == 1) && !has(object.spec.podFailurePolicy) && !has(object.spec.successPolicy) && (!has(object.spec.manualSelector) || !object.spec.manualSelector)"
            message    = "in a Cloud namespace, a Job runs one pod once: backoffLimit 0, at most one pod, no failure or success policy and no manual selector"
            reason     = "Forbidden"
          },
          {
            expression = "has(object.spec.activeDeadlineSeconds) && object.spec.activeDeadlineSeconds <= ${local.cloud_job_max_deadline_seconds} && has(object.spec.ttlSecondsAfterFinished) && object.spec.ttlSecondsAfterFinished <= ${local.cloud_job_max_ttl_seconds}"
            message    = "in a Cloud namespace, a Job sets activeDeadlineSeconds up to ${local.cloud_job_max_deadline_seconds} and ttlSecondsAfterFinished up to ${local.cloud_job_max_ttl_seconds}"
            reason     = "Forbidden"
          },
          {
            expression = "has(object.spec.template.spec.restartPolicy) && object.spec.template.spec.restartPolicy == 'Never'"
            message    = "in a Cloud namespace, a Job's pod sets restartPolicy Never"
            reason     = "Forbidden"
          },
          {
            # A migrate Job's labels name the same Service and component as
            # its pod's, so what lists Jobs reads the same as what lists pods.
            expression = "variables.component != '${local.cloud_migrate.component}' || has(object.metadata.labels) && '${local.cloud_component_label}' in object.metadata.labels && object.metadata.labels['${local.cloud_component_label}'] == variables.component && '${local.cloud_service_label}' in object.metadata.labels && object.metadata.labels['${local.cloud_service_label}'] == variables.service"
            message    = "in a Cloud namespace, a migrate Job carries its pod's ${local.cloud_component_label} and ${local.cloud_service_label} labels"
            reason     = "Forbidden"
          },
          {
            # Not app: the App's Kubernetes Service selects component app, so
            # an App-labelled Job pod would get its requests.
            expression = "variables.component == '${local.cloud_migrate.component}'"
            message    = "in a Cloud namespace, a Job is a Deploy's migrations (component ${local.cloud_migrate.component}); a cron run is component cron, a one-off job component ${local.cloud_one_off_job.component} and a psql toolbox component ${local.cloud_toolbox.component}"
            reason     = "Forbidden"
          },
          {
            expression = "variables.component != '${local.cloud_migrate.component}' || (object.metadata.name.matches('${local.cloud_migrate.name_re}') && object.metadata.name.startsWith('app-' + variables.service + '-m') && size(object.metadata.name) == size(variables.service) + 15 && size(variables.owners) == 0)"
            message    = "in a Cloud namespace, a migrate Job is named app-<its App>-m<9 hex digits> and has no owner"
            reason     = "Forbidden"
          },
        ])
      }
    }
    managed_job_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-job" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-job" })
    }
    # A one-off job (B20): the command a User runs once with an App's live
    # image, env and secrets. The reconciler starts it; nothing else in a
    # Project namespace may make a Job whose pod is component job, since
    # this policy and the pod rules admit only that shape.
    managed_one_off_job = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-one-off-job" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["batch"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["jobs"]
          }]
        }
        matchConditions = [{
          name       = "a-one-off-job"
          expression = local.cloud_one_off_job_component_is
        }]
        variables = concat(
          [for v in local.cloud_pod_variables : { name = v.name, expression = replace(v.expression, "@M", "object.spec.template.metadata") }],
          [{ name = "owners", expression = "has(object.metadata.ownerReferences) ? object.metadata.ownerReferences : []" }],
        )
        validations = concat([for r in local.cloud_pod_rules : {
          expression = replace(r.expression, "@S", "object.spec.template.spec")
          message    = r.message
          reason     = "Forbidden"
          }], [
          {
            expression = "has(object.spec.backoffLimit) && object.spec.backoffLimit == 0 && (!has(object.spec.parallelism) || object.spec.parallelism <= 1) && (!has(object.spec.completions) || object.spec.completions == 1) && !has(object.spec.podFailurePolicy) && !has(object.spec.successPolicy) && (!has(object.spec.manualSelector) || !object.spec.manualSelector)"
            message    = "in a Cloud namespace, a one-off job runs one pod once: backoffLimit 0, at most one pod, no failure or success policy and no manual selector"
            reason     = "Forbidden"
          },
          {
            expression = "has(object.spec.activeDeadlineSeconds) && object.spec.activeDeadlineSeconds <= ${local.cloud_one_off_job.max_deadline_seconds} && has(object.spec.ttlSecondsAfterFinished) && object.spec.ttlSecondsAfterFinished <= ${local.cloud_job_max_ttl_seconds}"
            message    = "in a Cloud namespace, a one-off job sets activeDeadlineSeconds up to ${local.cloud_one_off_job.max_deadline_seconds} and ttlSecondsAfterFinished up to ${local.cloud_job_max_ttl_seconds}"
            reason     = "Forbidden"
          },
          {
            expression = "has(object.spec.template.spec.restartPolicy) && object.spec.template.spec.restartPolicy == 'Never'"
            message    = "in a Cloud namespace, a one-off job's pod sets restartPolicy Never"
            reason     = "Forbidden"
          },
          {
            # The Job's labels name the same Service and component as its
            # pod's, so what lists Jobs reads the same as what lists pods.
            expression = "has(object.metadata.labels) && '${local.cloud_component_label}' in object.metadata.labels && object.metadata.labels['${local.cloud_component_label}'] == variables.component && '${local.cloud_service_label}' in object.metadata.labels && object.metadata.labels['${local.cloud_service_label}'] == variables.service"
            message    = "in a Cloud namespace, a one-off job carries its pod's ${local.cloud_component_label} and ${local.cloud_service_label} labels"
            reason     = "Forbidden"
          },
          {
            expression = "object.metadata.name.matches('${local.cloud_one_off_job.name_re}') && object.metadata.name.startsWith('job-' + variables.service + '-') && size(object.metadata.name) == size(variables.service) + 14 && size(variables.owners) == 0"
            message    = "in a Cloud namespace, a one-off job is named job-<its App>-<9 hex digits> and has no owner"
            reason     = "Forbidden"
          },
        ])
      }
    }
    managed_one_off_job_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-one-off-job" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-one-off-job" })
    }
    # A psql toolbox (B22): one sleeping pod for one session. The reconciler
    # starts it; the pod rules above pin its pod.
    managed_toolbox_job = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-toolbox-job" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["batch"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["jobs"]
          }]
        }
        matchConditions = [{
          name       = "a-toolbox"
          expression = local.cloud_toolbox_component_is
        }]
        variables = concat(
          [for v in local.cloud_pod_variables : { name = v.name, expression = replace(v.expression, "@M", "object.spec.template.metadata") }],
          [
            { name = "owners", expression = "has(object.metadata.ownerReferences) ? object.metadata.ownerReferences : []" },
            { name = "jobLabels", expression = "has(object.metadata.labels) ? object.metadata.labels : {}" },
          ],
        )
        validations = concat([for r in local.cloud_pod_rules : {
          expression = replace(r.expression, "@S", "object.spec.template.spec")
          message    = r.message
          reason     = "Forbidden"
          }], [
          {
            expression = "has(object.spec.backoffLimit) && object.spec.backoffLimit == 0 && (!has(object.spec.parallelism) || object.spec.parallelism <= 1) && (!has(object.spec.completions) || object.spec.completions == 1) && !has(object.spec.podFailurePolicy) && !has(object.spec.successPolicy) && (!has(object.spec.manualSelector) || !object.spec.manualSelector)"
            message    = "in a Cloud namespace, a toolbox runs one pod once: backoffLimit 0, at most one pod, no failure or success policy and no manual selector"
            reason     = "Forbidden"
          },
          {
            expression = "has(object.spec.activeDeadlineSeconds) && object.spec.activeDeadlineSeconds <= ${local.cloud_toolbox.max_deadline_seconds} && has(object.spec.ttlSecondsAfterFinished) && object.spec.ttlSecondsAfterFinished <= 3600"
            message    = "in a Cloud namespace, a toolbox sets activeDeadlineSeconds up to ${local.cloud_toolbox.max_deadline_seconds} and ttlSecondsAfterFinished up to 3600"
            reason     = "Forbidden"
          },
          {
            # The Job carries every Cloud label of its pod (the Job
            # controller adds its own to the pod), so what lists Jobs reads
            # the same as what lists pods, and the session label names one.
            expression = "variables.podLabels.all(k, !k.startsWith('cloud.viktorbarzin.me/') || (k in variables.jobLabels && variables.jobLabels[k] == variables.podLabels[k])) && '${local.cloud_toolbox.session_label}' in variables.podLabels && variables.podLabels['${local.cloud_toolbox.session_label}'].matches('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') && '${local.cloud_toolbox.target_label}' in variables.podLabels && variables.podLabels['${local.cloud_toolbox.target_label}'] in ${jsonencode(keys(local.cloud_toolbox.images))}"
            message    = "in a Cloud namespace, a toolbox Job carries its pod's Cloud labels, a session id in ${local.cloud_toolbox.session_label} and a target in ${local.cloud_toolbox.target_label}"
            reason     = "Forbidden"
          },
          {
            # The image its target runs, so a Postgres session runs the
            # Postgres toolbox.
            expression = "variables.podLabels[?'${local.cloud_toolbox.target_label}'].orValue('') in ${jsonencode(keys(local.cloud_toolbox.images))} && object.spec.template.spec.containers.all(c, c.image == ${jsonencode(local.cloud_toolbox.images)}[variables.podLabels['${local.cloud_toolbox.target_label}']])"
            message    = "in a Cloud namespace, a toolbox runs the image of its target"
            reason     = "Forbidden"
          },
          {
            expression = "object.metadata.name.matches('${local.cloud_toolbox.name_re}') && object.metadata.name == 'toolbox-' + variables.podLabels[?'${local.cloud_toolbox.session_label}'].orValue('nosession').replace('-', '').substring(0, 9) && size(variables.owners) == 0"
            message    = "in a Cloud namespace, a toolbox Job is named toolbox-<the first 9 hex digits of its session id> and has no owner"
            reason     = "Forbidden"
          },
        ])
      }
    }
    managed_toolbox_job_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-toolbox-job" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-toolbox-job" })
    }
    # Shell and psql sessions (B22): what the console may run through
    # pods/exec. RBAC already keeps it to Project namespaces (the role is
    # bound only there); this keeps it to managed p-* namespaces even if a
    # binding appears elsewhere, to the App container with sh and the
    # toolbox container with psql, never the edge or the oauth2-proxy, and
    # never another command. Exec is a CONNECT whose object is the
    # PodExecOptions. No namespace selector on the binding: a refusal must
    # reach every namespace.
    console_exec = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-console-exec" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = [""]
            apiVersions = ["v1"]
            operations  = ["CONNECT"]
            resources   = ["pods/exec", "pods/attach", "pods/portforward"]
          }]
        }
        matchConditions = [{
          name       = "is-cloud-console"
          expression = "request.userInfo.username == '${local.cloud_console_exec.user}'"
        }]
        validations = [
          {
            expression = "request.subResource == 'exec'"
            message    = "the Cloud console may only exec, never attach or port-forward"
            reason     = "Forbidden"
          },
          {
            expression = "namespaceObject != null && namespaceObject.metadata.name.startsWith('p-') && ${format(local.cloud_label_is_true, "namespaceObject", "namespaceObject", "namespaceObject")}"
            message    = "the Cloud console may exec only in namespaces named p-* labelled ${local.cloud_managed_label}=true"
            reason     = "Forbidden"
          },
          {
            expression = "request.subResource != 'exec' || (has(object.container) && has(object.command) && ((object.container == 'app' && object.command == ['sh']) || (object.container == '${local.cloud_toolbox.container}' && size(object.command) > 0 && object.command[0] == 'psql')))"
            message    = "the Cloud console may exec only sh in container app or psql in container ${local.cloud_toolbox.container}"
            reason     = "Forbidden"
          },
        ]
      }
    }
    # A Postgres task's Job (the cloud repo's B28b, B28c) in the reconciler's
    # own namespace; cloud-pg-task-secret below checks the Secret that holds
    # the Project role's credentials for it. The only writes
    # cloud-reconciler-scope lets the
    # reconciler make in `cloud`, so this is the whole of what it may run
    # there: the pinned postgres image as uid 999, with the task's fixed
    # script, no service account token, no capability, a read-only root,
    # and of the NFS claims only Cloud's two dump directories, the nightly
    # one read-only and the manual one writable for a backup Job alone.
    pg_task = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-pg-task" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [
            { apiGroups = ["batch"], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["jobs"] },
          ]
        }
        matchConditions = [{
          name       = "is-cloud-reconciler"
          expression = "request.userInfo.username == '${local.cloud_reconciler_user}'"
        }]
        variables = [
          { name = "labels", expression = "has(object.metadata.labels) ? object.metadata.labels : {}" },
          { name = "component", expression = "'${local.cloud_component_label}' in variables.labels ? variables.labels['${local.cloud_component_label}'] : ''" },
          { name = "pod", expression = "object.spec.template.spec" },
          { name = "podLabels", expression = "has(object.spec.template.metadata) && has(object.spec.template.metadata.labels) ? object.spec.template.metadata.labels : {}" },
          { name = "owners", expression = "has(object.metadata.ownerReferences) ? object.metadata.ownerReferences : []" },
        ]
        validations = [
          {
            expression = "(variables.component in ${jsonencode([for k in local.cloud_pg_task.kinds : "pg-${k}"])} && object.metadata.name.matches('${local.cloud_pg_task.name_re}') && object.metadata.name.startsWith(variables.component + '-') && size(object.metadata.name) == size(variables.component) + 10 && '${local.cloud_component_label}' in variables.podLabels && variables.podLabels['${local.cloud_component_label}'] == variables.component && '${local.cloud_pg_task.task_label}' in variables.labels && '${local.cloud_pg_task.task_label}' in variables.podLabels && variables.podLabels['${local.cloud_pg_task.task_label}'] == variables.labels['${local.cloud_pg_task.task_label}'] && size(variables.owners) == 0)"
            message    = "in ${local.cloud_namespace}, a Postgres task Job is named pg-<kind>-<9 hex digits>, carries its pod's ${local.cloud_component_label} and ${local.cloud_pg_task.task_label} labels and has no owner"
            reason     = "Forbidden"
          },
          {
            expression = "(has(object.spec.backoffLimit) && object.spec.backoffLimit == 0 && (!has(object.spec.parallelism) || object.spec.parallelism <= 1) && (!has(object.spec.completions) || object.spec.completions == 1) && !has(object.spec.podFailurePolicy) && !has(object.spec.successPolicy) && (!has(object.spec.manualSelector) || !object.spec.manualSelector) && has(object.spec.activeDeadlineSeconds) && object.spec.activeDeadlineSeconds <= ${local.cloud_pg_task.max_deadline} && has(object.spec.ttlSecondsAfterFinished) && object.spec.ttlSecondsAfterFinished <= ${local.cloud_pg_task.max_ttl})"
            message    = "in ${local.cloud_namespace}, a Postgres task Job runs one pod once (backoffLimit 0, no failure or success policy), with activeDeadlineSeconds up to ${local.cloud_pg_task.max_deadline} and ttlSecondsAfterFinished up to ${local.cloud_pg_task.max_ttl}"
            reason     = "Forbidden"
          },
          {
            expression = "(has(variables.pod.restartPolicy) && variables.pod.restartPolicy == 'Never' && has(variables.pod.automountServiceAccountToken) && variables.pod.automountServiceAccountToken == false && (!has(variables.pod.serviceAccountName) || variables.pod.serviceAccountName == 'default') && (!has(variables.pod.hostNetwork) || !variables.pod.hostNetwork) && (!has(variables.pod.hostPID) || !variables.pod.hostPID) && (!has(variables.pod.hostIPC) || !variables.pod.hostIPC) && !has(variables.pod.initContainers) && !has(variables.pod.ephemeralContainers) && !has(variables.pod.nodeName) && has(variables.pod.securityContext) && has(variables.pod.securityContext.runAsNonRoot) && variables.pod.securityContext.runAsNonRoot && has(variables.pod.securityContext.runAsUser) && variables.pod.securityContext.runAsUser == ${local.cloud_pg_task.uid})"
            message    = "in ${local.cloud_namespace}, a Postgres task pod sets restartPolicy Never, mounts no service account token, runs as uid ${local.cloud_pg_task.uid} with runAsNonRoot, and has no host namespaces, init containers or nodeName"
            reason     = "Forbidden"
          },
          {
            expression = "(size(variables.pod.containers) == 1 && variables.pod.containers.all(c, c.name == '${local.cloud_pg_task.container}' && c.image == '${local.cloud_pg_task.image}' && has(c.command) && size(c.command) >= 4 && size(c.command) <= ${local.cloud_pg_task.max_command} && c.command[0] == '/bin/bash' && c.command[1] == '-c' && size(c.command[2]) <= ${local.cloud_pg_task.max_script_len} && c.command[3] == 'pg-task' && (!has(c.args) || size(c.args) == 0) && !has(c.lifecycle) && has(c.securityContext) && has(c.securityContext.allowPrivilegeEscalation) && c.securityContext.allowPrivilegeEscalation == false && has(c.securityContext.readOnlyRootFilesystem) && c.securityContext.readOnlyRootFilesystem && (!has(c.securityContext.privileged) || !c.securityContext.privileged) && has(c.securityContext.capabilities) && has(c.securityContext.capabilities.drop) && 'ALL' in c.securityContext.capabilities.drop && !has(c.securityContext.capabilities.add)))"
            message    = "in ${local.cloud_namespace}, a Postgres task pod has one container ${local.cloud_pg_task.container} running ${local.cloud_pg_task.image} with /bin/bash -c and a task script, no privilege escalation, a read-only root and every capability dropped"
            reason     = "Forbidden"
          },
          {
            expression = "variables.pod.containers.all(c, (!has(c.ports) || size(c.ports) == 0 || (variables.component == 'pg-export' && c.ports.all(p, p.containerPort == ${local.cloud_pg_task.export_port} && !has(p.hostPort)))) && (!has(c.env) || c.env.all(e, !has(e.valueFrom))) && (!has(c.envFrom) || size(c.envFrom) == 0 || (variables.component != 'pg-backups' && size(c.envFrom) == 1 && has(c.envFrom[0].secretRef) && c.envFrom[0].secretRef.name == 'pg-task-' + object.metadata.name.substring(size(object.metadata.name) - 9) && !has(c.envFrom[0].prefix))))"
            message    = "in ${local.cloud_namespace}, a Postgres task pod listens only for an export, on ${local.cloud_pg_task.export_port}, and reads its credentials only from its own Secret pg-task-<the Job's 9 hex digits>"
            reason     = "Forbidden"
          },
          {
            expression = "(!has(variables.pod.volumes) || variables.pod.volumes.all(v, (has(v.emptyDir) && has(v.emptyDir.sizeLimit)) || (has(v.persistentVolumeClaim) && ((v.persistentVolumeClaim.claimName == '${local.cloud_pg_task.nightly_claim}' && variables.component in ['pg-backups', 'pg-restore'] && has(v.persistentVolumeClaim.readOnly) && v.persistentVolumeClaim.readOnly) || (v.persistentVolumeClaim.claimName == '${local.cloud_pg_task.manual_claim}' && variables.component != 'pg-export' && ((has(v.persistentVolumeClaim.readOnly) && v.persistentVolumeClaim.readOnly) || variables.component == 'pg-backup'))))))"
            message    = "in ${local.cloud_namespace}, a Postgres task pod may use only bounded emptyDirs, ${local.cloud_pg_task.nightly_claim} read-only (a list or a restore) and ${local.cloud_pg_task.manual_claim} (read-only unless it is a backup)"
            reason     = "Forbidden"
          },
          {
            expression = "variables.pod.containers.all(c, !has(c.volumeMounts) || c.volumeMounts.all(m, (!has(m.subPath) || m.subPath == '') && (!has(m.subPathExpr) || m.subPathExpr == '') && has(variables.pod.volumes) && variables.pod.volumes.exists(v, v.name == m.name && (!has(v.persistentVolumeClaim) || (has(m.readOnly) && m.readOnly) || (variables.component == 'pg-backup' && v.persistentVolumeClaim.claimName == '${local.cloud_pg_task.manual_claim}')))))"
            message    = "in ${local.cloud_namespace}, a Postgres task pod mounts the dump directories read-only, but for a backup's manual one, and with no subPath"
            reason     = "Forbidden"
          },
        ]
      }
    }
    console_exec_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-console-exec" }
      spec = {
        policyName        = "cloud-console-exec"
        validationActions = ["Deny"]
      }
    }
    pg_task_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-pg-task" }
      spec = {
        policyName        = "cloud-pg-task"
        validationActions = ["Deny"]
        matchResources = {
          namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = local.cloud_namespace } }
        }
      }
    }
    # The Secret of a Postgres task: the Project role's credentials, owned by
    # its Job so that Kubernetes deletes it with the Job.
    pg_task_secret = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-pg-task-secret" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [
            { apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["secrets"] },
          ]
        }
        matchConditions = [{
          name       = "is-cloud-reconciler"
          expression = "request.userInfo.username == '${local.cloud_reconciler_user}'"
        }]
        variables = [
          { name = "owners", expression = "has(object.metadata.ownerReferences) ? object.metadata.ownerReferences : []" },
        ]
        validations = [
          {
            expression = "(request.operation == 'CREATE' && object.metadata.name.matches('${local.cloud_pg_task.secret_re}') && has(object.type) && object.type == 'Opaque' && size(variables.owners) == 1 && variables.owners.all(o, o.apiVersion == 'batch/v1' && o.kind == 'Job' && has(o.controller) && o.controller && o.name.matches('${local.cloud_pg_task.name_re}') && o.name.endsWith('-' + object.metadata.name.substring(8))) && (!has(object.data) || object.data.all(k, k in ${jsonencode(local.cloud_pg_task.secret_keys)})) && (!has(object.stringData) || object.stringData.all(k, k in ${jsonencode(local.cloud_pg_task.secret_keys)})))"
            message    = "in ${local.cloud_namespace}, cloud-reconciler creates only Secrets pg-task-<9 hex digits> of type Opaque, owned by their Postgres task Job, holding only ${join(", ", local.cloud_pg_task.secret_keys)}"
            reason     = "Forbidden"
          },
        ]
      }
    }
    pg_task_secret_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-pg-task-secret" }
      spec = {
        policyName        = "cloud-pg-task-secret"
        validationActions = ["Deny"]
        matchResources = {
          namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = local.cloud_namespace } }
        }
      }
    }
    # Cron Services (the cloud repo's B19). Every pod rule applies to the
    # Job template's pod, so a CronJob the reconciler writes fails at apply
    # time, not at its first run. Its pod is component cron: never an App,
    # edge or oauth2-proxy pod, and no init container (a cron runs no
    # migrations). The deadline caps how long one run may hold its quota, 12
    # hours at most.
    managed_cronjob = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-cronjob" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["batch"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["cronjobs"]
          }]
        }
        variables = [for v in local.cloud_pod_variables : { name = v.name, expression = replace(v.expression, "@M", "object.spec.jobTemplate.spec.template.metadata") }]
        validations = concat([for r in local.cloud_pod_rules : {
          expression = replace(r.expression, "@S", "object.spec.jobTemplate.spec.template.spec")
          message    = r.message
          reason     = "Forbidden"
          }], [
          {
            expression = "variables.component == 'cron'"
            message    = "in a Cloud namespace, a CronJob's pod is labelled ${local.cloud_component_label} cron"
            reason     = "Forbidden"
          },
          {
            expression = "!has(object.spec.jobTemplate.spec.template.spec.initContainers) || size(object.spec.jobTemplate.spec.template.spec.initContainers) == 0"
            message    = "in a Cloud namespace, a CronJob's pod has no init container"
            reason     = "Forbidden"
          },
          {
            expression = "has(object.spec.jobTemplate.spec.template.spec.restartPolicy) && object.spec.jobTemplate.spec.template.spec.restartPolicy in ['Never', 'OnFailure']"
            message    = "in a Cloud namespace, a CronJob's pod sets restartPolicy Never or OnFailure"
            reason     = "Forbidden"
          },
          {
            expression = "has(object.spec.jobTemplate.spec.activeDeadlineSeconds) && object.spec.jobTemplate.spec.activeDeadlineSeconds <= ${local.cloud_job_max_deadline_seconds}"
            message    = "in a Cloud namespace, a CronJob's Job sets activeDeadlineSeconds, at most ${local.cloud_job_max_deadline_seconds}"
            reason     = "Forbidden"
          },
        ])
      }
    }
    managed_cronjob_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-cronjob" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-cronjob" })
    }
    # The Jobs of a cron Service: the CronJob controller's scheduled runs and
    # the reconciler's manual runs, both component cron. Any other Job is
    # cloud-managed-job's, which skips component cron. CREATE only: a Job's
    # pod template cannot change after it is created, the reconciler may not
    # update a Job, and the garbage collector updates ownerReferences when
    # it orphans one.
    managed_cron_job = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "cloud-managed-cron-job" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["batch"]
            apiVersions = ["v1"]
            operations  = ["CREATE"]
            resources   = ["jobs"]
          }]
        }
        matchConditions = [{
          name       = "is-cron-job"
          expression = "has(object.spec.template.metadata) && has(object.spec.template.metadata.labels) && '${local.cloud_component_label}' in object.spec.template.metadata.labels && object.spec.template.metadata.labels['${local.cloud_component_label}'] == 'cron'"
        }]
        variables = [for v in local.cloud_pod_variables : { name = v.name, expression = replace(v.expression, "@M", "object.spec.template.metadata") }]
        validations = concat([for r in local.cloud_pod_rules : {
          expression = replace(r.expression, "@S", "object.spec.template.spec")
          message    = r.message
          reason     = "Forbidden"
          }], [
          {
            expression = "!has(object.spec.template.spec.initContainers) || size(object.spec.template.spec.initContainers) == 0"
            message    = "in a Cloud namespace, a cron Job's pod has no init container"
            reason     = "Forbidden"
          },
          {
            expression = "has(object.spec.template.spec.restartPolicy) && object.spec.template.spec.restartPolicy in ['Never', 'OnFailure']"
            message    = "in a Cloud namespace, a cron Job's pod sets restartPolicy Never or OnFailure"
            reason     = "Forbidden"
          },
          {
            expression = "has(object.spec.activeDeadlineSeconds) && object.spec.activeDeadlineSeconds <= ${local.cloud_job_max_deadline_seconds}"
            message    = "in a Cloud namespace, a cron Job sets activeDeadlineSeconds, at most ${local.cloud_job_max_deadline_seconds}"
            reason     = "Forbidden"
          },
          {
            # A service name is a DNS label, so it holds no regex
            # metacharacter.
            expression = "variables.service.matches('^[a-z0-9]([a-z0-9-]*[a-z0-9])?$') && has(object.metadata.ownerReferences) && size(object.metadata.ownerReferences) == 1 && object.metadata.ownerReferences.all(o, o.apiVersion == 'batch/v1' && o.kind == 'CronJob' && o.name == 'cron-' + variables.service) && object.metadata.name.matches('^cron-' + variables.service + '-m?[0-9]+$')"
            message    = "in a Cloud namespace, a cron Job is owned by CronJob cron-<its service> alone and named cron-<service>-<digits> or cron-<service>-m<digits>"
            reason     = "Forbidden"
          },
        ])
      }
    }
    managed_cron_job_binding = {
      apiVersion = "admissionregistration.k8s.io/v1"
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "cloud-managed-cron-job" }
      spec       = merge(local.cloud_managed_binding, { policyName = "cloud-managed-cron-job" })
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

  # The live host guard (Kyverno ValidatingPolicy cloud-ingress-live-hosts,
  # applied by main.tf). cloud-managed-ingress knows only the hosts that were
  # routed when this stack was last applied. A homelab host added after that
  # is missing from it until the next apply, and a stolen reconciler token
  # could claim it in the meantime. This policy asks the API server at
  # admission time instead: it refuses an Ingress in a managed namespace when
  # one of its rule or TLS hosts is also a host of an Ingress, or appears in
  # a Host(`...`) match of an IngressRoute, in any namespace not labelled
  # managed. A ValidatingAdmissionPolicy cannot list objects, so Kyverno runs
  # it. Its own namespace is managed, so updating an Ingress never clashes
  # with itself. HostRegexp hosts cannot be compared, as in taken_hosts.tf.
  #
  # failurePolicy Fail: if a lookup fails, the write is refused. While the
  # Kyverno chart runs with features.forceFailurePolicyIgnore
  # (stacks/kyverno), Kyverno treats every policy as Ignore, this one too,
  # so a failed lookup or an unavailable Kyverno admits the Ingress; then
  # cloud-managed-ingress, which needs nothing at runtime, is the only
  # layer. docs/agents/security.md, "Live host guard".
  cloud_live_host_guard_name = "cloud-ingress-live-hosts"
  cloud_live_host_guard = {
    apiVersion = "policies.kyverno.io/v1"
    kind       = "ValidatingPolicy"
    metadata = {
      name = local.cloud_live_host_guard_name
      annotations = {
        "policies.kyverno.io/title"       = "Cloud: no homelab host in a Project Ingress"
        "policies.kyverno.io/category"    = "Cloud"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "In namespaces labelled ${local.cloud_managed_label}=true, refuse an Ingress whose host is routed by an Ingress or IngressRoute outside those namespaces, looked up at admission time (stacks/cloud access_rules.tf)."
      }
    }
    spec = {
      validationActions = ["Deny"]
      failurePolicy     = "Fail"
      # Admission only. Background scans are off on this cluster, and each
      # evaluation lists every Ingress and IngressRoute.
      evaluation = { background = { enabled = false } }
      matchConstraints = {
        resourceRules = [{
          apiGroups   = ["networking.k8s.io"]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["ingresses"]
        }]
        namespaceSelector = { matchLabels = { (local.cloud_managed_label) = "true" } }
      }
      variables = [
        {
          name       = "managedNamespaces"
          expression = "dyn(resource.List('v1', 'namespaces', '').items).filter(n, '${local.cloud_managed_label}' in n.metadata.?labels.orValue({}) && n.metadata.labels['${local.cloud_managed_label}'] == 'true').map(n, n.metadata.name)"
        },
        {
          name       = "requested"
          expression = "(object.spec.?rules.orValue([]).filter(r, has(r.host)).map(r, r.host) + object.spec.?tls.orValue([]).map(t, t.?hosts.orValue([])).flatten()).map(h, h.lowerAscii())"
        },
        {
          name       = "ingressHosts"
          expression = "dyn(resource.List('networking.k8s.io/v1', 'ingresses', '').items).filter(i, !(i.metadata.namespace in variables.managedNamespaces)).map(i, i.spec.?rules.orValue([]).filter(r, has(r.host)).map(r, r.host) + i.spec.?tls.orValue([]).map(t, t.?hosts.orValue([])).flatten()).flatten().map(h, h.lowerAscii())"
        },
        {
          # Host(`a`) and Host(`a`, `b`) in each route's match, as in
          # taken_hosts.tf.
          name       = "routeHosts"
          expression = "dyn(resource.List('traefik.io/v1alpha1', 'ingressroutes', '').items).filter(r, !(r.metadata.namespace in variables.managedNamespaces)).map(r, r.spec.?routes.orValue([]).map(rt, rt.?match.orValue('').findAll('Host[(][^)]*[)]').map(c, c.findAll('`[^`]+`')).flatten()).flatten()).flatten().map(q, q.replace('`', '').lowerAscii())"
        },
        {
          name       = "taken"
          expression = "variables.requested.filter(h, h in variables.ingressHosts || h in variables.routeHosts)"
        },
      ]
      validations = [{
        expression        = "size(variables.taken) == 0"
        message           = "in a Cloud namespace, an Ingress may not use a host the homelab routes"
        messageExpression = "'in a Cloud namespace, an Ingress may not use a host the homelab routes now: ' + variables.taken.join(', ')"
      }]
    }
  }

  # Kyverno's admission controller runs the lookups above with its own
  # service account. The chart binds it to `view`, which covers Ingresses,
  # and its core role reads namespaces; neither covers Traefik's CRDs. The
  # chart's ClusterRole kyverno:admission-controller aggregates every
  # ClusterRole with this label (Kyverno docs, "Customizing permissions").
  cloud_live_host_guard_kyverno_role = {
    name   = "kyverno:admission-controller:cloud-ingressroutes"
    labels = { "rbac.kyverno.io/aggregate-to-admission-controller" = "true" }
    rules = [
      { api_groups = ["traefik.io"], resources = ["ingressroutes"], verbs = ["get", "list", "watch"], resource_names = [] },
    ]
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
