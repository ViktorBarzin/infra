# CI Build Caching Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Speed up Woodpecker CI Docker image builds by adding BuildKit layer caching via a local private registry, with dual-push to Docker Hub and local.

**Architecture:** Extend the existing Docker Compose registry stack on `10.0.20.10` with a new R/W `registry-private` service (port 5050). Configure Woodpecker `plugin-docker-buildx` pipelines with `cache_from`/`cache_to` pointing to `registry.viktorbarzin.lan:5050`. Push final images to both Docker Hub and local registry. All changes persisted in Terraform via `stacks/infra/main.tf` cloud-init provisioning.

**Tech Stack:** Docker Registry v2, nginx, Docker Compose, Woodpecker CI, BuildKit, Technitium DNS, Terraform

**Design doc:** `docs/plans/2026-02-28-ci-build-caching-design.md`

**Key context:** The registry VM at `10.0.20.10` is fully managed via Terraform in `stacks/infra/main.tf`. Config files live in `modules/docker-registry/` and are read by Terraform via `file()` and `templatefile()`, then base64-encoded into cloud-init `provision_cmds`. Changes to config files require updating both the files AND the cloud-init provisioning in `stacks/infra/main.tf`. Since the VM is already running, we also SCP updated files to the live VM for immediate effect.

---

### Task 1: Create private registry config file

**Files:**
- Create: `modules/docker-registry/config-private.yml`

**Step 1: Create the config file**

This is a standard `registry:2` config WITHOUT the `proxy` section (which is what makes it R/W instead of read-only pull-through). Based on the existing `config.yaml` but with 100GiB storage and no proxy/auth.

```yaml
version: 0.1
log:
  fields:
    service: registry-private
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
    maxsize: 100GiB
  delete:
    enabled: true
  maintenance:
    uploadpurging:
      enabled: true
      age: 168h
      interval: 4h
      dryrun: false
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
```

Key differences from the proxy configs:
- No `proxy` section → allows pushes
- `maxsize: 100GiB` (user requested 100GB)
- `uploadpurging.age: 168h` (7 days, since build cache layers are re-pushed frequently)

**Step 2: Commit**

```bash
git add modules/docker-registry/config-private.yml
git commit -m "[ci skip] add private R/W registry config for CI build caching"
```

---

### Task 2: Add registry-private service to Docker Compose

**Files:**
- Modify: `modules/docker-registry/docker-compose.yml`

**Step 1: Add the registry-private service**

Add this service block after `registry-kyverno` (before `nginx`):

```yaml
  registry-private:
    image: registry:2
    container_name: registry-private
    restart: always
    volumes:
      - /opt/registry/data/private:/var/lib/registry
      - /opt/registry/config-private.yml:/etc/docker/registry/config.yml:ro
    networks:
      - registry
    healthcheck:
      test: ["CMD", "sh", "-c", "wget -qO- http://localhost:5000/v2/ >/dev/null 2>&1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
```

**Step 2: Add port 5050 to the nginx service**

In the `nginx` service `ports` list, add:

```yaml
      - "5050:5050"
```

**Step 3: Add registry-private to nginx depends_on**

```yaml
      registry-private:
        condition: service_healthy
```

**Step 4: Commit**

```bash
git add modules/docker-registry/docker-compose.yml
git commit -m "[ci skip] add registry-private service to Docker Compose stack"
```

---

### Task 3: Add nginx upstream and server block for private registry

**Files:**
- Modify: `modules/docker-registry/nginx_registry.conf`

**Step 1: Add upstream block**

After the existing `upstream kyverno` block, add:

```nginx
    upstream private {
        server registry-private:5000;
        keepalive 32;
    }
```

**Step 2: Add server block**

After the last server block (kyverno on port 5040), add:

