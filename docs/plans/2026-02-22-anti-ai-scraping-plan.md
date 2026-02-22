# Anti-AI Scraping System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy a 5-layer anti-AI scraping system that blocks known bots, injects hidden trap links into all HTML responses, serves poisoned content from Poison Fountain, and tarpits scrapers with slow-drip responses.

**Architecture:** A lightweight Python service handles bot detection (ForwardAuth) and poison content serving (tarpit). Traefik middlewares inject anti-AI headers and hidden trap links into all public service responses via ingress_factory defaults. A CronJob refreshes cached poison content from rnsaffn.com.

**Tech Stack:** Python 3 (stdlib http.server), Terraform/Terragrunt, Traefik middleware CRDs, Kubernetes CronJob

---

### Task 1: Create the Python poison service code

**Files:**
- Create: `stacks/poison-fountain/app/server.py`
- Create: `stacks/poison-fountain/app/fetch-poison.sh`

**Step 1: Create the service directory**

```bash
mkdir -p stacks/poison-fountain/app
```

**Step 2: Write `stacks/poison-fountain/app/server.py`**

```python
"""Poison Fountain service.

Endpoints:
  GET /auth       - ForwardAuth: block known AI bot User-Agents (403) or pass (200)
  GET /article/*  - Serve cached poisoned content with tarpit slow-drip
  GET /healthz    - Health check for Kubernetes probes
  GET /*          - Catch-all: serve poison for any path (scrapers explore randomly)
"""

import http.server
import os
import glob
import random
import time
import hashlib
import sys

LISTEN_PORT = int(os.environ.get("PORT", "8080"))
CACHE_DIR = os.environ.get("CACHE_DIR", "/data/cache")
DRIP_BYTES = int(os.environ.get("DRIP_BYTES", "50"))
DRIP_DELAY = float(os.environ.get("DRIP_DELAY", "0.5"))
TRAP_LINK_COUNT = int(os.environ.get("TRAP_LINK_COUNT", "20"))
POISON_DOMAIN = os.environ.get("POISON_DOMAIN", "poison.viktorbarzin.me")

AI_BOT_PATTERNS = [
    "gptbot", "chatgpt-user", "claudebot", "claude-web", "ccbot",
    "bytespider", "google-extended", "applebot-extended",
    "anthropic-ai", "cohere-ai", "diffbot", "facebookbot",
    "perplexitybot", "youbot", "meta-externalagent", "petalbot",
    "amazonbot", "ai2bot", "omgilibot", "img2dataset",
    "omgili", "commoncrawl", "ia_archiver", "scrapy",
    "semrushbot", "ahrefsbot", "dotbot", "mj12bot",
    "seekport", "blexbot", "dataforseo", "serpstatbot",
]

FALLBACK_WORDS = [
    "the", "quantum", "neural", "framework", "implements", "distributed",
    "processing", "with", "advanced", "recursive", "algorithms", "for",
    "optimal", "convergence", "in", "multi-dimensional", "space",
    "utilizing", "transformer", "architecture", "trained", "on",
    "large-scale", "corpus", "data", "achieving", "state-of-the-art",
    "performance", "across", "benchmark", "tasks", "including",
    "natural", "language", "understanding", "generation", "and",
    "cross-lingual", "transfer", "learning", "capabilities",
]


def generate_slug():
    return hashlib.md5(str(random.random()).encode()).hexdigest()[:16]


def generate_trap_links(count):
    titles = [
        "Research Archive", "Training Corpus", "Dataset Export",
        "NLP Benchmark Results", "Web Crawl Index", "Text Corpus",
        "Machine Learning Data", "Evaluation Dataset", "Model Weights",
        "Annotation Guidelines", "Parallel Corpus", "Knowledge Base",
        "Document Collection", "Reference Data", "Taxonomy Index",
        "Classification Labels", "Entity Database", "Relation Extraction",
        "Sentiment Annotations", "Summarization Corpus", "QA Dataset",
        "Dialogue Transcripts", "Code Documentation", "API Reference",
    ]
    links = []
    for _ in range(count):
        slug = generate_slug()
        title = random.choice(titles)
        links.append(f'<a href="https://{POISON_DOMAIN}/article/{slug}">{title}</a>')
    return "\n".join(links)


def get_poison_content():
    cache_files = glob.glob(os.path.join(CACHE_DIR, "*.txt"))
    if cache_files:
        try:
            with open(random.choice(cache_files), "r", errors="replace") as f:
                return f.read()
        except Exception:
            pass
    return " ".join(random.choices(FALLBACK_WORDS, k=500))


class PoisonHandler(http.server.BaseHTTPRequestHandler):
    server_version = "Apache/2.4.52"
    sys_version = ""

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[{self.log_date_time_string()}] {fmt % args}\n")

    def do_GET(self):
        if self.path == "/healthz":
            self._respond(200, "ok")
            return

        if self.path == "/auth":
            self._handle_auth()
            return

        # Everything else gets poison
        self._serve_poison()

    def _handle_auth(self):
        ua = (self.headers.get("User-Agent") or "").lower()
        for pattern in AI_BOT_PATTERNS:
            if pattern in ua:
                self.log_message("BLOCKED AI bot: %s (matched: %s)", ua, pattern)
                self._respond(403, "Forbidden")
                return
        self._respond(200, "OK")

    def _respond(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body.encode())

    def _serve_poison(self):
        content = get_poison_content()
        trap_links = generate_trap_links(TRAP_LINK_COUNT)

        html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Research Data Archive</title>
</head>
<body>
<main>
<article>
<h1>Research Data Collection</h1>
<div class="content">
<p>{content}</p>
</div>
</article>
<nav>
<h2>Related Research</h2>
{trap_links}
</nav>
</main>
</body>
</html>"""

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        for i in range(0, len(html), DRIP_BYTES):
            chunk = html[i : i + DRIP_BYTES].encode("utf-8")
            try:
                self.wfile.write(f"{len(chunk):x}\r\n".encode())
                self.wfile.write(chunk)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
                time.sleep(DRIP_DELAY)
            except (BrokenPipeError, ConnectionResetError):
                return

        try:
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    os.makedirs(CACHE_DIR, exist_ok=True)
    server = http.server.HTTPServer(("0.0.0.0", LISTEN_PORT), PoisonHandler)
    print(f"Poison Fountain service listening on :{LISTEN_PORT}", flush=True)
    server.serve_forever()
```

