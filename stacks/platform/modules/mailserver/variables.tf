# this is appended and merged to the main postfix.cf
# see defaults - https://github.com/docker-mailserver/docker-mailserver/blob/master/target/postfix/main.cf
variable "postfix_cf" {
  default = <<EOT
#relayhost = [smtp.sendgrid.net]:587
relayhost = [smtp.eu.mailgun.org]:587
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
EOT
}

variable "postfix_cf_reference_DO_NOT_USE" {
  default = <<EOT
# See /usr/share/postfix/main.cf.dist for a commented, more complete version

smtpd_banner = $myhostname ESMTP $mail_name (Debian)
biff = no
append_dot_mydomain = no
readme_directory = no

# Basic configuration
# myhostname =
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
mydestination = $myhostname, localhost.$mydomain, localhost
mynetworks = 127.0.0.0/8 [::1]/128 [fe80::]/64 
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = all
inet_protocols = ipv4

# TLS parameters
smtpd_tls_cert_file=/tmp/ssl/tls.crt
smtpd_tls_key_file=/tmp/ssl/tls.key
#smtpd_tls_CAfile=
#smtp_tls_CAfile=
smtpd_tls_security_level = may
smtpd_use_tls=yes
smtpd_tls_loglevel = 1
smtp_tls_loglevel = 1
tls_ssl_options = NO_COMPRESSION
tls_high_cipherlist = ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA:ECDHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:DHE-RSA-AES256-SHA:ECDHE-ECDSA-DES-CBC3-SHA:ECDHE-RSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:DES-CBC3-SHA:!DSS
tls_preempt_cipherlist = yes
smtpd_tls_protocols = !SSLv2,!SSLv3
smtp_tls_protocols = !SSLv2,!SSLv3
smtpd_tls_mandatory_ciphers = high
smtpd_tls_mandatory_protocols = !SSLv2,!SSLv3
smtpd_tls_exclude_ciphers = aNULL, LOW, EXP, MEDIUM, ADH, AECDH, MD5, DSS, ECDSA, CAMELLIA128, 3DES, CAMELLIA256, RSA+AES, eNULL
smtpd_tls_dh1024_param_file = /etc/postfix/dhparams.pem
smtpd_tls_CApath = /etc/ssl/certs
smtp_tls_CApath = /etc/ssl/certs

# Settings to prevent SPAM early
smtpd_helo_required = yes
smtpd_delay_reject = yes
smtpd_helo_restrictions = permit_mynetworks, reject_invalid_helo_hostname, permit
#smtpd_relay_restrictions = permit_mynetworks permit_sasl_authenticated defer_unauth_destination
#smtpd_relay_restrictions = reject_sender_login_mismatch permit_sasl_authenticated permit_mynetworks defer_unauth_destination
smtpd_relay_restrictions = reject_sender_login_mismatch permit_sasl_authenticated permit_mynetworks defer_unauth_destination
smtpd_recipient_restrictions = permit_sasl_authenticated, reject_unauth_destination, reject_unauth_pipelining, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname, reject_unknown_recipient_domain, reject_rbl_client bl.spamcop.net, permit_mynetworks
smtpd_client_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, reject_unauth_pipelining
#smtpd_sender_restrictions = reject_sender_login_mismatch, permit_sasl_authenticated, permit_mynetworks, reject_unknown_sender_domain 
smtpd_sender_restrictions = reject_sender_login_mismatch, reject_authenticated_sender_login_mismatch,  reject_unknown_sender_domain, permit_sasl_authenticated, permit_mynetworks
disable_vrfy_command = yes

# Postscreen settings to drop zombies/open relays/spam early
#postscreen_dnsbl_action = enforce
postscreen_dnsbl_action = ignore
postscreen_dnsbl_sites = zen.spamhaus.org*2
        bl.mailspike.net
        b.barracudacentral.org*2
        bl.spameatingmonkey.net
        bl.spamcop.net
        dnsbl.sorbs.net
        psbl.surriel.com
        list.dnswl.org=127.0.[0..255].0*-2
        list.dnswl.org=127.0.[0..255].1*-3
        list.dnswl.org=127.0.[0..255].[2..3]*-4
postscreen_dnsbl_threshold = 3
postscreen_dnsbl_whitelist_threshold = -1
postscreen_greet_action = enforce
postscreen_bare_newline_action = enforce

# SASL
smtpd_sasl_auth_enable = no
#smtpd_sasl_auth_enable = yes
##smtpd_sasl_path = /var/spool/postfix/private/auth
#smtpd_sasl_path = /var/spool/postfix/private/smtpd
##smtpd_sasl_type = dovecot
#smtpd_sasl_type = dovecot
##smtpd_sasl_security_options = noanonymous
#smtpd_sasl_security_options = noanonymous
##smtpd_sasl_local_domain = $mydomain
##broken_sasl_auth_clients = yes
#broken_sasl_auth_clients = yes

# SMTP configuration
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl/passwd
smtp_sasl_security_options = noanonymous
smtp_sasl_tls_security_options = noanonymous
smtp_tls_security_level = encrypt
header_size_limit = 4096000
relayhost = [smtp.sendgrid.net]:587

# Mail directory
virtual_transport = lmtp:unix:/var/run/dovecot/lmtp
virtual_mailbox_domains = /etc/postfix/vhost
virtual_mailbox_maps = texthash:/etc/postfix/vmailbox
virtual_alias_maps = texthash:/etc/postfix/virtual

# Additional option for filtering
content_filter = smtp-amavis:[127.0.0.1]:10024

# Milters used by DKIM
milter_protocol = 6
milter_default_action = accept
dkim_milter = inet:localhost:8891
dmarc_milter = inet:localhost:8893
smtpd_milters = $dkim_milter,$dmarc_milter
non_smtpd_milters = $dkim_milter

# SPF policy settings
policyd-spf_time_limit = 3600

# Header checks for content inspection on receiving
header_checks = pcre:/etc/postfix/maps/header_checks.pcre

# Remove unwanted headers that reveail our privacy
smtp_header_checks = pcre:/etc/postfix/maps/sender_header_filter.pcre
myhostname = mail.viktorbarzin.me
mydomain = viktorbarzin.me
smtputf8_enable = no
message_size_limit = 20480000
sender_canonical_maps = tcp:localhost:10001
sender_canonical_classes = envelope_sender
recipient_canonical_maps = tcp:localhost:10002
recipient_canonical_classes = envelope_recipient,header_recipient
compatibility_level = 2
# enable_original_recipient = no  # b4 uncommenting see https://serverfault.com/questions/661615/how-to-drop-orig-to-using-postfix-virtual-domains
always_add_missing_headers = yes

anvil_status_update_time = 5s
EOT
}

