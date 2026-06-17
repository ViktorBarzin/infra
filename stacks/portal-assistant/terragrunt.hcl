include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

# portal-assistant gateway — the voice-assistant orchestrator (STT -> Brain ->
# TTS). v1 is ClusterIP-only (E2E proven in-cluster); the public Cloudflare
# ingress for the Portal app is added next. In-memory sessions for now (no
# SESSION_DB_DSN); CNPG Postgres is a later add. portal-assistant issue #10.