**Step 3: Write `stacks/poison-fountain/app/fetch-poison.sh`**

```bash
#!/bin/sh
set -e

CACHE_DIR="${CACHE_DIR:-/data/cache}"
POISON_URL="${POISON_URL:-https://rnsaffn.com/poison2/}"
FETCH_COUNT="${FETCH_COUNT:-50}"
MAX_CACHE_FILES="${MAX_CACHE_FILES:-100}"

mkdir -p "$CACHE_DIR"

echo "Fetching $FETCH_COUNT poison documents from $POISON_URL"

fetched=0
for i in $(seq 1 "$FETCH_COUNT"); do
  OUTPUT="$CACHE_DIR/poison_$(date +%s)_${i}.txt"
  if curl -sS --compressed -o "$OUTPUT" -m 30 "$POISON_URL" 2>/dev/null; then
    # Verify file is non-empty
    if [ -s "$OUTPUT" ]; then
      fetched=$((fetched + 1))
      echo "  [$i/$FETCH_COUNT] OK"
    else
      rm -f "$OUTPUT"
      echo "  [$i/$FETCH_COUNT] Empty response, skipped"
    fi
  else
    rm -f "$OUTPUT"
    echo "  [$i/$FETCH_COUNT] Fetch failed, skipped"
  fi
  sleep 2
done

# Clean up oldest files if cache exceeds limit
total=$(find "$CACHE_DIR" -name '*.txt' -type f | wc -l)
if [ "$total" -gt "$MAX_CACHE_FILES" ]; then
  excess=$((total - MAX_CACHE_FILES))
  find "$CACHE_DIR" -name '*.txt' -type f -printf '%T+ %p\n' | \
    sort | head -n "$excess" | cut -d' ' -f2- | xargs rm -f
  echo "Cleaned $excess old cache files"
fi

echo "Done: fetched $fetched new documents, $(find "$CACHE_DIR" -name '*.txt' -type f | wc -l) total cached"
```

