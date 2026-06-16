# One-shot adoption of two alert-digest resources that exist in-cluster but fell
# out of Terraform state — the monitoring apply was create-failing on every push
# with `configmaps "alert-digest-script" already exists` and `secrets
# "alert-digest" already exists` (pre-existing: pipelines 203 AND 204). Importing
# reconciles them into state so `terraform apply` UPDATES instead of failing to
# create. These blocks are idempotent (a no-op once the resources are in state)
# and may be removed after the next green apply. Defs: modules/monitoring/alert_digest.tf.
import {
  to = module.monitoring.kubernetes_config_map.alert_digest_script
  id = "monitoring/alert-digest-script"
}

import {
  to = module.monitoring.kubernetes_secret.alert_digest
  id = "monitoring/alert-digest"
}
