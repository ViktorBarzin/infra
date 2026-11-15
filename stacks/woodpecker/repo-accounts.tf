# Each pipeline runs with the rights of its own repo (enforced-identity plan,
# docs/plans/2026-11-15-enforced-identity-design.md, step 4).
#
# Before 2026-11-15 every step pod ran as `default`, bound to cluster-admin,
# and the Vault `ci` role (ci-vault-admin) trusted that account. So a pipeline
# in any of the 49 Woodpecker repos was cluster and Vault admin.
#
# Woodpecker stamps each step pod with its repo (label
# woodpecker-ci.org/repo-id) and drops any label under that prefix that a
# pipeline sets itself (pipeline/frontend/builder/builder.go, v3.19.0), so the
# label can be trusted. The MutatingPolicy below reads it at pod admission and
# sets the pod's ServiceAccount:
#   - infra (repo 1): ci-infra, cluster-admin and the Vault `ci` role, which
#     its terragrunt applies need;
#   - an app repo that deploys: ci-deploy-<namespace>, which may set an image,
#     watch the rollout and run a smoke Job in that one namespace;
#   - every other repo: `default`, which has no rights.
# A pipeline cannot pick its own account: the agent leaves
# WOODPECKER_BACKEND_K8S_SERVICE_ACCOUNT_NAME_ALLOW_FROM_STEP at false. The
# policy fails open to `default`, so a Kyverno outage costs rights, not safety.

locals {
  # Woodpecker repo id -> the namespace its deploy pipeline changes. Read from
  # each repo's .woodpecker/deploy.yml on 2026-11-15 (`kubectl -n <ns>`),
  # leaving out instagram-poster and hermes-agent, whose namespaces are gone. The
  # GitHub and Forgejo registrations of one repo have different ids.
  ci_deploy_repos = {
    "2"   = "website"                  # ViktorBarzin/Website
    "4"   = "health"                   # ViktorBarzin/health
    "6"   = "webhook-handler"          # ViktorBarzin/webhook-handler
    "77"  = "claude-memory"            # viktor/claude-memory
    "78"  = "claude-memory"            # ViktorBarzin/claude-memory-mcp
    "121" = "broker-sync"              # ViktorBarzin/broker-sync
    "156" = "beads-server"             # viktor/beadboard
    "157" = "broker-sync"              # viktor/broker-sync
    "158" = "claude-memory"            # viktor/claude-memory-mcp
    "160" = "claude-agent"             # viktor/claude-agent-service
    "167" = "tripit"                   # ViktorBarzin/tripit
    "200" = "job-hunter"               # ViktorBarzin/job-hunter
    "201" = "tuya-bridge"              # ViktorBarzin/tuya_bridge
    "202" = "freedify"                 # ViktorBarzin/freedify
    "203" = "kms"                      # ViktorBarzin/kms-website
    "204" = "beads-server"             # ViktorBarzin/beadboard
    "205" = "payslip-ingest"           # ViktorBarzin/payslip-ingest
    "207" = "nextcloud-todos"          # ViktorBarzin/nextcloud-todos
    "208" = "fire-planner"             # ViktorBarzin/fire-planner
    "209" = "recruiter-responder"      # ViktorBarzin/recruiter-responder
    "210" = "claude-agent"             # ViktorBarzin/claude-agent-service
    "211" = "traefik"                  # ViktorBarzin/x402-gateway
    "278" = "vpn-portal"               # ViktorBarzin/vpn-portal
    "279" = "lesson-harvester"         # ViktorBarzin/lesson-harvester
    "312" = "stremio"                  # ViktorBarzin/stremio-nvenc
    "345" = "offline-reader"           # ViktorBarzin/offline-reader
    "378" = "goldmane-edge-aggregator" # ViktorBarzin/goldmane-edge-aggregator
    "411" = "browser-bridge"           # ViktorBarzin/browser-bridge
    "444" = "crowdsec"                 # ViktorBarzin/crowdsec_web
    "445" = "wa-bot"                   # ViktorBarzin/wa-bot
    "478" = "alexa-assistant"          # ViktorBarzin/alexa-assistant
    "511" = "reels"                    # ViktorBarzin/trip-reel
    "512" = "cloud"                    # ViktorBarzin/cloud
  }
  ci_deploy_namespaces = toset(values(local.ci_deploy_repos))

  ci_repo_accounts = merge(
    { for id, ns in local.ci_deploy_repos : id => "ci-deploy-${ns}" },
    { "1" = kubernetes_service_account.ci_infra.metadata[0].name }, # ViktorBarzin/infra
  )
}

# `default` keeps no binding (the woodpecker-default ClusterRoleBinding to
# cluster-admin was removed), so its token reaches nothing.

resource "kubernetes_service_account" "ci_infra" {
  metadata {
    name      = "ci-infra"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
}

# The infra pipelines apply every stack, so they stay cluster-admin, but only
# for the one repo whose master only Viktor and the bots can push
# (stacks/forgejo-acl).
resource "kubernetes_cluster_role_binding" "ci_infra" {
  metadata {
    name = "woodpecker-ci-infra"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ci_infra.metadata[0].name
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  role_ref {
    kind      = "ClusterRole"
    name      = "cluster-admin"
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_service_account" "ci_deploy" {
  for_each = local.ci_deploy_namespaces
  metadata {
    name      = "ci-deploy-${each.value}"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
}

# What the deploy pipelines run, counted on 2026-11-15: `set image` (44),
# `rollout status` (35), `get deployment`, and broker-sync's smoke Job
# (create, wait, logs, delete).
resource "kubernetes_cluster_role" "ci_deployer" {
  metadata {
    name = "woodpecker-ci-deployer"
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "patch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "events"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding" "ci_deploy" {
  for_each = local.ci_deploy_namespaces
  metadata {
    name      = "woodpecker-ci-deploy"
    namespace = each.value
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ci_deploy[each.value].metadata[0].name
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  role_ref {
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.ci_deployer.metadata[0].name
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubectl_manifest" "ci_repo_accounts" {
  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata = {
      name = "woodpecker-repo-service-account"
      annotations = {
        "policies.kyverno.io/title"       = "Woodpecker repo ServiceAccount"
        "policies.kyverno.io/description" = "Run each Woodpecker step pod as its repo's ServiceAccount (stacks/woodpecker/repo-accounts.tf)."
      }
    }
    spec = {
      failurePolicy = "Ignore"
      autogen       = { podControllers = { controllers = [] } }
      matchConstraints = {
        namespaceSelector = {
          matchLabels = { "kubernetes.io/metadata.name" = kubernetes_namespace.woodpecker.metadata[0].name }
        }
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE"]
          resources   = ["pods"]
        }]
      }
      variables = [{
        name       = "accounts"
        expression = jsonencode(local.ci_repo_accounts)
      }]
      matchConditions = [{
        name       = "known-repo"
        expression = "has(object.metadata.labels) && 'woodpecker-ci.org/repo-id' in object.metadata.labels && object.metadata.labels['woodpecker-ci.org/repo-id'] in ${jsonencode(local.ci_repo_accounts)}"
      }]
      mutations = [{
        patchType = "ApplyConfiguration"
        applyConfiguration = {
          expression = "Object{spec: Object.spec{serviceAccountName: variables.accounts[object.metadata.labels['woodpecker-ci.org/repo-id']]}}"
        }
      }]
    }
  })

  depends_on = [kubernetes_service_account.ci_deploy, kubernetes_service_account.ci_infra]
}
