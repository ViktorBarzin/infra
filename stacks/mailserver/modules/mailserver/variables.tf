# this is appended and merged to the main postfix.cf
# see defaults - https://github.com/docker-mailserver/docker-mailserver/blob/master/target/postfix/main.cf
variable "postfix_cf" {
  default = <<EOT
#relayhost = [smtp.sendgrid.net]:587
relayhost = [smtp-relay.brevo.com]:587
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl/passwd
smtp_sasl_security_options = noanonymous
smtp_sasl_tls_security_options = noanonymous
smtp_tls_security_level = encrypt
smtpd_tls_cert_file=/tmp/ssl/tls.crt
smtpd_tls_key_file=/tmp/ssl/tls.key
smtpd_use_tls=yes
header_size_limit = 4096000

# Debug mail tls
smtpd_tls_loglevel = 1
#smtpd_tls_ciphers = TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:DHE-RSA-AES128-SHA256:DHE-RSA-AES256-SHA256:!aNULL:!SEED:!CAMELLIA:!RSA+AES:!SHA1
#tls_medium_cipherlist = ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:DHE-RSA-AES128-SHA256:DHE-RSA-AES256-SHA256:!aNULL:!SEED:!CAMELLIA:!RSA+AES:!SHA1

# Rate limiting (brute-force protection)
smtpd_client_connection_rate_limit = 10
smtpd_client_message_rate_limit = 30
anvil_rate_time_unit = 60s

# Disable the postscreen decision cache. The default (btree) driver
# requires an exclusive file lock for every access, and with postscreen
# re-spawning per connection (master.cf: maxproc=1) that produces thousands
# of 'unable to get exclusive lock' fatals per day — stalling SMTP
# acceptance and starving inbound delivery. lmdb would avoid the lock but
# isn't compiled into docker-mailserver 15.0.0's Postfix build
# (postconf -m → no lmdb). Proxy:btree is unsafe because postscreen does
# its own locking. An empty value disables the cache entirely — legitimate
# clients pay the greet/bare-newline re-check on every new TCP session,
# which is trivial at our volume (~100 deliveries/day).
postscreen_cache_map =
EOT
}
