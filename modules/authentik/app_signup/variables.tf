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

variable "initial_users" {
  type        = list(number)
  default     = []
  description = "User pks put in the group when it is created, for people who already use the app. Later changes to this list are ignored, like every other membership change."
}

variable "existing_account_state_prefix" {
  type        = string
  default     = null
  description = "Request mode only: an OAuth state prefix the app puts on authorize requests that ask for access. When set, the module creates an access-request policy (output existing_account_policy_id) for the app stack to bind to its application. An existing account outside the app's groups whose authorize request carries this prefix is then let through to the app, after the policy records attributes.signup_request on it, instead of seeing Authentik's access-denied page."

  validation {
    condition     = var.existing_account_state_prefix == null || can(regex("^[A-Za-z0-9._~-]{2,32}$", var.existing_account_state_prefix))
    error_message = "existing_account_state_prefix is 2 to 32 URL-safe characters (letters, digits, . _ ~ -)."
  }
}
