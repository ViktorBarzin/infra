variable "mailserver_accounts" {}
variable postfix_account_aliases {}

resource "kubernetes_namespace" "mailserver" {
  metadata {
    name = "mailserver"
  }
}

resource "kubernetes_config_map" "mailserver_env_config" {
  metadata {
    name      = "mailserver.env.config"
    namespace = "mailserver"
    labels = {
      app = "mailserver"
    }
  }

  data = {
    DMS_DEBUG           = "0"
    ENABLE_CLAMAV       = "0"
    ENABLE_FAIL2BAN     = "1"
    ENABLE_FETCHMAIL    = "0"
    ENABLE_POSTGREY     = "0"
    ENABLE_SPAMASSASSIN = "0"
    ENABLE_SRS          = "1"
    FETCHMAIL_POLL      = "120"
    ONE_DIR             = "1"
    OVERRIDE_HOSTNAME   = "mail.viktorbarzin.me"
    TLS_LEVEL           = "intermediate"
  }
}

locals {
  postfix_accounts_cf = join("\n", [for user, pass in var.mailserver_accounts : "${user}|${bcrypt(pass, 6)}"])
  #   postfix_accounts_cf = join("\n", [for user, pass in var.mailserver_accounts : format("%s%s%s", user, "|{SHA512-CRYPT}$6$$", sha512(pass))])  # Does not work :/
}

resource "kubernetes_config_map" "mailserver_config" {
  metadata {
    name      = "mailserver.config"
    namespace = "mailserver"

    labels = {
      app = "mailserver"
    }
  }

  data = {
    # Actual mail settings
    "postfix-accounts.cf" = local.postfix_accounts_cf
    "postfix-main.cf"     = var.postfix_cf
    "postfix-virtual.cf"  = var.postfix_account_aliases

    KeyTable     = "mail._domainkey.viktorbarzin.me viktorbarzin.me:mail:/etc/opendkim/keys/viktorbarzin.me-mail.key\n"
    SigningTable = "*@viktorbarzin.me mail._domainkey.viktorbarzin.me\n"
    TrustedHosts = "127.0.0.1\nlocalhost\n"
  }
  # Password hashes are different each time and avoid changing secret constantly. 
  # Either 1.Create consistent hashes or 2.Find a way to ignore_changes on per password
  lifecycle {
    ignore_changes = [data["postfix-accounts.cf"]]
  }

}
