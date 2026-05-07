# Runbook: Forgejo registry break-glass — recovering infra-ci

Last updated: 2026-05-07

## When to use this runbook

When **all** of the following are true:

1. Forgejo (`forgejo.viktorbarzin.me`) is unreachable.
2. `registry-private` is also gone (post-Phase 4 of the consolidation),
   so you can't fall back to `registry.viktorbarzin.me:5050/infra-ci`.
3. You need to run an infra Woodpecker pipeline (apply, build-cli,
   drift-detection, etc.) — but those pipelines pull `infra-ci` and
   crash because the registry is down.

If only Forgejo is down but `registry-private` is still alive, the
pipelines work — `image:` references in `infra/.woodpecker/*.yml`
still hit `registry.viktorbarzin.me:5050/infra-ci` until Phase 3
flips them. Skip this runbook entirely.

## What's available

The `build-ci-image.yml` Woodpecker pipeline saves a tarball after
each successful push:

| Location | Path |
|---|---|
| Registry VM disk (10.0.20.10) | `/opt/registry/data/private/_breakglass/infra-ci-<sha>.tar.gz` |
| Registry VM disk (latest symlink) | `/opt/registry/data/private/_breakglass/infra-ci-latest.tar.gz` |
| Synology NAS (offsite copy via daily-backup sync) | `/volume1/Backup/Viki/pve-backup/_forgejo-breakglass/` |

The registry VM keeps the last 5 tarballs. Synology mirrors them
through the existing offsite-sync-backup job (`/usr/local/bin/
offsite-sync-backup`).

## Recovery procedure

The goal is to get a working `infra-ci` image onto a k8s node so
Woodpecker pods can run it. Then run a Woodpecker pipeline that
restores Forgejo from PVC backup or rebuilds it.

### Step 1 — copy the tarball to a node

From your workstation (the registry VM is reachable but Forgejo is
not — the rest of the cluster might be in a similar partial state):

```bash
ssh wizard@10.0.20.103  # any responsive k8s node
sudo mkdir -p /var/breakglass
sudo scp root@10.0.20.10:/opt/registry/data/private/_breakglass/infra-ci-latest.tar.gz \
  /var/breakglass/
```

If the registry VM is also down, fall back to Synology:

```bash
sudo scp 192.168.1.13:/volume1/Backup/Viki/pve-backup/_forgejo-breakglass/infra-ci-latest.tar.gz \
  /var/breakglass/
```

### Step 2 — load into containerd

`docker load` won't help on a k8s node — it loads into the docker
daemon, which kubelet/containerd doesn't see. Use `ctr`:

```bash
sudo ctr -n k8s.io images import /var/breakglass/infra-ci-latest.tar.gz
sudo ctr -n k8s.io images list | grep infra-ci
```

Confirm the image is tagged with the original repository name
(`registry.viktorbarzin.me:5050/infra-ci:<sha>` — the tarball was
saved with that tag, NOT the Forgejo name).

### Step 3 — pin pods to this node

Add a node selector or taint-toleration to whatever pipeline you
need to run. Simplest: cordon the other nodes briefly so Woodpecker
schedules onto this one.

```bash
for n in $(kubectl get nodes -o name | grep -v $(hostname)); do
  kubectl cordon ${n#node/}
done
```

Run the pipeline. After it completes:

```bash
for n in $(kubectl get nodes -o name); do
  kubectl uncordon ${n#node/}
done
```

### Step 4 — fix the underlying problem

The pipeline you just ran was meant to restore Forgejo. Common
options:

- **Forgejo PVC corrupt** — `docs/runbooks/forgejo-registry-rebuild-image.md`
  walks through PVC restore from LVM snapshot or PVE backup.
- **Forgejo OOM-loop** — bump memory request+limit in
  `infra/stacks/forgejo/main.tf` and apply.
- **Forgejo unreachable due to network** — check Traefik, MetalLB,
  pfSense.

Once Forgejo is back, run `build-ci-image.yml` manually so the
tarball regenerates with the latest commit.

## Why this exists

The 2026-04-19 post-mortem on the registry-orphan-index incident
showed that a single registry going corrupt could block ALL infra
pipelines (because every pipeline pulls `infra-ci` from that
registry). The dual-push to Forgejo + registry-private removes that
single-point-of-failure during the bake. After Phase 4
decommissions registry-private, the tarball is the last line of
defense.

## Why on the registry VM and not in-cluster

The Forgejo pod and registry-private pod both depend on cluster
networking + storage. The registry VM is an independent
non-clustered VM with local storage. If the cluster is in a bad
state, the VM's disk is still readable from any other host on the
LAN.
