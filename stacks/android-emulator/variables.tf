variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "android-emulator image tag at ghcr.io/viktorbarzin/android-emulator. Built by GHA (.github/workflows/build-android-emulator.yml) on changes to stacks/android-emulator/docker/ (ADR-0002). :latest tracks the newest build."
}
