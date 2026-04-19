# Runbook: Rebuild an Image After a Registry Orphan-Index Incident

Last updated: 2026-04-19

## When to use this

Pipelines that pull from `registry.viktorbarzin.me:5050` are failing with
messages like:

- `failed to resolve reference … : not found`
- `manifest unknown`
- `image can't be pulled` (Woodpecker exit 126)
- `error pulling image`: HEAD on a child manifest digest returns 404

…and `skopeo inspect --tls-verify --creds "$USER:$PASS" docker://registry.viktorbarzin.me:5050/<image>:<tag>`
returns an OCI image index whose `manifests[].digest` references are 404
on the registry.

This is the **orphan OCI-index** failure mode documented in
`docs/post-mortems/2026-04-19-registry-orphan-index.md`. The fix is to
rebuild the affected image from source so the registry receives a fresh,
complete push.

If the symptom is different (e.g., registry container down, TLS expiry,
auth failure), use `docs/runbooks/registry-vm.md` instead.

## Phase 1 — Confirm the diagnosis

From any host with `skopeo`:

```sh
REG=registry.viktorbarzin.me:5050
IMAGE=infra-ci
TAG=latest

# 1. Confirm the index exists.
skopeo inspect --tls-verify --creds "$USER:$PASS" \
  --raw "docker://$REG/$IMAGE:$TAG" | jq '.mediaType, .manifests[].digest'

# 2. HEAD each child. Any non-200 = confirmed orphan.
for d in $(skopeo inspect --tls-verify --creds "$USER:$PASS" --raw \
           "docker://$REG/$IMAGE:$TAG" | jq -r '.manifests[].digest'); do
  code=$(curl -sk -u "$USER:$PASS" -o /dev/null -w '%{http_code}' \
         -I "https://$REG/v2/$IMAGE/manifests/$d")
  echo "$d → $code"
done
```

If every child is 200, the problem is elsewhere — stop here and check
the registry VM, TLS, or auth.

The `registry-integrity-probe` CronJob in the `monitoring` namespace
runs this same check every 15 minutes across every tag in the catalog;
its last run is also a fast way to see which image(s) are affected:

```sh
kubectl -n monitoring logs \
  $(kubectl -n monitoring get pods -l job-name -o name \
     | grep registry-integrity-probe | head -1)
```

## Phase 2 — Rebuild

### Option A (preferred): rebuild via CI

Find the `build-*.yml` pipeline that produces the image:

| Image | Pipeline | Repo ID |
|---|---|---|
| `infra-ci` | `.woodpecker/build-ci-image.yml` | 1 (infra) |
| `infra` (cli) | `.woodpecker/build-cli.yml` | 1 (infra) |
| `k8s-portal` | `.woodpecker/k8s-portal.yml` | 1 (infra) |

Trigger a manual build. The Woodpecker API expects a numeric repo ID
(paths with `owner/name` return HTML):

```sh
WOODPECKER_TOKEN=$(vault kv get -field=woodpecker_admin_token secret/viktor)

# Kick off a manual build against master.
curl -s -X POST \
  -H "Authorization: Bearer $WOODPECKER_TOKEN" \
  -H "Content-Type: application/json" \
  "https://ci.viktorbarzin.me/api/repos/1/pipelines" \
  -d '{"branch":"master"}' | jq .number

# Follow the pipeline at https://ci.viktorbarzin.me/repos/1/pipeline/<number>
```

The pipeline's `verify-integrity` step walks every blob the push
references. If it passes, the registry now has a clean index; pull
consumers will recover on next attempt.

### Option B (fallback): build on the registry VM

Only use this if Woodpecker itself is broken (its own pipeline runs
from the same `infra-ci` image, so a corrupted `infra-ci:latest` can
prevent Option A from recovering).

```sh
ssh root@10.0.20.10 '
  cd /tmp
  git clone --depth 1 https://github.com/ViktorBarzin/infra
  cd infra/ci
  docker build -t registry.viktorbarzin.me:5050/infra-ci:manual -t registry.viktorbarzin.me:5050/infra-ci:latest .
  docker login -u "$USER" -p "$PASS" registry.viktorbarzin.me:5050
  docker push registry.viktorbarzin.me:5050/infra-ci:manual
  docker push registry.viktorbarzin.me:5050/infra-ci:latest
'
```

Then re-run any pipelines that failed — Woodpecker UI → Restart, or:

```sh
curl -s -X POST \
  -H "Authorization: Bearer $WOODPECKER_TOKEN" \
  "https://ci.viktorbarzin.me/api/repos/1/pipelines/<failed-pipeline-number>"
```

## Phase 3 — Verify

```sh
# 1. Pull the image fresh (bypassing containerd cache) and check its index.
REG=registry.viktorbarzin.me:5050
skopeo inspect --tls-verify --creds "$USER:$PASS" \
  --raw "docker://$REG/infra-ci:latest" \
  | jq '.manifests[] | {digest, platform}'

# 2. HEAD every child digest — all should be 200.
for d in $(skopeo inspect --tls-verify --creds "$USER:$PASS" --raw \
           "docker://$REG/infra-ci:latest" | jq -r '.manifests[].digest'); do
  code=$(curl -sk -u "$USER:$PASS" -o /dev/null -w '%{http_code}' \
         -I "https://$REG/v2/infra-ci/manifests/$d")
  [ "$code" = "200" ] || echo "STILL BROKEN: $d → $code"
done
echo "verified"

# 3. Kick off the next scheduled probe for good measure.
kubectl -n monitoring create job --from=cronjob/registry-integrity-probe \
  registry-integrity-probe-verify-$(date +%s)
kubectl -n monitoring logs -f -l job-name=registry-integrity-probe-verify-$(date +%s)
```

The `RegistryManifestIntegrityFailure` alert clears automatically when
the probe's next run returns zero failures.

## Phase 4 — Investigate orphans

Once the immediate fix is in, check whether any OTHER images on the
registry have orphan children:

```sh
ssh root@10.0.20.10 'python3 /opt/registry/fix-broken-blobs.sh --dry-run 2>&1 | grep "ORPHAN INDEX"'
```

Each hit is a separate image that will eventually fail to pull. Rebuild
them in the same way (Option A preferred). If the list is long, open a
beads task — do NOT batch-delete the indexes; that's a destructive
registry operation outside this runbook's scope.

## Related

- `docs/post-mortems/2026-04-19-registry-orphan-index.md` — why this
  happens.
- `docs/runbooks/registry-vm.md` — VM-level operations (DNS,
  `docker compose` restarts).
- `modules/docker-registry/fix-broken-blobs.sh` — the scanner cron
  itself, runs nightly and after each GC.
- `stacks/monitoring/modules/monitoring/main.tf` —
  `registry_integrity_probe` CronJob definition.
