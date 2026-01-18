# Kubectl Command

Run kubectl commands on the cluster via the remote executor.

Use the remote executor relay:
```bash
echo "kubectl $ARGUMENTS" > /System/Volumes/Data/mnt/code/infra/.claude/cmd_input.txt
sleep 2 && cat /System/Volumes/Data/mnt/code/infra/.claude/cmd_status.txt
cat /System/Volumes/Data/mnt/code/infra/.claude/cmd_output.txt
```

Examples:
- `/kubectl get pods -A` - List all pods
- `/kubectl get pods -n immich` - List pods in immich namespace
- `/kubectl logs -n immich deploy/immich-server` - View logs
- `/kubectl describe pod -n monitoring <pod>` - Describe a pod
