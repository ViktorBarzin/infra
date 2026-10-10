# Trivy Operator runbook

Architecture: `docs/architecture/trivy.md`. Stack: `stacks/trivy-operator`.

## Read the findings

```sh
# Vulnerability summary per workload container (Critical/High only are stored)
kubectl get vulnerabilityreports -A -o wide

# Fixable Critical/High CVEs in one namespace, with the fixed version
kubectl get vulnerabilityreports -n <ns> -o json | jq -r '
  .items[] | .metadata.labels["trivy-operator.resource.name"] as $w
  | .report.vulnerabilities[] | select(.fixedVersion != "")
  | [$w, .severity, .vulnerabilityID, .resource, .installedVersion, .fixedVersion] | @tsv'

# Secrets found in images
kubectl get exposedsecretreports -A -o wide

# Config audit, RBAC, node assessment, compliance
kubectl get configauditreports -A -o wide
kubectl get rbacassessmentreports,clusterrbacassessmentreports -A -o wide
kubectl get infraassessmentreports -A -o wide
kubectl get clustercompliancereports
```

## Force a rescan

Reports expire after 24h and are rescanned automatically. To rescan one workload now, delete its report; the operator queues a new scan job:

```sh
kubectl -n <ns> delete vulnerabilityreport <report-name>
```

Deleting a report is a transient action on operator-owned output, not configuration. Do not bulk-delete every report: each rescan queues behind the 3-job concurrency limit and the first pass over the whole cluster takes hours.

## Scan jobs fail

```sh
kubectl -n trivy-system get jobs,pods
kubectl -n trivy-system logs deploy/trivy-operator --since=30m | grep -i error
homelab logs query '{namespace="trivy-system"} |= "error"' --since 6h
```

| Symptom | Likely cause | What to do |
|---|---|---|
| Job pods rejected at admission | Kyverno: an image outside `mirror.gcr.io/aquasec/*`, or a node-collector name the PolicyException does not match | Check the operator's events (`kubectl -n trivy-system get events`). Fix the allowlist or exception in `stacks/kyverno/modules/kyverno/security-policies.tf`. |
| `OOMKilled` scan pods | A very large image | Raise `trivy.resources.limits.memory` in `stacks/trivy-operator/main.tf`. |
| `DeadlineExceeded` on first scans | Layer download from the cache took longer than `scanJobTimeout` | Raise `operator.scanJobTimeout` and `trivy.timeout` together. |
| `toomanyrequests` in scan logs | A Docker Hub image the pull-through cache could not serve, so Trivy fell back to Docker Hub | Check the cache (`docs/architecture/networking.md`, registry VM 10.0.20.10). |
| `failed to connect to trivy server` | trivy-server not Ready (DB download on start) | `kubectl -n trivy-system logs sts/trivy-server`. It retries; the operator retries the job after 30s. |

## Node-collector

One Job per node, named `node-collector-<hash>`, at most one running at a time. It needs hostPID, granted only by PolicyException `kyverno/trivy-node-collector-hostpid`. If node assessments stop appearing, check that the exception still exists and that `--enablePolicyException=true` is set on the Kyverno admission controller.

## Pause scanning

Set `operator.vulnerabilityScannerEnabled` (and the other scanner flags) to `false` in `stacks/trivy-operator/main.tf` and land it. Existing reports stay until their TTL expires.
