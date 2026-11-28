#!/bin/sh
# Starts avahi for mDNS and the AirPlay receiver. If either exits, the add-on
# exits and the Supervisor watchdog starts it again.
set -eu

name=$(jq -r .name /data/options.json)

# avahi announces the receiver on the home network only. The Pi's own name
# stays with Home Assistant (homeassistant.local).
cat > /etc/avahi/avahi-daemon.conf <<CONF
[server]
host-name=living-room-music
deny-interfaces=docker0,hassio
use-ipv6=no
[publish]
publish-workstation=no
publish-hinfo=no
publish-addresses=yes
[rlimits]
CONF

cat > /etc/shairport-sync.conf <<CONF
general = {
  name = "$name";
  output_backend = "pa";
  mdns_backend = "avahi";
};
sessioncontrol = {
  run_this_before_play_begins = "/app/playing.sh airplay on";
  run_this_after_play_ends = "/app/playing.sh airplay off";
  wait_for_completion = "no";
  allow_session_interruption = "yes";
};
diagnostics = {
  log_verbosity = 1;
};
pa = {
  application_name = "AirPlay";
};
CONF

# Spotify Connect (go-librespot) ran here in 1.0.0-1.0.2. Removed 2026-11-28:
# Spotify refuses the audio key to third-party Connect speakers for accounts
# that have not used one in the last year (go-librespot issue 279), and the
# retries got the account rate-limited. Spotify plays through AirPlay instead.
rm -rf /data/spotify

mkdir -p /run/dbus
rm -f /run/dbus/dbus.pid /run/avahi-daemon/pid
dbus-uuidgen --ensure
dbus-daemon --system
avahi-daemon --daemonize --no-chroot

/app/playing.sh airplay off

shairport-sync &
airplay=$!
for _ in 1 2 3 4 5; do [ -s /run/avahi-daemon/pid ] && break; sleep 1; done
avahi=$(cat /run/avahi-daemon/pid)

# Exit as soon as either stops.
while kill -0 "$airplay" "$avahi" 2>/dev/null; do sleep 5; done
echo "the AirPlay receiver or avahi stopped, exiting" >&2
exit 1