**Step 4: Verify files exist**

```bash
ls -la stacks/poison-fountain/app/
```

Expected: `server.py` and `fetch-poison.sh` listed.

**Step 5: Commit**

```bash
git add stacks/poison-fountain/app/
git commit -m "[ci skip] Add poison fountain Python service and fetcher script"
```

---

### Task 2: Set up NFS export and DNS record

**Files:**
- Modify: `secrets/nfs_directories.txt` (add `poison-fountain/cache` line, keep sorted)
- Modify: `terraform.tfvars` (add `poison` to `cloudflare_non_proxied_names`)

**Step 1: Add NFS directory**

Add `poison-fountain` and `poison-fountain/cache` to `secrets/nfs_directories.txt`, keeping alphabetical order. Insert after `plotting-book` entries.

**Step 2: Run NFS export script**

```bash
cd secrets && bash nfs_exports.sh
```

Verify the export was created successfully.

**Step 3: Add Cloudflare DNS record**

In `terraform.tfvars`, find the `cloudflare_non_proxied_names` list and add `"poison"` to it (alphabetical position after `"plotting-book"`).

**Step 4: Commit**

```bash
git add secrets/nfs_directories.txt terraform.tfvars
git commit -m "[ci skip] Add NFS export and DNS record for poison-fountain"
```

---

### Task 3: Add Traefik middleware CRDs

**Files:**
- Modify: `stacks/platform/modules/traefik/middleware.tf` (append 3 new middleware resources)

**Step 1: Add `ai-bot-block` ForwardAuth middleware**

Append to the end of `stacks/platform/modules/traefik/middleware.tf`:

```hcl
# ForwardAuth middleware to block known AI bot User-Agents
resource "kubernetes_manifest" "middleware_ai_bot_block" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ai-bot-block"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      forwardAuth = {
        address            = "http://poison-fountain.poison-fountain.svc.cluster.local:8080/auth"
        trustForwardHeader = true
      }
    }
  }

  depends_on = [helm_release.traefik]
}
```

**Step 2: Add `anti-ai-headers` middleware**

Append to the end of `stacks/platform/modules/traefik/middleware.tf`:

```hcl
# X-Robots-Tag header to discourage compliant AI crawlers
resource "kubernetes_manifest" "middleware_anti_ai_headers" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "anti-ai-headers"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      headers = {
        customResponseHeaders = {
          "X-Robots-Tag" = "noai, noimageai"
        }
      }
    }
  }

  depends_on = [helm_release.traefik]
}
```

**Step 3: Add `anti-ai-trap-links` rewrite-body middleware**

Append to the end of `stacks/platform/modules/traefik/middleware.tf`:

```hcl
# Inject hidden trap links before </body> to catch AI scrapers
# Links are CSS-hidden and aria-hidden so humans never see them
resource "kubernetes_manifest" "middleware_anti_ai_trap_links" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "anti-ai-trap-links"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      plugin = {
        rewrite-body = {
          rewrites = [{
            regex       = "</body>"
            replacement = "<div style=\"position:absolute;left:-9999px;height:0;overflow:hidden\" aria-hidden=\"true\"><a href=\"https://poison.viktorbarzin.me/article/training-data-2024-research-corpus\">Research Archive</a><a href=\"https://poison.viktorbarzin.me/article/dataset-export-machine-learning-v3\">Dataset Export</a><a href=\"https://poison.viktorbarzin.me/article/nlp-benchmark-evaluation-results\">Benchmark Results</a><a href=\"https://poison.viktorbarzin.me/article/web-crawl-index-2024-archive\">Web Index</a><a href=\"https://poison.viktorbarzin.me/article/text-corpus-english-dump\">Text Corpus</a></div></body>"
          }]
          monitoring = {
            types = ["text/html"]
          }
        }
      }
    }
  }

  depends_on = [helm_release.traefik]
}
```

