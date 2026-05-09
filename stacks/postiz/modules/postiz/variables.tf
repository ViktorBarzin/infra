variable "tls_secret_name" {
  type        = string
  sensitive   = true
  description = "Name of the wildcard TLS Secret to copy into the postiz namespace."
}

variable "tier" {
  type        = string
  description = "Workload tier label applied to the namespace (e.g. 4-aux)."
}

variable "namespace" {
  type        = string
  default     = "postiz"
  description = "Kubernetes namespace for Postiz."
}

variable "host" {
  type        = string
  default     = "postiz"
  description = "Ingress hostname label (joined with root_domain by ingress_factory)."
}

variable "image_tag" {
  type        = string
  default     = "v2.21.7"
  description = "Postiz container image tag."
}

variable "chart_version" {
  type        = string
  default     = "1.0.5"
  description = "Postiz Helm chart version (OCI ghcr.io/gitroomhq/postiz-helmchart)."
}

variable "storage_size" {
  type        = string
  default     = "20Gi"
  description = "Persistent volume size for /uploads."
}
