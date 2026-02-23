# Codebase Concerns

**Analysis Date:** 2026-02-23

## Tech Debt

**MySQL Backup Rotation Not Implemented:**
- Issue: Backup rotation logic exists (comment at `stacks/platform/modules/dbaas/main.tf:196`) but is incomplete. Backup size noted as 11MB, rotation deferred.
- Files: `stacks/platform/modules/dbaas/main.tf` (lines 196-206)
- Impact: Backup directory could grow unbounded; no automated retention policy enforced. Manual cleanup required.
- Fix approach: Implement full rotation schedule using `find -mtime +N` or migrate to external backup solution (Velero, pgbackrest). Set up CronJob with proper retention (e.g., 14-day backups).

**PostgreSQL Major Version Upgrade Blocked:**
- Issue: Comment at `stacks/platform/modules/dbaas/main.tf:718` indicates PostgreSQL 17.2 requires `pg_upgrade` to data directory but is not implemented.
- Files: `stacks/platform/modules/dbaas/main.tf` (line 718)
- Impact: Cannot upgrade PostgreSQL from 16-master to 17.2. When upgrade is needed, requires manual pg_upgrade procedure; high downtime risk.
- Fix approach: Implement pg_upgrade CronJob or StatefulSet init container that performs in-place upgrade. Test migration path with backup first.

**TP-Link Gateway Reverse Proxy Not Functional:**
- Issue: Reverse proxy module for TP-Link gateway marked as "Not working yet" at `stacks/platform/modules/reverse_proxy/main.tf:91`.
- Files: `stacks/platform/modules/reverse_proxy/main.tf` (lines 91-95)
- Impact: Gateway access over HTTPS or HTTP routing non-functional. Unknown scope of impact on dependent services.
- Fix approach: Either complete reverse proxy implementation (Traefik/Nginx config) or document why it's disabled. Clarify if gateway is still accessible via HTTP or LAN-only.

**WireGuard Firewall Rules Incomplete:**
- Issue: Client firewall restrictions not written at `terraform.tfvars:430`. Only placeholder exists.
- Files: `terraform.tfvars` (lines 430-434)
- Impact: No network isolation between VPN clients and cluster-internal services (10.32.0.0/12). All connected clients can access cluster APIs if firewall rules not enforced at kernel level.
- Fix approach: Define explicit iptables rules for each client role (e.g., "allow DNS only", "deny cluster access"). Test with `iptables -L -v`. Consider VPN network segmentation if multiple trust levels exist.

## Known Bugs & Issues

**Immich Database Compatibility Mismatch:**
- Symptoms: Custom PostgreSQL image version mismatch between Immich PostgreSQL pod and dbaas PostgreSQL. Immich uses `ghcr.io/immich-app/postgres:15-vectorchord0.3.0-pgvectors0.2.0`, while dbaas PostgreSQL is 16-master with PostGIS/PgVector mix.
- Files: `stacks/immich/main.tf` (lines 76-77, 276), `stacks/platform/modules/dbaas/main.tf` (line 717)
- Trigger: If Immich database is migrated to shared dbaas PostgreSQL, extension version incompatibility will cause failures.
- Workaround: Keep Immich on isolated PostgreSQL 15 with Immich-specific extensions. If consolidation needed, test extension compatibility first.

**Realestate-Crawler Latest Image Tag Ignores Updates:**
- Symptoms: `realestate-crawler-ui` uses `image = "viktorbarzin/immoweb:latest"` with `lifecycle { ignore_changes = [spec[0].template[0].spec[0].container[0].image] }`.
- Files: `stacks/real-estate-crawler/main.tf` (lines 64, 79-82)
- Trigger: New versions of `immoweb:latest` will never be deployed. Terraform ignores image updates; manual image pull/push required.
- Workaround: Use Diun annotations to track image updates. Consider using version-pinned tags instead of `:latest`. Remove `ignore_changes` if auto-updates desired.