```nginx
    # --- Private R/W Registry (port 5050) ---

    server {
        listen 5050;
        server_name _;

        client_max_body_size 0;
        proxy_request_buffering off;
        proxy_buffering off;
        chunked_transfer_encoding on;

        location /v2/ {
            proxy_pass http://private;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header Connection "";
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

            proxy_read_timeout 900;
            proxy_send_timeout 900;
        }

        location / {
            return 200 'ok';
            add_header Content-Type text/plain;
        }
    }
```

Key differences from the read-only proxy server blocks:
- **No `proxy_cache`** directives — caching uploads would corrupt pushes
- **`proxy_buffering off`** — important for large layer uploads
- **`chunked_transfer_encoding on`** — Docker push uses chunked uploads
- **`X-Real-IP` / `X-Forwarded-For`** headers — useful for debugging

**Step 3: Commit**

```bash
git add modules/docker-registry/nginx_registry.conf
git commit -m "[ci skip] add nginx upstream and server block for private registry on port 5050"
```

---

### Task 4: Update Terraform provisioning for the private registry

**Files:**
- Modify: `stacks/infra/main.tf` (lines 119-274, the docker-registry-template and docker-registry-vm modules)

**Step 1: Add private registry data directory to `provision_cmds`**

In the `mkdir` command at line 152, append the private registry directory. Change:

```hcl
    "mkdir -p /opt/registry/data/dockerhub /opt/registry/data/ghcr /opt/registry/data/quay /opt/registry/data/k8s /opt/registry/data/kyverno",
```

to:

```hcl
    "mkdir -p /opt/registry/data/dockerhub /opt/registry/data/ghcr /opt/registry/data/quay /opt/registry/data/k8s /opt/registry/data/kyverno /opt/registry/data/private",
```

**Step 2: Add config-private.yml deployment command**

After the kyverno config block (line 203), add:

```hcl
    # Write private R/W registry config (no proxy = accepts pushes)
    format("echo %s | base64 -d > /opt/registry/config-private.yml",
      base64encode(file("${path.root}/../../modules/docker-registry/config-private.yml"))
    ),
```

**Step 3: Add garbage collection cron for private registry**

After the kyverno garbage collection cron (line 239), add:

```hcl
    "( crontab -l 2>/dev/null; echo '25 3 * * 0 /usr/bin/docker exec registry-private registry garbage-collect -m /etc/docker/registry/config.yml >> /var/log/registry-gc.log 2>&1' ) | crontab -",
```

This follows the existing staggered pattern (each registry offset by 5 minutes).

**Step 4: Update the VM module comment block**

At lines 266-273, update the port documentation comment to include port 5050:

```hcl
  # All ports go through nginx for request serialization (proxy_cache_lock):
  # 5000 -> nginx -> registry-dockerhub (docker.io proxy)
  # 5001 -> registry-dockerhub direct (Prometheus metrics)
  # 5010 -> nginx -> registry-ghcr (ghcr.io proxy)
  # 5020 -> nginx -> registry-quay (quay.io proxy)
  # 5030 -> nginx -> registry-k8s (registry.k8s.io proxy)
  # 5040 -> nginx -> registry-kyverno (reg.kyverno.io proxy)
  # 5050 -> nginx -> registry-private (R/W registry for CI build cache)
  # 8080 -> registry-ui (joxit/docker-registry-ui)
```

**Step 5: Commit**

```bash
git add stacks/infra/main.tf
git commit -m "[ci skip] add private registry to Terraform cloud-init provisioning"
```

**Note:** This updates the cloud-init template. The running VM won't automatically pick up these changes — it only applies on fresh VM creation from the template. For the running VM, Task 5 deploys the files via SCP. This ensures both the live VM and Terraform state are in sync.

---

### Task 5: Deploy to the running registry VM

Since the registry VM is already running (cloud-init only runs on first boot), we deploy the updated files directly via SSH/SCP for immediate effect.

**Step 1: SSH to the registry VM and create the storage directory**

```bash
ssh root@10.0.20.10 "mkdir -p /opt/registry/data/private"
```

**Step 2: Copy updated files to the VM**