**Step 4: Verify syntax**

```bash
cd stacks/platform && terraform fmt -check modules/traefik/middleware.tf || terraform fmt modules/traefik/middleware.tf
```

**Step 5: Commit**

```bash
git add stacks/platform/modules/traefik/middleware.tf
git commit -m "[ci skip] Add anti-AI scraping Traefik middlewares (ForwardAuth, headers, trap links)"
```

---

### Task 4: Update ingress_factory to apply anti-AI middlewares by default

**Files:**
- Modify: `modules/kubernetes/ingress_factory/main.tf` (add variable + middleware references)

**Step 1: Add `anti_ai_scraping` variable**

In `modules/kubernetes/ingress_factory/main.tf`, add after the `skip_default_rate_limit` variable (around line 73):

```hcl
variable "anti_ai_scraping" {
  type    = bool
  default = true
}
```

**Step 2: Add middlewares to the chain**

In the `kubernetes_ingress_v1` resource's `router.middlewares` annotation (around line 108-117), add 3 new lines for anti-AI middlewares. The updated `concat` list should include:

```hcl
var.anti_ai_scraping ? "traefik-ai-bot-block@kubernetescrd" : null,
var.anti_ai_scraping ? "traefik-anti-ai-headers@kubernetescrd" : null,
var.anti_ai_scraping ? "traefik-strip-accept-encoding@kubernetescrd" : null,
var.anti_ai_scraping ? "traefik-anti-ai-trap-links@kubernetescrd" : null,
```

Insert these after the existing `crowdsec` line (line 111) and before the `protected` line (line 112). The full `concat` array becomes:

```hcl
"traefik.ingress.kubernetes.io/router.middlewares" = join(",", compact(concat([
  var.skip_default_rate_limit ? null : "traefik-rate-limit@kubernetescrd",
  var.custom_content_security_policy == null ? "traefik-csp-headers@kubernetescrd" : null,
  var.exclude_crowdsec ? null : "traefik-crowdsec@kubernetescrd",
  var.anti_ai_scraping ? "traefik-ai-bot-block@kubernetescrd" : null,
  var.anti_ai_scraping ? "traefik-anti-ai-headers@kubernetescrd" : null,
  var.anti_ai_scraping ? "traefik-strip-accept-encoding@kubernetescrd" : null,
  var.anti_ai_scraping ? "traefik-anti-ai-trap-links@kubernetescrd" : null,
  var.protected ? "traefik-authentik-forward-auth@kubernetescrd" : null,
  var.allow_local_access_only ? "traefik-local-only@kubernetescrd" : null,
  var.rybbit_site_id != null ? "traefik-strip-accept-encoding@kubernetescrd" : null,
  var.rybbit_site_id != null ? "${var.namespace}-rybbit-analytics-${var.name}@kubernetescrd" : null,
  var.custom_content_security_policy != null ? "${var.namespace}-custom-csp-${var.name}@kubernetescrd" : null,
], var.extra_middlewares)))
```

**Step 3: Format**

```bash
terraform fmt modules/kubernetes/ingress_factory/main.tf
```

**Step 4: Commit**

```bash
git add modules/kubernetes/ingress_factory/main.tf
git commit -m "[ci skip] Add anti_ai_scraping option to ingress_factory (default: true)"
```

---

### Task 5: Create the poison-fountain Terraform stack

**Files:**
- Create: `stacks/poison-fountain/terragrunt.hcl`
- Create: `stacks/poison-fountain/main.tf`
- Create: `stacks/poison-fountain/secrets` (symlink)

**Step 1: Create terragrunt.hcl**

Write `stacks/poison-fountain/terragrunt.hcl`:

```hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}
```

**Step 2: Create secrets symlink**

```bash
ln -s ../../secrets stacks/poison-fountain/secrets
```

**Step 3: Write `stacks/poison-fountain/main.tf`**