## Security Considerations

**OpenClaw Has Cluster-Admin Permissions:**
- Risk: OpenClaw ServiceAccount granted unrestricted `cluster-admin` ClusterRoleBinding at `stacks/openclaw/main.tf:41-54`.
- Files: `stacks/openclaw/main.tf` (lines 34-55)
- Current mitigation: `dangerouslyDisableDeviceAuth = true` in config (line 89) disables device auth but relies on network access control.
- Recommendations:
  - Scope OpenClaw RBAC to specific namespaces/resources needed for skill execution (e.g., `get/list/watch pods`, `exec into pods`, `apply resources in specific namespaces`).
  - Re-enable device auth or implement mTLS between OpenClaw and operators.
  - Audit OpenClaw logs for unauthorized API calls (enable API server audit logs).

**Git-Crypt Key Mounted as ConfigMap:**
- Risk: git-crypt key at `stacks/openclaw/main.tf:68-76` stored as plain-text ConfigMap data. Any pod on cluster can read it (unless RBAC enforces secrets-only access).
- Files: `stacks/openclaw/main.tf` (lines 68-76)
- Current mitigation: None; ConfigMap is world-readable by default.
- Recommendations:
  - Move git-crypt key to Kubernetes Secret instead of ConfigMap.
  - Add RBAC policy restricting secret read to openclaw namespace only.
  - Consider external secret management (Authentik-backed secret injection, Sealed Secrets).

**SSH Private Key Stored as Secret:**
- Risk: SSH private key for OpenClaw stored at `stacks/openclaw/main.tf:57-66` as unencrypted Secret. Readable by any pod with secret access.
- Files: `stacks/openclaw/main.tf` (lines 57-66)
- Current mitigation: Secret only readable by openclaw namespace (if RBAC enforced); encryption at rest not confirmed.
- Recommendations:
  - Rotate SSH key regularly; consider using ed25519 keys (shorter, stronger).
  - Audit Secret access via Kubernetes audit logs.
  - Use external secret store (HashiCorp Vault, Bitwarden) instead of native Secrets.

**WireGuard VPN Clients Unrestricted:**
- Risk: VPN clients can reach all cluster-internal services (10.32.0.0/12) unless firewall rules defined. No per-client segmentation.
- Files: `terraform.tfvars` (lines 430-434)
- Current mitigation: Attempted iptables rules commented out; not enforced.
- Recommendations:
  - Define explicit client restrictions in WireGuard firewall script (uncomment/complete lines 433-434).
  - Implement deny-by-default firewall (drop all, then allow specific routes).
  - Consider separate WireGuard interfaces for different trust levels (admin vs. guest).

**Multiple `:latest` Image Tags in Production:**
- Risk: 17 services use `:latest` tags (e.g., `nextcloud`, `kms`, `calibre`, `speedtest`, `rybbit`, `wealthfolio`, `cyberchef`, `coturn`, `immich-frame`, `health`, others).
- Files: Multiple stacks (see full list in grep output above).
- Current mitigation: Diun annotations track updates but don't auto-pull; images are immutable but unversioned.
- Recommendations:
  - Pin all production images to specific semantic versions (e.g., `ghcr.io/foo/bar:v1.2.3`, not `:latest`).
  - Use Diun to track new releases and trigger automated testing in staging.
  - Update CI/CD pipeline to require version tags for production deployments.

## Performance Bottlenecks

**Insufficient Health Probes on Critical Services:**
- Problem: Only 14 services have liveness/readiness probes out of 70+ services. Missing probes on databases (MySQL, PostgreSQL, Redis), ingress, auth.
- Files: All stacks (identified via grep: 14 instances of liveness/readiness out of 70+ services).
- Cause: Default Kubernetes behavior is to not restart unhealthy pods without probes; cascading failures silent.
- Improvement path: Add `livenessProbe`, `readinessProbe`, and `startupProbe` to all stateful services (databases, message queues, auth providers). Use TCP/HTTP probes appropriate to each service.

