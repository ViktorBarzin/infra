# Terraform Apply

Run terraform apply to deploy infrastructure changes via the remote executor.

Use the remote executor relay:
```bash
echo "terraform apply -target=module.kubernetes_cluster.module.<service> -auto-approve" > /System/Volumes/Data/mnt/code/infra/.claude/cmd_input.txt
sleep 2 && cat /System/Volumes/Data/mnt/code/infra/.claude/cmd_status.txt
# Wait for done:N status, then read output
cat /System/Volumes/Data/mnt/code/infra/.claude/cmd_output.txt
```

ALWAYS use -target to speed up execution. Monitor the output and report any errors or successful completions.
