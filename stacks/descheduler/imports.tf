# Adopt the live descheduler resources into (empty) Terraform state.
#
# The stack's PG-backend state is EMPTY while all five resources have been
# running in-cluster for ~180 days — the state was lost around the platform
# mega-stack split / local→PG state migration, and every apply since errored
# with "namespaces \"descheduler\" already exists" (GitHub issue
# ViktorBarzin/infra#68). Per AGENTS.md → "Adopting Existing Resources":
# commit stanzas → plan-to-zero → apply → delete stanzas.
#
# DELETE THIS FILE after the first successful apply.

import {
  to = kubernetes_namespace.descheduler
  id = "descheduler"
}

import {
  to = kubernetes_cluster_role.descheduler
  id = "descheduler-cluster-role"
}

import {
  to = kubernetes_service_account.descheduler
  id = "descheduler/descheduler-sa"
}

import {
  to = kubernetes_cluster_role_binding.descheduler
  id = "descheduler-cluster-role-binding"
}

import {
  to = helm_release.descheduler
  id = "descheduler/descheduler"
}
