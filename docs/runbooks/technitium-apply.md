# Runbook: Applying the Technitium Terraform stack

Last updated: 2026-04-19

The `stacks/technitium/` apply has a **post-apply readiness gate** that asserts all three DNS instances are healthy before the apply is allowed to finish. This runbook explains what it checks, how to interpret failures, and how to override it for emergency maintenance.

## What the gate checks

`stacks/technitium/modules/technitium/readiness.tf` defines `null_resource.technitium_readiness_gate`. It runs after the three Technitium deployments, the DNS LoadBalancer service, and the PDB are applied, and performs:

1. **Rollout status** — `kubectl rollout status deploy/<name> --timeout=180s` for `technitium`, `technitium-secondary`, `technitium-tertiary`. Fails if any deployment has not reached its desired pod count within 180s.
2. **Per-pod API health** — for every pod with label `dns-server=true`, executes `wget http://127.0.0.1:5380/api/stats/get` inside the pod and asserts the response contains `"status":"ok"`. Catches Technitium process hangs that TCP probes miss.
3. **Zone-count parity** — queries `technitium-web`, `technitium-secondary-web`, `technitium-tertiary-web` and counts the zones returned. Fails if the three counts differ, which would mean `technitium-zone-sync` has drifted or a replica has lost state.

The gate is re-run whenever any of the deployment container spec, the CoreDNS Corefile, or the apply timestamp changes (see `triggers` in `readiness.tf`).

## Emergency override

Set `skip_readiness=true` via terragrunt inputs or pass it directly to the Terraform apply:

```bash
cd infra/stacks/technitium
scripts/tg apply -var skip_readiness=true
```

Only use this when you need to land a Terraform change while one Technitium instance is intentionally offline (e.g., you are replacing its PVC, migrating storage, or recovering a corrupted config DB). Re-apply without the flag once the instance is back.

You can also target around the gate during emergency work:

```bash
scripts/tg apply -target=kubernetes_config_map.coredns
```

`-target` bypasses the `depends_on` chain feeding the gate, so a single-resource push does not need the gate to pass.

## Failure modes and responses

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `rollout status` times out on one deployment | Pod stuck `Pending` (node pressure / anti-affinity with other dns-server pods) or `ImagePullBackOff` | `kubectl describe pod` for events. If anti-affinity is blocking, confirm 3 nodes are Ready. |
| API check fails on a pod but readiness probe passes | Technitium process hung but port 53 still accepting TCP (liveness probe is `tcp_socket` on :53) | `kubectl delete pod <name>` — deployment will recreate it. |
| Zone count differs between instances | `technitium-zone-sync` CronJob is failing or AXFR is blocked | `kubectl logs -n technitium -l job-name=<latest-zone-sync-job>`. Check `TechnitiumZoneSyncFailed` alert. |
| Gate passes but external clients still cannot resolve | Gate only checks in-pod API and intra-cluster zone parity — external path (LoadBalancer → Technitium pod) is not tested | Run the LAN-client drill in `docs/architecture/dns.md` troubleshooting section. |

## What the gate does NOT check

- External reachability through the LoadBalancer IP `10.0.20.201` (that would require a LAN-side probe).
- CoreDNS health (CoreDNS is patched by `coredns.tf`, not this module's deployments — alerts `CoreDNSErrors` / `CoreDNSForwardFailureRate` catch regressions post-apply).
- Upstream resolver health (covered by `CoreDNSForwardFailureRate`).

For broader end-to-end verification, see `docs/architecture/dns.md` → "Verification" section, or run the Uptime Kuma external DNS probe.
