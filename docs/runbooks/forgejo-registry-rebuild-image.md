# Runbook: Rebuild an Image on the Forgejo OCI Registry

Last updated: 2026-05-07

## When to use this

Pipelines pulling from `forgejo.viktorbarzin.me/viktor/<image>` fail with:

- `failed to resolve reference … : not found`
- `manifest unknown`
- HEAD on a manifest/blob digest returns 404
- `forgejo-integrity-probe` CronJob in `monitoring` reports
  `registry_manifest_integrity_failures > 0` for
  `instance="forgejo.viktorbarzin.me"`

This is the Forgejo equivalent of the registry-private orphan-index
failure mode (`docs/post-mortems/2026-04-19-registry-orphan-index.md`).
Cause is usually package-version delete races with an in-flight pull,
or PVC corruption. Fix is to rebuild the image from source and
re-push, so Forgejo receives a complete, fresh upload.

If the symptom is different (Forgejo unreachable, PVC OOM,
authentication failure), use:
- `docs/runbooks/forgejo-registry-setup.md` for auth + token issues
- `docs/runbooks/forgejo-registry-breakglass.md` if Forgejo + the
  cluster are both unreachable
- `docs/runbooks/restore-pvc-from-backup.md` for PVC corruption

## Phase 1 — Confirm the diagnosis

From any host:

```sh
REG=forgejo.viktorbarzin.me
USER=cluster-puller
PASS="$(vault kv get -field=forgejo_pull_token secret/viktor)"
IMAGE=viktor/payslip-ingest
TAG=latest

# 1. Confirm the manifest exists at all.
curl -sk -u "$USER:$PASS" \
  -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json' \
  "https://$REG/v2/$IMAGE/manifests/$TAG" | jq '.mediaType, .manifests[].digest // .config.digest'

# 2. HEAD each child / config / layer digest. Any non-200 = confirmed.
for d in $(curl -sk -u "$USER:$PASS" -H 'Accept: application/vnd.oci.image.index.v1+json' \
             "https://$REG/v2/$IMAGE/manifests/$TAG" | jq -r '.manifests[].digest // empty'); do
  code=$(curl -sk -u "$USER:$PASS" -o /dev/null -w '%{http_code}' \
         -I "https://$REG/v2/$IMAGE/manifests/$d")
  echo "$d → $code"
done
```

The probe's last log run is also a fast way to see what's affected:

```sh
kubectl -n monitoring logs \
  $(kubectl -n monitoring get pods -l job-name -o name \
     | grep forgejo-integrity-probe | head -1)
```

## Phase 2 — Rebuild and re-push

Forgejo lets you delete a specific package version through the API.
Doing this **before** the rebuild ensures the new push doesn't
collide with the half-broken existing entry.

```sh
# Delete the broken version (replace TAG with the actual tag).
curl -X DELETE -H "Authorization: token $(vault kv get -field=forgejo_cleanup_token secret/viktor)" \
  "https://$REG/api/v1/packages/viktor/container/$(basename $IMAGE)/$TAG"
```

Rebuild via Woodpecker (manual run if the pipeline isn't triggered
by a code change):

1. Open `https://ci.viktorbarzin.me/repos/<repo>/manual` for the
   project.
2. Click **Run pipeline** with `branch=master`.
3. Wait for the build-and-push step to complete.
4. Confirm the new version is visible in Forgejo Web UI under
   `viktor/<image>` → Packages → Container.

## Phase 3 — Restart consumers

Pods that already cached the broken digest may continue using it.
Force a fresh pull:

```sh
kubectl rollout restart deploy/<service> -n <ns>
```

If the pod still fails, the new manifest digest may not have
propagated through containerd's cache. Drain + restart containerd on
the affected node:

```sh
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
ssh wizard@<node> sudo systemctl restart containerd
kubectl uncordon <node>
```

## Phase 4 — Verify integrity recovery

The next probe run (every 15 min) will report:

```
registry_manifest_integrity_failures{instance="forgejo.viktorbarzin.me"} 0
```

The `RegistryManifestIntegrityFailure` alert resolves automatically
30 minutes after the metric goes back to 0.

## Why this happens

Forgejo's OCI registry stores blobs in its own DB+filesystem. Unlike
`registry:2` + `distribution`, it doesn't have the
[`distribution#3324`](https://github.com/distribution/distribution/issues/3324)
GC-vs-tag-delete race. But it can still reach a broken state if:

- The retention CronJob deletes a version while a pull is in flight
  on the same digest.
- The PVC fills up mid-push (`docs/runbooks/restore-pvc-from-backup.md`).
- A Forgejo upgrade migrates the package schema and a row is dropped.

In all cases the recovery procedure is identical: delete the broken
version through the API, rebuild from source, force consumers to
re-pull.
