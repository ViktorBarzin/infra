# =============================================================================
# Platform Stack — Empty Shell (all modules extracted)
# =============================================================================
#
# All modules have been extracted to independent stacks.
# This stack remains as a dependency target for 72+ app stacks
# that declare `dependency "platform" { skip_outputs = true }`.
#
# Outputs are kept as variable pass-throughs for any stacks
# that may read them (though most use skip_outputs = true).
# =============================================================================

variable "tls_secret_name" { type = string }
variable "redis_host" { type = string }
variable "postgresql_host" { type = string }
variable "mysql_host" { type = string }
variable "mail_host" { type = string }

output "tls_secret_name" {
  value = var.tls_secret_name
}

output "redis_host" {
  value = var.redis_host
}

output "postgresql_host" {
  value = var.postgresql_host
}

output "postgresql_port" {
  value = 5432
}

output "mysql_host" {
  value = var.mysql_host
}

output "mysql_port" {
  value = 3306
}

output "smtp_host" {
  value = var.mail_host
}

output "smtp_port" {
  value = 587
}
