# Kubectl Command

Run kubectl commands on the cluster.

```bash
kubectl --kubeconfig $(pwd)/config $ARGUMENTS
```

Examples:
- `/kubectl get pods -A` - List all pods
- `/kubectl get pods -n immich` - List pods in immich namespace
- `/kubectl logs -n immich deploy/immich-server` - View logs
- `/kubectl describe pod -n monitoring <pod>` - Describe a pod