```hcl
variable "tls_secret_name" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

resource "kubernetes_namespace" "poison_fountain" {
  metadata {
    name = "poison-fountain"
    labels = {
      "istio-injection" = "disabled"
      tier              = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.poison_fountain.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# ConfigMap for the Python service code
resource "kubernetes_config_map" "poison_fountain_code" {
  metadata {
    name      = "poison-fountain-code"
    namespace = kubernetes_namespace.poison_fountain.metadata[0].name
  }

  data = {
    "server.py" = file("${path.module}/app/server.py")
  }
}

# ConfigMap for the fetcher script
resource "kubernetes_config_map" "poison_fountain_fetcher" {
  metadata {
    name      = "poison-fountain-fetcher"
    namespace = kubernetes_namespace.poison_fountain.metadata[0].name
  }

  data = {
    "fetch-poison.sh" = file("${path.module}/app/fetch-poison.sh")
  }
}

# Main service deployment
resource "kubernetes_deployment" "poison_fountain" {
  metadata {
    name      = "poison-fountain"
    namespace = kubernetes_namespace.poison_fountain.metadata[0].name
    labels = {
      app  = "poison-fountain"
      tier = local.tiers.aux
    }
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "poison-fountain"
      }
    }
    template {
      metadata {
        labels = {
          app = "poison-fountain"
        }
      }
      spec {
        container {
          name  = "poison-fountain"
          image = "python:3.12-slim"
          command = ["python", "/app/server.py"]

          port {
            container_port = 8080
          }

          env {
            name  = "CACHE_DIR"
            value = "/data/cache"
          }
          env {
            name  = "DRIP_BYTES"
            value = "50"
          }
          env {
            name  = "DRIP_DELAY"
            value = "0.5"
          }
          env {
            name  = "POISON_DOMAIN"
            value = "poison.viktorbarzin.me"
          }

          volume_mount {
            name       = "code"
            mount_path = "/app"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "code"
          config_map {
            name = kubernetes_config_map.poison_fountain_code.metadata[0].name
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/poison-fountain"
          }
        }
      }
    }
  }
}

# Internal service (for ForwardAuth from Traefik)
resource "kubernetes_service" "poison_fountain" {
  metadata {
    name      = "poison-fountain"
    namespace = kubernetes_namespace.poison_fountain.metadata[0].name
    labels = {
      app = "poison-fountain"
    }
  }

  spec {
    selector = {
      app = "poison-fountain"
    }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

# Public ingress for the poison trap subdomain
# Deliberately NO rate limiting, NO CrowdSec, NO anti-AI (we WANT scrapers here)
module "ingress" {
  source                = "../../modules/kubernetes/ingress_factory"
  namespace             = kubernetes_namespace.poison_fountain.metadata[0].name
  name                  = "poison-fountain"
  host                  = "poison"
  port                  = 8080
  tls_secret_name       = var.tls_secret_name
  skip_default_rate_limit = true
  exclude_crowdsec      = true
  anti_ai_scraping      = false
}

# CronJob to fetch and cache poisoned content from Poison Fountain
resource "kubernetes_cron_job_v1" "poison_fetcher" {
  metadata {
    name      = "poison-fountain-fetcher"
    namespace = kubernetes_namespace.poison_fountain.metadata[0].name
  }

  spec {
    schedule                      = "0 */6 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 1
    concurrency_policy            = "Forbid"

    job_template {
      metadata {
        name = "poison-fountain-fetcher"
      }
      spec {
        template {
          metadata {
            name = "poison-fountain-fetcher"
          }
          spec {
            container {
              name    = "fetcher"
              image   = "curlimages/curl:latest"
              command = ["sh", "/scripts/fetch-poison.sh"]

              env {
                name  = "CACHE_DIR"
                value = "/data/cache"
              }
              env {
                name  = "POISON_URL"
                value = "https://rnsaffn.com/poison2/"
              }
              env {
                name  = "FETCH_COUNT"
                value = "50"
              }

              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
            }

            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map.poison_fountain_fetcher.metadata[0].name
                default_mode = "0755"
              }
            }
            volume {
              name = "data"
              nfs {
                server = "10.0.10.15"
                path   = "/mnt/main/poison-fountain"
              }
            }

            restart_policy = "Never"
          }
        }
      }
    }
  }
}
```

