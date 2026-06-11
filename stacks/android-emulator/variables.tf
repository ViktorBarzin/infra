variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "image_tag" {
  type        = string
  default     = "api36-v4"
  description = "android-emulator image tag at forgejo.viktorbarzin.me/viktor/android-emulator. Built + pushed manually from stacks/android-emulator/docker/ (see README.md) — bump this when the image is rebuilt."
}
