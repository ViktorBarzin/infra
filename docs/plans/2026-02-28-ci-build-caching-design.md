# CI Build Caching Design

**Date**: 2026-02-28
**Status**: Approved

## Problem

Woodpecker CI Docker image builds (build-cli, f1-stream, and future pipelines) rebuild everything from scratch on every push. No BuildKit layer caching is configured, so dependency installation steps (npm install, pip install, go build) re-execute even when requirements haven't changed.

## Decision

Extend the existing Docker Compose registry stack on `10.0.20.10` with a private R/W registry for BuildKit layer caching and image storage. Configure Woodpecker pipelines to use registry-based BuildKit cache and dual-push to both local and Docker Hub.

## Design

### 1. Private Registry Service

Add `registry-private` to the existing Docker Compose stack at `modules/docker-registry/docker-compose.yml`:

- **Port**: 5050 (via nginx, consistent with existing 50xx pattern)
- **Storage**: `/opt/registry/data/private`, 100GiB limit
- **Config**: Standard `registry:2` without `proxy` section (enables R/W)
- **Auth**: None (internal network only, `10.0.20.0/24`)
- **Nginx**: New upstream + server block on port 5050. Unlike the read-only proxy servers, this must allow PUT/POST/PATCH for image pushes.

### 2. DNS

Add Technitium A record: `registry.viktorbarzin.lan` → `10.0.20.10`

### 3. Woodpecker Pipeline Changes

For each Docker image build pipeline, update the `plugin-docker-buildx` step:

```yaml
settings:
  # BuildKit registry cache
  cache_from: type=registry,ref=registry.viktorbarzin.lan:5050/<repo>:buildcache
  cache_to: type=registry,ref=registry.viktorbarzin.lan:5050/<repo>:buildcache,mode=max
  # Dual push: Docker Hub + local
  tags:
    - latest
    - registry.viktorbarzin.lan:5050/<repo>:latest
  # Allow HTTP registry
  buildkit_config: |
    [registry."registry.viktorbarzin.lan:5050"]
      http = true
      insecure = true
```

`mode=max` caches all intermediate layers, not just final image layers. This is critical for multi-stage builds (f1-stream has Node + Python stages).

### 4. No Containerd Changes

K8s pods continue pulling from Docker Hub via the existing pull-through cache on `10.0.20.10:5000`. The private registry is only used by Woodpecker for build caching and as a backup image store.

### 5. Cleanup

Extend `modules/docker-registry/cleanup-tags.sh` to also prune the private registry, keeping the N most recent tags per image.

## Expected Impact

- **First build**: Same speed (cold cache), layers stored in local registry
- **Subsequent builds (unchanged requirements)**: BuildKit pulls cached layers over LAN. Only `COPY . .` and final build steps re-execute. Expected 50-80% build time reduction for typical dependency-heavy builds.
- **Storage**: Build cache layers consume space on the VM. 100GiB limit with cleanup keeps this bounded.

## What's NOT In Scope

- Main terragrunt-apply pipeline (`default.yml`) — not a Docker image build
- Dependency caching (npm node_modules, Go modules, pip packages) — not needed since BuildKit layer caching covers this
- Containerd config changes on K8s nodes
- Migrating pull-through caches to K8s
