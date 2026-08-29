#!/bin/bash
IFACE="${1:-ens18}"
if networkctl status --no-pager "$IFACE" 2>/dev/null | grep -qE '^\s*State:.*\(failed\)'; then
  /usr/bin/logger -t networkd-dhcp-watchdog "interface $IFACE in failed state; running networkctl reconfigure"
  /usr/bin/networkctl reconfigure "$IFACE"
fi
