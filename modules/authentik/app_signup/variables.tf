variable "app_slug" {
  type        = string
  description = "Slug of the Authentik application people sign up for. The sign-up flow matches it against the application behind the client_id of the authorize request the person arrived with."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.app_slug))
    error_message = "app_slug is an Authentik application slug: lowercase letters, digits and dashes."
  }
}

variable "group_name" {
  type        = string
  description = "Name of the app's member group, \"<App> Users\" by convention. The module creates it."
}

variable "mode" {
  type        = string
  description = "\"open\" adds new accounts to the group during sign-up. \"request\" creates them with no group and leaves approval to the app."

  validation {
    condition     = contains(["open", "request"], var.mode)
    error_message = "mode is \"open\" or \"request\"."
  }
}

variable "pending_url" {
  type        = string
  default     = null
  description = "Request mode only: the https:// page in the app a person lands on after signing up, which tells them the request is waiting."
}
