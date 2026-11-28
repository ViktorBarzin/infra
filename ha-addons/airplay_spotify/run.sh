#!/bin/sh
# Starts one avahi for mDNS, the AirPlay receiver and the Spotify Connect
# speaker. If any of them exits, the add-on exits and the Supervisor watchdog
# starts it again.
set -eu

name=$(jq -r .name /data/options.json)

# avahi announces both receivers on the home network only. The Pi's own name
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
  session_timeout = 20;
};
pa = {
  application_name = "AirPlay";
};
CONF

mkdir -p /data/spotify
cat > /data/spotify/config.yml <<CONF
device_name: "$name"
device_type: speaker
audio_backend: pulseaudio
zeroconf_enabled: true
zeroconf_backend: avahi
credentials:
  type: zeroconf
  zeroconf:
    persist_credentials: true
server:
  enabled: true
  address: 127.0.0.1
  port: 3678
CONF

mkdir -p /run/dbus
rm -f /run/dbus/dbus.pid /run/avahi-daemon/pid
dbus-uuidgen --ensure
dbus-daemon --system
avahi-daemon --daemonize --no-chroot

/app/playing.sh airplay off
/app/playing.sh spotify off

shairport-sync &
airplay=$!
go-librespot --config_dir /data/spotify &
spotify=$!
/app/spotify_watch.sh &
watch=$!

# Exit as soon as any of them stops.
while kill -0 "$airplay" "$spotify" "$watch" 2>/dev/null; do sleep 5; done
echo "a receiver stopped, exiting" >&2
exit 1
