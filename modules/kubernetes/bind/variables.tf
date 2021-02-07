variable "named_conf" {
  default = <<EOT
// This is the primary configuration file for the BIND DNS server named.
//
// Please read /usr/share/doc/bind9/README.Debian.gz for information on the
// structure of BIND configuration files in Debian, *BEFORE* you customize
// this configuration file.
//
// If you are just adding zones, please do that in /etc/bind/named.conf.local

include "/etc/bind/named.conf.options";
include "/etc/bind/named.conf.local";
//include "/etc/bind/named.conf.default-zones";
EOT
}

variable "named_conf_local" {
  default = <<EOT
//
// Do any local configuration here
//

// Consider adding the 1918 zones here, if they are not used in your
// organization
//include "/etc/bind/zones.rfc1918";

zone "viktorbarzin.me" {
  type master;
  file "/etc/bind/db.viktorbarzin.me";
};

zone "viktorbarzin.lan" {
  type master;
  file "/etc/bind/db.viktorbarzin.lan";
};
EOT
}

variable "public_named_conf_local" {
  default = <<EOT
//
// Do any local configuration here
//

// Consider adding the 1918 zones here, if they are not used in your
// organization
//include "/etc/bind/zones.rfc1918";

zone "viktorbarzin.me" {
  type master;
  file "/etc/bind/db.viktorbarzin.me";
};
EOT
}

variable "public_named_conf_options" {
  default = <<EOT
options {
  querylog yes;
  directory "/tmp/";
  listen-on {
    any;
  };
  dnssec-validation auto;

  allow-recursion {
    none;
  };
};
EOT
}
