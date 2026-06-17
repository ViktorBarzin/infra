include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

# portal-stt: in-cluster speech-to-text for the portal-assistant Gateway
# (portal-assistant issue #2, ADR-0003). One Deployment of Speaches
# (ghcr.io/speaches-ai/speaches, OpenAI-compatible faster-whisper) serving
# `large-v3-turbo` int8, multilingual (Bulgarian + English), behind a single
# ClusterIP Service `portal-stt.portal-stt.svc:8000`. Transcription path:
# /v1/audio/transcriptions. Requests ONE time-slice of the shared T4
# (nvidia.com/gpu=1) — a slice, not the card.
#
# WARM-RESIDENT (NOT the tts/chatterbox demand-gate): replicas=1, never scaled
# to zero. The model is preloaded at startup (PRELOAD_MODELS) and never unloaded
# (STT_MODEL_TTL=-1) so interactive voice Turns never pay a cold model load.
# Chatterbox can scale 0<->1 because it is best-effort batch narration; STT is
# latency-critical and must stay warm. See portal-assistant CONTEXT.md
# "Warm window".
#
# VRAM safety on the shared T4 (16 GiB, no per-tenant isolation): int8 weights
# budget ~1.5 GiB; worst-case alongside immich-ml (~2.1) + frigate (~1.9) +
# llama-swap qwen3-8b (~4.35) leaves ~6 GiB headroom. This pod is NOT excluded
# from the kyverno gpu-priority policy, so it correctly gets the immich-equal
# `gpu-workload` priority (first-class resident, never evicted first) — the
# inverse of tts. Full VRAM math + the OOM post-mortem reference are in main.tf.
#
# HITL: agent drafts; operator presence-claims the T4 and applies via GitOps,
# then verifies the rollout + a bg/en transcription smoke test.
