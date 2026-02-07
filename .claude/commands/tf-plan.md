# Terraform Plan

Run terraform plan to preview infrastructure changes.

```bash
terraform plan -target=module.kubernetes_cluster.module.<service> -var="kube_config_path=$(pwd)/config"
```

ALWAYS use -target to speed up execution. Summarize the planned changes, highlighting any resources being destroyed or recreated.
