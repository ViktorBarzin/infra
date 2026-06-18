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

# Reads the Paperless API over the in-cluster service.
dependency "paperless-ngx" {
  config_path  = "../paperless-ngx"
  skip_outputs = true
}

# LLM (chat/answer generation + auto-tagging) is served by llama-swap's
# OpenAI-compatible endpoint; embeddings/semantic search are local in-pod.
dependency "llama-cpp" {
  config_path  = "../llama-cpp"
  skip_outputs = true
}