```bash
scp modules/docker-registry/docker-compose.yml root@10.0.20.10:/opt/registry/docker-compose.yml
scp modules/docker-registry/config-private.yml root@10.0.20.10:/opt/registry/config-private.yml
scp modules/docker-registry/nginx_registry.conf root@10.0.20.10:/opt/registry/nginx.conf
```

Note: The nginx config is stored as `/opt/registry/nginx.conf` on the VM (the docker-compose mounts it as `nginx.conf`).

**Step 3: Restart the Docker Compose stack**

```bash
ssh root@10.0.20.10 "cd /opt/registry && docker compose up -d"
```

This will create the new `registry-private` container and reload nginx with the new port.

**Step 4: Add garbage collection cron on the running VM**

```bash
ssh root@10.0.20.10 '( crontab -l 2>/dev/null; echo "25 3 * * 0 /usr/bin/docker exec registry-private registry garbage-collect -m /etc/docker/registry/config.yml >> /var/log/registry-gc.log 2>&1" ) | crontab -'
```

**Step 5: Verify the private registry is accessible**

```bash
curl -s http://10.0.20.10:5050/v2/
# Expected: {} (empty JSON object = registry is up)

curl -s http://10.0.20.10:5050/v2/_catalog
# Expected: {"repositories":[]} (empty, no images pushed yet)
```

---

### Task 6: Add DNS record for registry.viktorbarzin.lan

**Step 1: Add A record via Technitium API**

```bash
# Technitium DNS API endpoint (web UI is on port 5380)
# Get API token from tfvars (technitium_password)
curl -s "http://10.0.20.204:5380/api/zones/records/add?token=<TECHNITIUM_TOKEN>&domain=registry.viktorbarzin.lan&zone=viktorbarzin.lan&type=A&ipAddress=10.0.20.10&overwrite=true"
```

Alternatively, add via Technitium web UI at `https://technitium.viktorbarzin.me`:
- Zone: `viktorbarzin.lan`
- Record: `registry` → A → `10.0.20.10`

**Step 2: Verify DNS resolution from a K8s pod**

```bash
kubectl run -it --rm dns-test --image=alpine --restart=Never -- nslookup registry.viktorbarzin.lan
# Expected: Address: 10.0.20.10
```

**Step 3: Verify registry is accessible via DNS name**

```bash
curl -s http://registry.viktorbarzin.lan:5050/v2/
# Expected: {}
```

---

### Task 7: Update build-cli.yml pipeline with BuildKit caching

**Files:**
- Modify: `.woodpecker/build-cli.yml`

**Step 1: Update the pipeline**

Replace the entire file content with:

```yaml
when:
  event: push

clone:
  git:
    image: woodpeckerci/plugin-git
    settings:
      attempts: 5
      backoff: 10s

steps:
  - name: build-image
    image: woodpeckerci/plugin-docker-buildx
    settings:
      username: "viktorbarzin"
      password:
        from_secret: dockerhub-pat
      repo:
        - viktorbarzin/infra
        - registry.viktorbarzin.lan:5050/infra
      logins:
        - registry: https://index.docker.io/v1/
          username: viktorbarzin
          password:
            from_secret: dockerhub-pat
      dockerfile: cli/Dockerfile
      context: cli
      auto_tag: true
      cache_from: type=registry,ref=registry.viktorbarzin.lan:5050/infra:buildcache
      cache_to: type=registry,ref=registry.viktorbarzin.lan:5050/infra:buildcache,mode=max
      buildkit_config: |
        [registry."registry.viktorbarzin.lan:5050"]
          http = true
          insecure = true
```

Key changes:
- `repo` is now a list — pushes to both Docker Hub and local registry
- `logins` provides Docker Hub credentials explicitly (needed when `repo` is a list)
- `cache_from`/`cache_to` use registry-based BuildKit cache on the local registry
- `buildkit_config` allows HTTP access to the insecure local registry
- `mode=max` caches ALL layers (including intermediate build stages)

**Step 2: Commit**

```bash
git add .woodpecker/build-cli.yml
git commit -m "[ci skip] add BuildKit layer caching and dual-push to build-cli pipeline"
```

