# Kubectl Command

Run kubectl commands on the cluster via the `/remote` skill.

```
/remote kubectl $ARGUMENTS
```

Examples:
- `/kubectl get pods -A` - List all pods
- `/kubectl get pods -n immich` - List pods in immich namespace
- `/kubectl logs -n immich deploy/immich-server` - View logs
- `/kubectl describe pod -n monitoring <pod>` - Describe a pod
