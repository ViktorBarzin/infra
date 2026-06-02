# Post-Mortem: immich-ml VRAM hog (MODEL_TTL=0) starved llama-swap → recruiter-responder silently down

| Field | Value |
|-------|-------|
| **Date** | 2026-06-02 |
| **Duration** | Triage failing 17:41 → ~20:08 EEST (~2.5 h confirmed in retained logs; first 502 at 17:41) |
| **Severity** | SEV3 — one pipeline (recruiter-responder) fully down; no data loss (emails preserved unseen); no other user-facing impact |
| **Affected** | `recruiter-responder` (triage). Root cause in `immich-machine-learning` + shared T4 GPU. |
| **Status** | Fixed — `immich` `MACHINE_LEARNING_MODEL_TTL` 0 → 600; immich-ml VRAM dropped 10.7 GB → ~1.9 GB; qwen3-8b loads again; backlog reprocessed. |

## Summary

Reported by the operator: "receiving recruiter emails but seeing no responses."
The recruiter-responder IMAP IDLE reader was healthy and fetching mail, but every
email failed at the triage step with `502 Bad Gateway` from llama-swap. llama-swap
could not load its `qwen3-8b` model because the shared Tesla T4 (16 GB) had only
~2.2 GB free — `immich-machine-learning` was holding **10.7 GB** and never released
it. Because triage *raised* (not swallowed), each email was left **unseen** and
retried, so no mail was lost — but no draft/event/Telegram notification was ever
produced.

## Root cause (chain)

```
immich-ml runs with MACHINE_LEARNING_MODEL_TTL=0  →  ModelCache(revalidate=False),
  per-model TTL eviction + idle-shutdown both DISABLED → nothing ever unloads
        ▼
heavy immich library job ~17:17 (metadata + smartSearch + OCR + face) runs OCR
  (PP-OCRv5, dynamic input shapes) → onnxruntime BFC CUDA arena inflates to ~10.7 GB
        ▼
TTL=0 → the arena floor is permanent (onnxruntime doesn't cudaFree between runs;
  only a process restart reclaims it)
        ▼
T4 free VRAM ~2.2 GB  (T4 is time-sliced across immich-ml / immich-server /
  frigate / llama-swap with NO memory isolation)
        ▼
llama-swap gets a qwen3-8b request → llama-server: cudaMalloc 4455 MiB OOM →
  "exiting due to model loading error" → llama-swap returns 502
        ▼
recruiter-responder triage.py raise_for_status() → orchestrator raises →
  imap_idle leaves the message UNSEEN (BODY.PEEK) → no draft/event → no Telegram
```

## Why it was hard to spot

- **Everything showed `Running`/healthy**: the recruiter-responder, llama-swap, and
  immich-ml pods were all `1/1 Running` with 0 restarts. The failure was a runtime
  502, not a crash.
- **`nvidia-smi` inside a container shows "No running processes found"** (PID-namespace
  isolation) — per-process VRAM attribution needed the host-PID `gpu-pod-exporter`
  (`nvidia-smi --query-compute-apps`), which pinned the 10.7 GB on `immich_ml.main`.
- **Silent**: triage errors only landed in recruiter-responder logs; no alert fired
  on llama-swap 5xx or on low GPU free-VRAM. ~440 triage attempts failed before the
  operator noticed organically.

## Resolution

- `stacks/immich/main.tf`: `MACHINE_LEARNING_MODEL_TTL` `0` → `600` (targeted apply of
  `kubernetes_deployment.immich-machine-learning`). The Recreate rollout cleared the
  stuck arena immediately; going forward, idle ad-hoc models (OCR, face) unload after
  600 s and return VRAM, while preloaded CLIP (smart search) stays warm.
- Verified: T4 used 12571 → 3785 MiB (11.1 GB free); immich-ml 10726 → 1940 MiB;
  `qwen3-8b` chat completion returns HTTP 200; recruiter-responder reprocessed its
  unseen backlog with triage `200 OK`.

## Why MODEL_TTL=0 was set (and the correction)

`MODEL_TTL=0` was almost certainly chosen to keep the smart-search model permanently
warm for snappy search. The unintended consequence: it *also* pins every ad-hoc model
(OCR/face) and lets onnxruntime's arena grow unbounded on a GPU it doesn't own alone.
immich has **no per-model TTL** (a single global knob; the idle path kills the whole
worker via `os.kill(getpid(), SIGINT)` and respawns), so the practical compromise is a
moderate global TTL + CLIP preload: CLIP reloads in ~10 s on the rare idle miss, while
OCR/face free their VRAM.

## Follow-ups (not yet done — operator declined hardening this session)

- **Alerting** on (a) GPU free-VRAM below a threshold and (b) llama-swap 5xx /
  recruiter-responder triage failure rate, so a future starvation doesn't sit silent.
  (Operator believes existing alerts cover it — unverified here.)
- **Optional** recruiter-responder resilience: fall back to a smaller model
  (`qwen3vl-4b`) or the Tier-1 GPT relay when llama-swap 502s.
- **Separate pre-existing issue** surfaced in immich-server logs: repeated
  `AssetExtractMetadata` `ENOENT` on `upload/upload/...` paths (missing originals) —
  unrelated to this incident; worth a look.
