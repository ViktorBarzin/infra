# Kubectl Command

Run kubectl commands on the cluster via SSH.

```bash
ssh wizard@10.0.10.10 "kubectl $ARGUMENTS"
```

Examples:
- `/kubectl get pods -A` - List all pods
- `/kubectl get pods -n immich` - List pods in immich namespace
- `/kubectl logs -n immich deploy/immich-server` - View logs
- `/kubectl describe pod -n monitoring <pod>` - Describe a pod
