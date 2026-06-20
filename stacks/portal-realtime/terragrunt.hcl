include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

# portal-realtime — the v2 full-duplex voice agent (Pipecat). One persistent
# WebSocket per conversation: continuous mic audio -> Silero VAD turn-taking ->
# Whisper STT (portal-stt) -> streaming Claude brain (claude-agent-service) ->
# edge-tts (portal-tts) -> audio out, with barge-in. Reuses all three upstream
# cluster services; nothing new is spun up. Public Cloudflare ingress (proxied,
# WebSocket) with the app's own DEVICE_TOKEN as the edge gate. Sibling to
# portal-assistant (the v1 tap-to-talk gateway, still live). portal-assistant
# realtime Phase 3.
