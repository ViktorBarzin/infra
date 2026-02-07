# Terraform Apply

Run terraform apply to deploy infrastructure changes.

```bash
terraform apply -target=module.kubernetes_cluster.module.<service> -auto-approve
```

ALWAYS use -target to speed up execution. Monitor the output and report any errors or successful completions.