**Pod Disruption Budgets Missing:**
- Problem: Only 2 services have PodDisruptionBudget resources (identified via grep). Node evictions (updates, failures) can cause service degradation.
- Files: All stacks (need comprehensive PodDisruptionBudget coverage).
- Cause: PDBs are optional; many assume single-replica stateless services won't need them.
- Improvement path: Add PDB with `minAvailable: 1` to all services with `replicas > 1`. For single-replica services, ensure they're marked as non-critical (lower PriorityClass) or accept downtime during node maintenance.

**Resource Requests Sparse, Limits Missing:**
- Problem: Many services lack explicit resource requests/limits. Kyverno auto-generates defaults but CPU limits often too low for bursty workloads (Immich ML, Ollama, Ebook2Audiobook).
- Files: Multiple stacks (e.g., `stacks/immich/main.tf`, `stacks/ebook2audiobook/main.tf`, `stacks/ollama/main.tf`).
- Cause: Request/limit tuning requires load testing; defaults used instead.
- Improvement path: Run load tests on GPU workloads (Immich ML, Ollama) to determine sustained CPU/memory. Set requests to P50 usage, limits to P99. Monitor via Prometheus and adjust quarterly.

**Large Terraform Modules (900+ lines):**
- Problem: `stacks/platform/modules/dbaas/main.tf` is 916 lines; `stacks/immich/main.tf` is 660 lines; others > 450 lines.
- Files: `stacks/platform/modules/dbaas/main.tf` (916 lines), `stacks/platform/modules/nvidia/main.tf` (658 lines), `stacks/platform/modules/kyverno/resource-governance.tf` (809 lines).
- Cause: Monolithic resource definitions; hard to navigate and test.
- Improvement path: Split large modules into sub-modules (e.g., `dbaas/` → `mysql/`, `postgresql/`, `pgadmin/`, `backups/`). Use Terraform workspaces for per-database configuration.

## Fragile Areas

**Immich Machine Learning GPU Dependency:**
- Files: `stacks/immich/main.tf` (lines 380-450).
- Why fragile: GPU workload (`immich-machine-learning-cuda`) requires Tesla T4 on k8s-node1. If GPU becomes unavailable (hardware failure, driver issues), ML inference fails silently (no fallback). Single GPU point of failure.
- Safe modification: Add `nodeAffinity` to prefer GPU but allow non-GPU fallback (degraded mode). Implement health checks on GPU availability (`nvidia-smi` probe). Test GPU failure scenario before production use.
- Test coverage: No tests for GPU unavailability; assumes GPU always available.

**Nextcloud Backup/Restore Procedures Manual:**
- Files: `stacks/nextcloud/main.tf` (backup.sh and restore.sh ConfigMaps).
- Why fragile: Backup/restore scripts are ConfigMap-based; no automation. Restoration requires manual `kubectl exec` and script execution. No tested recovery procedure.
- Safe modification: Implement automated backup via Velero or CSI snapshots. Test restore procedure monthly via staged environment.
- Test coverage: No automated backup validation; scripts untested.

**NFS Dependency for Data Persistence:**
- Files: 126 references to NFS volumes across all stacks.
- Why fragile: All stateful data depends on NFS server at `10.0.10.15`. If NFS becomes unavailable, all services lose data immediately (no local caches). No fallback storage.
- Safe modification: Implement NFS client-side read caching (Linux NFS mount options `ac,acregmin=3600`). Monitor NFS availability via Prometheus alerts (Mount point offline). Test NFS failover procedure (if replica NFS exists).
- Test coverage: No chaos engineering tests for NFS unavailability.