**Step 4: Format and validate**

```bash
terraform fmt stacks/poison-fountain/main.tf
cd stacks/poison-fountain && terragrunt validate --non-interactive
```

**Step 5: Commit**

```bash
git add stacks/poison-fountain/
git commit -m "[ci skip] Add poison-fountain Terraform stack (deployment, service, ingress, CronJob)"
```

---

### Task 6: Deploy the platform stack (Traefik middlewares + DNS)

**Step 1: Plan**

```bash
cd stacks/platform && terragrunt plan --non-interactive 2>&1 | tail -40
```

Expected: New resources for the 3 middleware CRDs + Cloudflare DNS record for `poison`. Changes to existing ingress resources (new middleware annotations).

Review the plan output carefully. The key additions should be:
- `kubernetes_manifest.middleware_ai_bot_block`
- `kubernetes_manifest.middleware_anti_ai_headers`
- `kubernetes_manifest.middleware_anti_ai_trap_links`
- Cloudflare DNS record for `poison`
- Modified ingress annotations on all services in the platform stack

**Step 2: Apply**

```bash
cd stacks/platform && terragrunt apply --non-interactive 2>&1 | tail -40
```

**Step 3: Verify middlewares exist**

```bash
kubectl --kubeconfig $(pwd)/config get middlewares.traefik.io -n traefik | grep -E "ai-bot-block|anti-ai"
```

Expected: 3 middleware resources listed.

---

### Task 7: Deploy the poison-fountain stack

**Step 1: Plan**

```bash
cd stacks/poison-fountain && terragrunt plan --non-interactive 2>&1 | tail -30
```

Expected: New namespace, configmaps, deployment, service, ingress, CronJob.

**Step 2: Apply**

```bash
cd stacks/poison-fountain && terragrunt apply --non-interactive 2>&1 | tail -30
```

**Step 3: Monitor pod startup**

Spawn a background agent to watch the pod come up:

```bash
kubectl --kubeconfig $(pwd)/config get pods -n poison-fountain -w
```

Expected: Pod reaches `Running` state with `1/1` ready.

**Step 4: Trigger the first poison cache fetch**

```bash
kubectl --kubeconfig $(pwd)/config create job --from=cronjob/poison-fountain-fetcher poison-fetch-initial -n poison-fountain
```

Watch the job complete:

```bash
kubectl --kubeconfig $(pwd)/config logs -n poison-fountain -l job-name=poison-fetch-initial -f
```

Expected: Fetched N poison documents.

---

### Task 8: Verify the full system

**Step 1: Verify ForwardAuth blocks AI bots**

```bash
curl -s -o /dev/null -w "%{http_code}" -H "User-Agent: GPTBot/1.0" https://echo.viktorbarzin.me/
```

Expected: `403`

**Step 2: Verify legitimate users pass through**

```bash
curl -s -o /dev/null -w "%{http_code}" -H "User-Agent: Mozilla/5.0" https://echo.viktorbarzin.me/
```

Expected: `200`

**Step 3: Verify X-Robots-Tag header**

```bash
curl -sI https://echo.viktorbarzin.me/ 2>/dev/null | grep -i x-robots-tag
```

Expected: `X-Robots-Tag: noai, noimageai`

**Step 4: Verify hidden trap links in HTML**

```bash
curl -s https://echo.viktorbarzin.me/ | grep -o "poison.viktorbarzin.me"
```

Expected: Multiple matches (trap links injected before `</body>`).

**Step 5: Verify poison service serves content with tarpit**

```bash
timeout 10 curl -s -H "User-Agent: Mozilla/5.0" https://poison.viktorbarzin.me/article/test 2>/dev/null | head -5
```

Expected: HTML content starting to arrive slowly (only a few lines in 10 seconds due to tarpit).

**Step 6: Run cluster health check**

```bash
bash scripts/cluster_healthcheck.sh --quiet
```

Expected: No new WARN/FAIL related to poison-fountain.

**Step 7: Commit all applied state**

```bash
git add -A && git status
```

Review for any uncommitted changes, commit if needed.
