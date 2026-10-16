# One-shot adoption of the pg-custom-queries ConfigMap
# (modules/dbaas/main.tf, kubernetes_config_map.pg_custom_queries). CI pipeline
# #2587 created it on 2026-10-16 and was then killed before its push step, so
# the dbaas state commit holding it never reached master. Without this block
# the next apply fails with `configmaps "pg-custom-queries" already exists`.
# Idempotent once the ConfigMap is in state; remove after the next green apply.
import {
  to = module.dbaas.kubernetes_config_map.pg_custom_queries
  id = "dbaas/pg-custom-queries"
}
