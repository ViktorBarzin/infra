# Inputs for one Windows app under Wine (ADR-0035). README.md explains the
# app contract (app.env + install.sh) and how to add a new app.

# --- Identity ------------------------------------------------------------------

variable "name" {
  type        = string
  description = "App slug, a DNS label. The Deployment, Services, PVC and ingress names derive from it."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.name))
    error_message = "name is a DNS label: a lowercase letter, then lowercase letters, digits and dashes."
  }
}

variable "title" {
  type        = string
  description = "Human name shown on the waiting page and the homepage tile, e.g. \"iVMS-4200\"."
}

variable "namespace" {
  type        = string
  description = "Namespace, created by the calling stack (it owns the tier label and any network policy)."
}

variable "host" {
  type        = string
  description = "Hostname label under viktorbarzin.me, e.g. \"ivms\"."
}

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "allowed_groups" {
  type        = list(string)
  default     = ["Home Server Admins"]
  description = "Authentik groups that may open the app (ingress_factory allowed_groups; ADR-0031 for non-admin groups)."
}

# --- The app -------------------------------------------------------------------

variable "app_files" {
  type        = map(string)
  description = "Files mounted read-only at /app: at least app.env and install.sh (contract in README.md and images/wine-app/README.md)."

  validation {
    condition     = contains(keys(var.app_files), "app.env") && contains(keys(var.app_files), "install.sh")
    error_message = "app_files needs app.env and install.sh."
  }
}

variable "image" {
  type        = string
  default     = "ghcr.io/viktorbarzin/wine-app"
  description = "The generic Wine + noVNC base image (images/wine-app), public."
}

variable "image_tag" {
  type        = string
  description = "Exact base image tag (a commit sha built by .github/workflows/build-wine-app.yml). Never latest: a rebuilt base can move Wine."
}

# --- Resources -----------------------------------------------------------------

variable "memory_request" {
  type        = string
  description = "Memory request. Size it from the app's spike (iVMS: about 3.2 GB PSS while idle)."
}

variable "memory_limit" {
  type        = string
  description = "Memory limit. Includes the /dev/shm emptyDir, which counts against it."
}

variable "cpu_request" {
  type    = string
  default = "500m"
  # No CPU limit: cluster-wide rule (CFS throttling).
}

variable "shm_size" {
  type        = string
  default     = "1Gi"
  description = "Size of the Memory-backed /dev/shm. Wine and the X server use shared memory; the Kubernetes default of 64Mi is too small."
}

variable "storage_size" {
  type        = string
  default     = "10Gi"
  description = "Initial size of the encrypted PVC that holds the Wine prefix (app install plus its state). The autoresizer grows it up to storage_limit."
}

variable "storage_limit" {
  type    = string
  default = "40Gi"
}

# --- Sleep ---------------------------------------------------------------------

variable "idle_no_viewer_seconds" {
  type        = number
  default     = 1800
  description = "Sleep after this long with no noVNC viewer connected."
}

variable "idle_no_input_seconds" {
  type        = number
  default     = 7200
  description = "Sleep after this long with no keyboard or mouse input, even with a viewer connected (a forgotten tab reconnects forever)."
}

# --- Backup --------------------------------------------------------------------

variable "nfs_server" {
  type        = string
  description = "var.nfs_server from the stack. Backups go to /srv/nfs/<name>-backup."
}

variable "backup_schedule" {
  type        = string
  default     = "40 3 * * *"
  description = "When the prefix is copied to NFS. The app is normally asleep then; the job waits for the volume if it is attached elsewhere."
}
