#!/bin/sh
# Bastion entrypoint. Replaces the image's s6 init.
#
# /etc/bastion/keys is the ExternalSecret from Vault secret/bastion:
#   ssh_host_ed25519_key      the host key (stable across restarts)
#   authorized_key_<client>   one public key line per client account
# Every authorized_key_<client> becomes a nologin account named <client>.
set -eu

KEYS=/etc/bastion/keys
RUN=/run/bastion

install -d -m 755 "$RUN" "$RUN/authorized_keys"
install -m 600 "$KEYS/ssh_host_ed25519_key" "$RUN/ssh_host_ed25519_key"

for f in "$KEYS"/authorized_key_*; do
  [ -e "$f" ] || continue
  client=${f##*/authorized_key_}
  case "$client" in
    "" | *[!a-z0-9_-]*)
      echo "bastion: skipping invalid client name '$client'" >&2
      continue
      ;;
  esac
  id "$client" >/dev/null 2>&1 || adduser -D -H -h /nonexistent -s /sbin/nologin "$client"
  # adduser leaves the password field as '!', which sshd treats as a locked
  # account and refuses even for key auth. '*' means "no password" instead.
  usermod -p '*' "$client"
  install -m 644 "$f" "$RUN/authorized_keys/$client"
  echo "bastion: client account '$client' ready" >&2
done

exec /usr/sbin/sshd.pam -D -e -f /etc/bastion/conf/sshd_config