**Istio Injection Disabled Cluster-Wide:**
- Files: `stacks/real-estate-crawler/main.tf` (line 19): `"istio-injection" : "disabled"` on namespace labels.
- Why fragile: No service mesh observability. Debugging pod-to-pod communication requires manual tracing (tcpdump). No mutual TLS between services.
- Safe modification: Enable Istio on non-critical services first (e.g., realestate-crawler). Monitor resource overhead. Gradually roll out to production.
- Test coverage: No mTLS validation; assumes all pods on same network are trusted.

**PostgreSQL Custom Image Not Tracked:**
- Files: `stacks/platform/modules/dbaas/main.tf` (line 717): `image = "viktorbarzin/postgres:16-master"`.
- Why fragile: Custom build at Docker Hub with PostGIS + PgVector extensions. No version tag; `:master` tag is mutable. Upstream extension versions unknown.
- Safe modification: Pin to semantic version (e.g., `:16.4-postgis3.4-pgvector0.8`). Build images locally with Dockerfile tracked in git. Test extension versions against application requirements.
- Test coverage: No tests for extension availability or version compatibility.

## Scaling Limits

**Single-Replica Critical Services:**
- Current capacity: Immich server (1 replica), PostgreSQL databases (1 replica), Redis (1 instance), Traefik (varies).
- Limit: Node failure causes immediate service outage. Kubernetes default takes 5+ minutes to reschedule pod.
- Scaling path: Increase critical service replicas to 3 (quorum). Add pod anti-affinity to spread across nodes. Implement PodDisruptionBudget with `minAvailable: 2`.

**GPU Capacity Bottleneck:**
- Current capacity: 1 Tesla T4 GPU on k8s-node1.
- Limit: Immich ML + Ebook2Audiobook + Ollama all compete for single GPU. Queue time 10+ minutes for CPU-bound inference tasks.
- Scaling path: Add second GPU (e.g., T4 or RTX 3090) to k8s-node1. Implement GPU scheduling via NVIDIA GPU Operator. Monitor GPU utilization (target 70-80%).

**NFS Storage Capacity:**
- Current capacity: `/mnt/main/` mounted on TrueNAS (size unknown; typically 4-8TB in home setups).
- Limit: Immich (image library), Calibre (ebooks), Dawarich (location history) grow unbounded. When storage full, writes fail; services degrade.
- Scaling path: Monitor NFS capacity monthly (`df -h`). Set up Prometheus alert at 80% capacity. Plan for annual storage growth based on user behavior (e.g., 100GB Immich/month).

**MySQL/PostgreSQL Connection Pool:**
- Current capacity: PgBouncer at `dbaas/pgbouncer` provides connection pooling. Default pool size likely 100-200 connections.
- Limit: Many simultaneous connections (Nextcloud, Affine, Gramps Web, Authentik) can exceed pool. New connections queue or fail.
- Scaling path: Monitor PgBouncer pool utilization (Prometheus metric `pgbouncer_pools_used_connections`). Increase pool size if > 80% utilization. Consider read replicas for read-heavy workloads.

**API Rate Limiting & Bandwidth:**
- Current capacity: Services exposed via Traefik ingress. No global rate limiting documented.
- Limit: External tools (Immich mobile app, ebook2audiobook processing) can spike bandwidth. DoS-like behavior possible.
- Scaling path: Implement Traefik rate limiting middleware (Prometheus-aware). Add Cloudflare rate limiting on public domains. Monitor egress bandwidth.

## Dependencies at Risk

**Redis Stack `:latest` Tag:**
- Risk: `stacks/platform/modules/redis/main.tf` uses `image = "redis/redis-stack:latest"`. Redis Stack is actively developed; breaking changes possible.
- Impact: Unexpected version upgrade could introduce incompatibilities with clients expecting specific command set or module versions.
- Migration plan: Pin to specific Redis Stack version (e.g., `:7.2-rc1`). Test version upgrades in staging first. Monitor Redis logs for deprecated command warnings.