---

### Task 8: Update f1-stream.yml pipeline with BuildKit caching

**Files:**
- Modify: `.woodpecker/f1-stream.yml`

**Step 1: Update the pipeline**

Replace the entire file content with:

```yaml
when:
  event: push
  path: "stacks/f1-stream/files/**"

clone:
  git:
    image: woodpeckerci/plugin-git
    settings:
      attempts: 5
      backoff: 10s

steps:
  - name: build-image
    image: woodpeckerci/plugin-docker-buildx
    settings:
      username: "viktorbarzin"
      password:
        from_secret: dockerhub-pat
      repo:
        - viktorbarzin/f1-stream
        - registry.viktorbarzin.lan:5050/f1-stream
      logins:
        - registry: https://index.docker.io/v1/
          username: viktorbarzin
          password:
            from_secret: dockerhub-pat
      dockerfile: stacks/f1-stream/files/Dockerfile
      context: stacks/f1-stream/files
      platforms: linux/amd64
      provenance: false
      tags: latest
      cache_from: type=registry,ref=registry.viktorbarzin.lan:5050/f1-stream:buildcache
      cache_to: type=registry,ref=registry.viktorbarzin.lan:5050/f1-stream:buildcache,mode=max
      buildkit_config: |
        [registry."registry.viktorbarzin.lan:5050"]
          http = true
          insecure = true

  - name: deploy
    image: bitnami/kubectl
    commands:
      - kubectl -n f1-stream rollout restart deployment f1-stream
      - kubectl -n f1-stream rollout status deployment f1-stream --timeout=120s
```

Same pattern as build-cli: dual-push + BuildKit cache. The `deploy` step is unchanged.

**Step 2: Commit**

```bash
git add .woodpecker/f1-stream.yml
git commit -m "[ci skip] add BuildKit layer caching and dual-push to f1-stream pipeline"
```

---

### Task 9: Test end-to-end with a manual build trigger

**Step 1: Push changes to trigger the build-cli pipeline**

```bash
git push origin master
```

The `build-cli.yml` pipeline triggers on every push. Monitor it at `https://ci.viktorbarzin.me`.

**Step 2: Verify cache was populated**

After the first build completes, check the local registry has the cache:

```bash
curl -s http://registry.viktorbarzin.lan:5050/v2/_catalog
# Expected: {"repositories":["infra"]}

curl -s http://registry.viktorbarzin.lan:5050/v2/infra/tags/list
# Expected: tags include "buildcache" and the auto-tagged version
```

**Step 3: Trigger a second build to verify cache hit**

Make a trivial change (e.g., update a comment in `cli/`) and push again. The build logs should show "importing cache manifest from registry.viktorbarzin.lan:5050/infra:buildcache" and skip unchanged layers.

**Step 4: Verify Docker Hub also has the image**

```bash
curl -s https://hub.docker.com/v2/repositories/viktorbarzin/infra/tags/ | python3 -m json.tool | head -20
```

---

### Task 10: Verify cleanup script covers private registry

**Files:**
- Review: `modules/docker-registry/cleanup-tags.sh`

**Step 1: Verify the script already handles multiple registries**

The existing script walks ALL subdirectories under `BASE` (`/opt/registry/data`). Since the private registry stores data at `/opt/registry/data/private/docker/registry/v2/repositories/`, it will automatically be picked up by the existing script without changes.

Verify by reading the script logic — `os.listdir(BASE)` iterates `dockerhub`, `ghcr`, `quay`, `k8s`, `kyverno`, and now `private`.

**Step 2: Consider whether to adjust the keep count**

The default `KEEP=10` may be too aggressive for the private registry since buildcache tags are few (usually just one `buildcache` tag per repo). The script only deletes when there are MORE than `KEEP` tags, so with typically 2-3 tags per repo (e.g., `latest`, `buildcache`, maybe a version tag), no cleanup will happen. This is fine.

No code changes needed — the script already works with the new registry.
