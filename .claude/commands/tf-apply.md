# Terraform Apply

Run terraform apply to deploy infrastructure changes via SSH.

```bash
ssh wizard@10.0.10.10 "cd /home/wizard/code/infra && terraform apply -auto-approve"
```

Monitor the output and report any errors or successful completions.
