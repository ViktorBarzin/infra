# One-shot adoption of the live tasks-stack resources that exist in-cluster but
# were never persisted to Terraform state: pipeline 477 (2026-07-03, the stack's
# first apply) died mid-`[tasks] apply` — after creating the resources, before
# the pg backend write — so `tasks.states` stayed empty and every later apply
# would create-fail with `namespaces "tasks" already exists` (same class as the
# monitoring alert-digest adoption in stacks/monitoring/imports.tf). Importing
# reconciles them into state so `terraform apply` UPDATES instead of failing to
# create. These blocks are idempotent (a no-op once the resources are in state)
# and may be removed after the next green apply. Defs: main.tf.
# (module.ingress_icons is deliberately NOT here — it does not exist live yet;
# the same apply creates it.)

import {
  to = kubernetes_namespace.tasks
  id = "tasks"
}

import {
  to = kubernetes_manifest.external_secret
  id = "apiVersion=external-secrets.io/v1,kind=ExternalSecret,namespace=tasks,name=tasks-secrets"
}

import {
  to = kubernetes_manifest.db_external_secret
  id = "apiVersion=external-secrets.io/v1,kind=ExternalSecret,namespace=tasks,name=tasks-db-creds"
}

import {
  to = kubernetes_deployment.tasks
  id = "tasks/tasks"
}

import {
  to = kubernetes_service.tasks
  id = "tasks/tasks"
}

import {
  to = kubernetes_network_policy_v1.tasks_ingress
  id = "tasks/tasks-ingress"
}

import {
  to = module.ingress.kubernetes_ingress_v1.proxied-ingress
  id = "tasks/tasks"
}

# Cloudflare record ID looked up via the API (zone fd2c5dd4… / record for
# tasks.viktorbarzin.me, CNAME → the cfargotunnel target, proxied).
import {
  to = module.ingress.cloudflare_record.proxied[0]
  id = "fd2c5dd4efe8fe38958944e74d0ced6d/a8e6901a074c5255d09700d93eaaf705"
}
