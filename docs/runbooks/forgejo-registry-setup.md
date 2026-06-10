# Runbook: Forgejo OCI registry — initial setup

Last updated: 2026-05-07

This runbook covers the **one-time** bootstrap of Forgejo's container
registry, executed during Phase 0 of the registry consolidation plan
(`docs/plans/2026-05-07-forgejo-registry-consolidation-plan.md`).

After this runbook is complete, the Forgejo OCI registry at
`forgejo.viktorbarzin.me` accepts pushes from CI and pulls from the
cluster, with retention and integrity monitoring in place.

## Order of operations

The Terraform stacks reference Vault keys that don't exist on a fresh
cluster. Create the keys **before** running `scripts/tg apply`.

1. Apply the resource bumps (memory, PVC, ingress body size,
   packages env vars) — these don't depend on the new Vault keys.
2. Create the service-account users + PATs in Forgejo.
3. Push the PATs to Vault.
4. Apply the rest of Phase 0 (registry-credentials extension,
   monitoring probe, retention CronJob).

### Step 1 — apply Forgejo deployment bumps

```bash
cd infra/stacks/forgejo
scripts/tg apply
```

Wait for the new pod to come up at the bumped 1Gi memory request and
the resized 15Gi PVC. Verify packages are enabled:

```bash
kubectl exec -n forgejo deploy/forgejo -- forgejo manager flush-queues
kubectl exec -n forgejo deploy/forgejo -- env | grep PACKAGES
```

### Step 2 — create service-account users

`forgejo admin user create` is idempotent only with
`--must-change-password=false`. Re-running it on an existing user
errors out — that's fine; skip on rerun.

```bash
# cluster-puller — read:package PAT for in-cluster pulls.
kubectl exec -n forgejo deploy/forgejo -- \
  forgejo admin user create \
  --username cluster-puller \
  --email cluster-puller@viktorbarzin.me \
  --password "$(openssl rand -base64 24)" \
  --must-change-password=false

# ci-pusher — write:package PAT for CI dual-push, also reused as the
# cleanup CronJob credential (write:package includes delete).
kubectl exec -n forgejo deploy/forgejo -- \
  forgejo admin user create \
  --username ci-pusher \
  --email ci-pusher@viktorbarzin.me \
  --password "$(openssl rand -base64 24)" \
  --must-change-password=false
```

The user passwords are throwaway — we only ever auth via PAT. Forgejo
admin can reset them at any time from the Web UI.

### Step 3 — generate the PATs

PATs **must** be generated through the Web UI logged in as the
respective user (the CLI doesn't expose token creation). To log in
without OAuth (registration is disabled for everyone except `viktor`,
the admin), use the per-user temporary password from step 2.

For each of `cluster-puller` and `ci-pusher`:

1. Sign out of `viktor`.
2. Go to `https://forgejo.viktorbarzin.me/user/login` and sign in
   with the throwaway password.
3. Settings → Applications → Generate new token.
4. Name: `cluster-pull` / `ci-push`. **Expiration: never.**
5. Scopes:
   - `cluster-puller`: `read:package`
   - `ci-pusher`: `write:package` (covers read+write+delete)
6. Save the token shown on the next page — it is **not** displayed again.

For the cleanup CronJob, generate a third PAT on `ci-pusher`:

7. Repeat steps 4-6 with name `cleanup`, scope `write:package`.

### Step 4 — push PATs to Vault

```bash
vault login -method=oidc

# Read-only, used by the cluster-wide registry-credentials Secret and
# by the Forgejo integrity probe.
vault kv patch secret/viktor \
  forgejo_pull_token=<paste cluster-puller PAT>

# Write+delete, used by the retention CronJob inside Forgejo's
# namespace.
vault kv patch secret/viktor \
  forgejo_cleanup_token=<paste ci-pusher cleanup PAT>

# Write, propagated by vault-woodpecker-sync to all Woodpecker repos.
vault kv patch secret/ci/global \
  forgejo_user=ci-pusher \
  forgejo_push_token=<paste ci-pusher push PAT>
```

### Step 5 — apply the rest of Phase 0

```bash
# Registry credential Secret (now reads forgejo_pull_token).
cd infra/stacks/kyverno && scripts/tg apply

# Monitoring probe + retention CronJob.
cd infra/stacks/monitoring && scripts/tg apply
cd infra/stacks/forgejo && scripts/tg apply

# Resolved routing domain (+ vestigial containerd hosts.toml) on each
# existing k8s node — VM cloud-init only fires on first boot. The routing
# domain (~viktorbarzin.me -> Technitium) is what makes pulls hairpin-proof:
# the hosts.toml mirror alone falls back to public DNS (Traefik 404s its
# bare-IP requests, and the registry auth realm is an absolute public URL).
infra/scripts/setup-forgejo-containerd-mirror.sh
```

## Verification

```bash
# Login from a workstation with docker.
echo "<ci-pusher PAT>" | docker login forgejo.viktorbarzin.me -u ci-pusher --password-stdin

# Push a smoketest image.
docker pull alpine:3.20
docker tag alpine:3.20 forgejo.viktorbarzin.me/viktor/smoketest:1
docker push forgejo.viktorbarzin.me/viktor/smoketest:1

# Per-node pull path: routing domain active + name resolves to the live
# Traefik LB (via Technitium split-horizon zone) + pull works.
ssh wizard@<node> 'resolvectl status | grep -A2 "~viktorbarzin.me"; getent hosts forgejo.viktorbarzin.me'
# Expect: DNS Domain ~viktorbarzin.me on server 10.0.20.201, and
#         getent -> the current Traefik LB IP (10.0.20.203 today)
ssh wizard@<node> sudo crictl pull forgejo.viktorbarzin.me/viktor/smoketest:1

# Confirm the cluster-wide Secret was synced into a fresh namespace.
kubectl create namespace forgejo-smoketest
kubectl get secret -n forgejo-smoketest registry-credentials \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq '.auths | keys'
# Expect: ["10.0.20.10:5050", "forgejo.viktorbarzin.me",
#         "registry.viktorbarzin.me", "registry.viktorbarzin.me:5050"]
kubectl delete namespace forgejo-smoketest

# Delete the smoketest package via API.
curl -X DELETE -H "Authorization: token <ci-pusher cleanup PAT>" \
  https://forgejo.viktorbarzin.me/api/v1/packages/viktor/container/smoketest/1
```

## When to revisit

- **PAT rotation**: PATs created here have no expiry by design. If a
  PAT leaks, regenerate via the Web UI and `vault kv patch` the new
  value into the same key — the next `terragrunt apply` will sync it
  to all consumers within minutes (Kyverno ClusterPolicy clones the
  Secret, vault-woodpecker-sync runs every 6h).
- **New service account**: if a future workload needs different
  scopes, add a parallel user/PAT here rather than expanding existing
  PAT scope. Principle of least privilege.