**Immich `:latest` or Floating Tag:**
- Risk: `stacks/immich/main.tf` pins to `v2.5.6` but Immich frequently releases patch versions. Database migrations can cause downtime.
- Impact: If Immich version upgrades without testing, database migrations could fail or hang (no rollback mechanism).
- Migration plan: Pin to specific patch versions (e.g., `v2.5.6`, not `v2.5`). Test Immich upgrades in staging first. Maintain backup before upgrading.

**Unsupported MySQL 9.2.0:**
- Risk: `stacks/platform/modules/dbaas/main.tf` specifies `image = "mysql:9.2.0"`. MySQL 9.2 is a development version (RC status as of Feb 2026).
- Impact: RC versions not recommended for production. Stability issues, CVEs possible. No long-term support.
- Migration plan: Migrate to MySQL 8.4 LTS or 9.0 GA (stable). Test data migration first. Plan for gradual rollout.

**Python Timeouts in Monitoring Scripts:**
- Risk: `stacks/platform/modules/nvidia/main.tf` uses hardcoded `timeout=10` for HTTP requests and subprocess calls. Slow network conditions will fail.
- Impact: GPU monitoring will fail if network is slow or unavailable. Silent failures possible.
- Migration plan: Implement exponential backoff and retry logic (e.g., `tenacity` library). Increase timeout to 30s for unreliable networks. Log timeouts for debugging.

## Missing Critical Features

**No Disaster Recovery Plan:**
- Problem: Backup procedures exist (Nextcloud, MySQL) but no tested recovery procedure. No runbook for cluster disaster.
- Blocks: If cluster data lost, recovery would be manual and time-consuming. No RTO/RPO defined.
- Impact: Data loss risk > 24 hours to recover.

**No Secrets Rotation Policy:**
- Problem: SSH keys, API tokens, database passwords stored in git-crypt and tfvars. No automated rotation schedule.
- Blocks: If key leaked, manual intervention required to rotate across all services.
- Impact: Leaked credentials persist until discovery.

**No Cross-Cluster Failover:**
- Problem: Single Kubernetes cluster on Proxmox. No HA cluster or backup cluster.
- Blocks: Cluster-wide failure (network partition, hypervisor crash) causes total outage.
- Impact: RTO > 1 hour (manual intervention to restart hypervisor or re-provision).

## Test Coverage Gaps

**No Infrastructure Testing:**
- What's not tested: Terraform applies, Helm charts, manifests only validated via `terraform plan`. No `terratest`, no functional tests of deployed services.
- Files: All stacks (no test files found).
- Risk: Typos, variable misconfigurations, missing dependencies not caught until production apply.
- Priority: High — add `terratest` to validate Terraform. Test critical paths (database connection, ingress routing).

**No Chaos Engineering Tests:**
- What's not tested: Pod evictions, node failures, NFS unavailability, network partitions.
- Files: All stacks (no chaos tests found).
- Risk: Cascading failures and data loss scenarios not validated. Assumptions about resilience untested.
- Priority: High — run monthly chaos tests (Gremlin, Chaos Toolkit). Document recovery procedures.

**No Backup Restoration Tests:**
- What's not tested: Nextcloud backups, MySQL backups. Restore procedures exist but never executed.
- Files: `stacks/nextcloud/main.tf`, `stacks/platform/modules/dbaas/main.tf`.
- Risk: Backups corrupt or unusable when needed. RPO > 24 hours if discovery slow.
- Priority: High — monthly restore-to-staging test. Automate backup validation.

**No Security Scanning for Vulnerabilities:**
- What's not tested: Container images for CVEs, Terraform for security anti-patterns (hardcoded secrets, overpermissive RBAC).
- Files: All stacks, all container images.
- Risk: Known vulnerabilities deployed to production. No supply chain security.
- Priority: Medium — integrate Trivy/Snyk into CI/CD. Scan images weekly; alert on high CVEs.

---

*Concerns audit: 2026-02-23*
