include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

# portal-tts: in-cluster text-to-speech for the portal-assistant Gateway
# (portal-assistant issue #3, ADR-0003). One ALWAYS-ON Deployment of Piper
# (ghcr.io/matatonic/openedai-speech-min, OpenAI-compatible /v1/audio/speech)
# serving Bulgarian `bg_BG-dimitar-medium` + English `en_US-lessac-medium`, voice
# chosen PER REQUEST, behind a single ClusterIP Service
# `portal-tts.portal-tts.svc:8000`. Speech path: /v1/audio/speech.
#
# CPU-ONLY: Piper is a fast CPU neural TTS — NO GPU node selector / toleration /
# nvidia.com/gpu request. This deliberately keeps TTS off the OOM-prone shared
# T4 (the two GPU siblings tts/chatterbox + portal-stt already contend for it);
# Bulgarian isn't available on chatterbox anyway (ADR-0003). replicas=1, never
# scaled to zero — no off-peak gate needed when there's no GPU to free.
#
# Voices live on an NFS-SSD PVC, downloaded from rhasspy/piper-voices by an init
# container on first boot (both .onnx + .onnx.json), then persist. A ConfigMap
# supplies voice_to_speaker.yaml mapping request voice "bg"/"en" -> .onnx model.
#
# PLUGGABLE: ADR-0003 keeps TTS a swappable backend with edge-tts as an online
# Bulgarian fallback — that switch is Gateway-side; nothing here changes for it.
#
# nfs_server comes from config.tfvars (192.168.1.127) via the root inputs.
#
# HITL: agent drafts; operator applies via GitOps, then verifies the rollout +
# a bg/en /v1/audio/speech smoke test (curl returns audio bytes).
