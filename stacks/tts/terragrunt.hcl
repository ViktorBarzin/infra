include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

dependency "vault" {
  config_path  = "../vault"
  skip_outputs = true
}

# tts: in-cluster text-to-speech for tripit's "Tour guide" narration.
# One Deployment of `forgejo.viktorbarzin.me/viktor/chatterbox-tts` (devnen
# Chatterbox-TTS-Server, OpenAI-compatible /v1/audio/speech) at a single
# ClusterIP Service `chatterbox-tts.tts.svc:8000` (server listens on 8004;
# the Service remaps). Requests ONE time-slice of the shared T4
# (nvidia.com/gpu=1) — a slice, not the card.
#
# OOM-avoidance (Option A, docs/plans/2026-06-08-chatterbox-tts-infra.md §3):
# the Deployment sits at replicas=0; an off-peak CronJob scales it to 1 at the
# 02:00–06:00 Europe/London window ONLY IF a free-VRAM preflight passes
# (gpu_pod_memory_used_bytes from gpu-pod-exporter), a guard CronJob yields the
# card mid-window if a resident wakes, and a window-down CronJob scales back to
# 0. tripit's bake is best-effort + cached-forever (ADR-0002/0004), so a
# skipped/aborted window simply backfills next time — no latency SLA.
#
# Polite-tenant hardening: the `tts` namespace must be EXCLUDED from the kyverno
# `inject-gpu-workload-priority` policy (a separate two-line edit to the kyverno
# stack) so Chatterbox keeps tier-2-gpu priority (600000) and is always the pod
# evicted under pressure — never immich-ml/frigate/llama-swap.
#
# Image is built from the devnen repo + pushed to Forgejo — see this stack's
# README.md for the exact docker build + push commands.
