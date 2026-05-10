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

# llama-cpp: in-cluster vision-LLM server. One Deployment of
# `mostlygeek/llama-swap:cuda` fronts three models (qwen3vl-8b,
# minicpm-v-4-5, qwen3vl-4b) at a single OpenAI-compat /v1 endpoint
# on Service `llama-swap`. llama-swap loads/unloads per-model
# llama-server subprocesses on demand (idle TTL 10 min). The T4 is
# allocated wholly to this pod; immich-ml must be scaled to 0 during
# benchmark runs. See infra/docs/architecture/llama-cpp.md for the
# full rationale (build ≥ b6907 for Qwen3-VL, T4 FP16/INT4 only,
# llama-swap over Ollama, etc.).
