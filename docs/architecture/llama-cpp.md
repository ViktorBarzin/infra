# llama-cpp / llama-swap

## Overview

In-cluster, OpenAI-compatible vision-LLM endpoint. A single
`mostlygeek/llama-swap:cuda` Deployment fronts three GGUF models
served by `llama.cpp`'s `llama-server` subprocesses, hot-swapped on
demand by `llama-swap`. One Service, one `/v1` endpoint, model
selected by the request body `model` field.

Initial use case: vision-LLM benchmark on a curated Immich album,
choosing between **Qwen3-VL-8B**, **MiniCPM-V-4.5**, and
**Qwen3-VL-4B** for instagram-poster's candidate-scoring path.
Future consumers (Home Assistant, agentic tooling) can hit the same
endpoint via LiteLLM at the cluster gateway.

## Why llama.cpp + llama-swap (not Ollama)

Verified across 7+7 research/challenger subagents (2026-05-10):

- **Broader OpenAI-compat surface** — `tool_choice`, `image_url`
  remote URLs, native bearer auth via `--api-key`, `/reranking`,
  Anthropic `/v1/messages` shim.
- **Native observability** — `/metrics`, `/health` returns 503 during
  model load (proper K8s startup-probe semantics), `/slots` per-slot
  tracking. Ollama still has the `/metrics` issue
  [#3144](https://github.com/ollama/ollama/issues/3144) open.
- **Stricter structured output** — native GBNF on `/completion`,
  JSON-schema-to-GBNF converter, optional `LLAMA_LLGUIDANCE=ON`.
- **Vision coverage for our targets** — llama.cpp ≥ b9095 supports
  Qwen3-VL and MiniCPM-V-4.5 natively; Ollama needs the official
  `qwen3-vl` tag (community GGUFs broken — split-mmproj
  [#14575](https://github.com/ollama/ollama/issues/14575)) and the
  `openbmb/minicpm-v4.5` Ollama tag is 8 months stale.

Ollama still wins for Llama-3.2-Vision (`mllama` cross-attention) and
ecosystem polish (Go/JS SDKs, langchain-ollama, n8n nodes, HA built-in)
— the latter is mooted by fronting llama.cpp with **LiteLLM** at the
gateway.

## Components

| Component | Resource | Purpose |
|-----------|----------|---------|
| llama-swap Deployment | `kubernetes_deployment.llama_swap` | One pod, one OpenAI-compat endpoint, hot-swaps model subprocesses |
| llama-swap ConfigMap | `kubernetes_config_map.llama_swap_config` | YAML model entries (cmd, ttl, checkEndpoint) |
| llama-swap Service | `kubernetes_service.llama_swap` | ClusterIP `:8080` → `llama-swap.llama-cpp.svc.cluster.local` |
| Models PVC | `module.nfs_models` (NFS-RWX `/srv/nfs-ssd/llamacpp`) | Shared GGUF store, 30Gi |
| Download Job | `kubernetes_job_v1.download_models` | Pulls Q4_K_M GGUF + mmproj per model, creates stable `model.gguf` / `mmproj.gguf` symlinks, warms page cache |

## Storage

NFS-SSD on the Proxmox host (`192.168.1.127:/srv/nfs-ssd/llamacpp`).
Cold model load is ~40s × 3 startups ≈ 2 min in a 25-30 min benchmark
run (<10%). The download Job warms the kernel page cache after pulling
GGUFs so first inference reads from warm cache.

If steady-state cold-load latency becomes a problem, **Path B**: carve
~50Gi from a Proxmox SSD as an LV, attach as a vdisk to k8s-node1,
mount on-host, expose via a static `kubernetes_persistent_volume` with
`local` source + node1 affinity. NVMe-class load times. Out of scope
for the initial deployment.

## GPU allocation

The llama-swap pod requests `nvidia.com/gpu: 1` (whole-T4
allocation). The shared T4 is also used by Immich's ML pod
(`immich.immich-machine-learning`); only one of the two can hold the
GPU at a time. Operator must scale immich-ml to 0 before running a
benchmark and restore it after:

```bash
kubectl scale -n immich deploy/immich-machine-learning --replicas=0
# ... benchmark ...
kubectl scale -n immich deploy/immich-machine-learning --replicas=1
```

## Models served

| ID | HF repo | Quant | Ctx | mmproj |
|----|---------|-------|-----|--------|
| `qwen3vl-8b` | `Qwen/Qwen3-VL-8B-Instruct-GGUF` | Q4_K_M | 3072 | yes |
| `minicpm-v-4-5` | `openbmb/MiniCPM-V-4_5-gguf` | Q4_K_M | 3072 | yes |
| `qwen3vl-4b` | `Qwen/Qwen3-VL-4B-Instruct-GGUF` | Q4_K_M | 3072 | yes |

llama.cpp build pinned via the `llama-swap:cuda` image (ships a
recent llama.cpp ≥ b9095, which includes Qwen3-VL projection fix
[#20899](https://github.com/ggml-org/llama.cpp/issues/20899) and
mtmd Flash-Attention regression fix
[#16962](https://github.com/ggml-org/llama.cpp/issues/16962)).

## Endpoints

- `GET /v1/models` — list configured models
- `POST /v1/chat/completions` — standard OpenAI chat (vision via
  `image_url` content parts, base64 or remote URL)
- `POST /completion` — llama.cpp native completion (preferred for
  GBNF-constrained structured output to avoid 2026 regression magnet
  on `/v1/chat/completions`)
- `GET /metrics` — Prometheus
- `GET /health` — 200 once a model is fully loaded; 503 during load

## Known issues / decisions

- **Cluster-wide GPU contention** — only one of llama-swap or
  immich-ml can hold the T4. No GPU sharing solution wired in
  (MPS/MIG would help but T4 has no MIG and MPS is overkill for two
  workloads).
- **Filename-agnostic config** — the download Job creates stable
  `model.gguf` / `mmproj.gguf` symlinks per model dir so the
  llama-swap config doesn't need to track exact HF filenames (which
  change between releases).
- **TF schema** — `llama-cpp` (PG backend on dbaas).
