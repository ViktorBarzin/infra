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
kubectl get clusterinfraassessmentreports        # one per node
kubectl get infraassessmentreports -A -o wide    # control-plane static pods
kubectl get clustercompliancereports
```

## Alerts

| Alert | First look |
|---|---|
| `TrivyFixableCVEInternetReachable` | Fixable CVEs in that namespace (query above). The fix is a newer image or chart; Renovate picks it up on its next run once released. Bump by hand if it is urgent. |
| `TrivyExposedSecretInImage` | `kubectl get exposedsecretreports -n <ns> -o json \| jq '.items[].report.secrets[] \| {ruleID, target, title}'`. A key inside a third-party library (for example yt-dlp's `extractor/*.py`) is usually a public value; add it to `trivy.ignoreFile` in `stacks/trivy-operator/main.tf` (see below), not an Alertmanager silence. A credential of ours means rotating it and rebuilding the image. |
| `TrivyMetricsAbsent` | `kubectl -n trivy-system get pods`; then check that `trivy_.+` is still on the keep allowlist in `prometheus_chart_values.tpl`. |

These alerts post at most once a day per alert (own Alertmanager route, `group_interval 24h`). The weekly digest section on Mondays covers everything that does not alert.

## Force a rescan

Reports expire after 72h and are rescanned automatically. To rescan one workload now, delete its report; the operator queues a new scan job. It starts within a minute when fewer than 2 scan Jobs are running; otherwise the operator retries after `scanJobsRetryDelay` (15 minutes):

```sh
kubectl -n <ns> delete vulnerabilityreport <report-name>
```

Deleting a report is a transient action on operator-owned output, not configuration. Do not bulk-delete every report: each rescan queues behind the 2-job concurrency limit and the first pass over the whole cluster takes hours.

## Suppress a false-positive secret

Image secrets that are confirmed not ours go in the `secrets` list of `trivy.ignoreFile` in `stacks/trivy-operator/main.tf`. The chart renders it into the `trivy-operator-trivy-config` ConfigMap as `.trivyignore.yaml`, and every scan Job mounts it at `/etc/trivy/.trivyignore.yaml` (`TRIVY_IGNOREFILE`). One entry:

```hcl
{
  id        = "aws-access-key-id"              # ruleID from the report
  paths     = ["/**/yt_dlp/extractor/shahid.py"] # doublestar glob on the report target
  statement = "Public AWS key ID embedded by the yt-dlp Shahid extractor."
}
```

Report targets start with `/`, so patterns need a leading `/` (or `/**/`). Keep the path as narrow as the finding allows, so the same rule elsewhere in the image still reports. After the apply, check the ConfigMap and rescan one affected workload:

```sh
kubectl -n trivy-system get cm trivy-operator-trivy-config -o jsonpath='{.data.trivy\.ignoreFile}'
kubectl -n <ns> delete exposedsecretreport <report-name>
# a minute or two later the new report has no entry for that path
kubectl -n <ns> get exposedsecretreports -o json | jq '.items[].report.secrets[] | {ruleID, target}'
```

Reports of other workloads pick up the change at their next scan (72h TTL at the latest).

## Completed one-shot Jobs stay scanned

Standalone Jobs (db-init, migrations, one-off exports) keep their reports for as long as the Job object exists, and the operator rescans them at every 72h TTL, even after they completed. Operator v0.35.0 skips only CronJob-owned Jobs; there is no setting for completed ones. Deleting the report does not help: the operator sees the missing report and scans the Job again at the next free scan slot (seen on 2026-10-19: a deleted report for the completed `broker-sync/imap-retry` Job came back 16 minutes later). Most of these Jobs are Terraform `kubernetes_job` resources, and adding `ttl_seconds_after_finished` to one would let Kubernetes delete it, after which the next apply recreates it and runs the job again. So they are left in place; the reports go when the Job object is deleted.

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
| `failed to connect to trivy server` | trivy-server not Ready (DB download on start) | `kubectl -n trivy-system logs sts/trivy-server`. It retries; the operator retries a failed scan after 15 minutes (`scanJobsRetryDelay`). |

## Node-collector

One Job per node, named `node-collector-<hash>`, at most one running at a time. It needs hostPID, granted only by PolicyException `kyverno/trivy-node-collector-hostpid`. If node assessments stop appearing, check that the exception still exists and that `--enablePolicyException=true` is set on the Kyverno admission controller.

## Pause scanning

Set `operator.vulnerabilityScannerEnabled` (and the other scanner flags) to `false` in `stacks/trivy-operator/main.tf` and land it. Existing reports stay until their TTL expires.
