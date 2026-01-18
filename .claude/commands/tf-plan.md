# Terraform Plan

Run terraform plan to preview infrastructure changes via the remote executor.

Use the remote executor relay:
```bash
echo "terraform plan -target=module.kubernetes_cluster.module.<service>" > /System/Volumes/Data/mnt/code/infra/.claude/cmd_input.txt
sleep 2 && cat /System/Volumes/Data/mnt/code/infra/.claude/cmd_status.txt
# Wait for done:N status, then read output
cat /System/Volumes/Data/mnt/code/infra/.claude/cmd_output.txt
```

ALWAYS use -target to speed up execution. Summarize the planned changes, highlighting any resources being destroyed or recreated.
