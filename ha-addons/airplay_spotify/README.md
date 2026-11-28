# AirPlay receiver (ha-london add-on)

Makes ha-london, the Pi 3 in the London living room, an AirPlay speaker named
**pi-london** (option `name`). Any app on an iPhone or Mac plays to it:
YouTube Music, Spotify, Apple Music. It uses shairport-sync, AirPlay 1. The
sound goes into the Pi's sound system like the radio's, so it plays on the
Logitech Z537 and the Livia strip follows it when Follow music is on.

The folder and slug keep the name `airplay_spotify`, because a new slug would
be a new add-on. Spotify Connect (go-librespot) ran here in 1.0.0 to 1.0.2 and
was removed on 2026-11-28: Spotify refused the audio key for every track
("code 1"), then rate-limited the account (HTTP 429) after go-librespot
skipped through 51 tracks twice. Spotify no longer enables third-party Connect
speakers for accounts that have not used one in the last year (go-librespot
issue 279, 2026-11-19).

## How it ties into Home Assistant

`playing.sh`, run by shairport-sync's session hooks, sets
`input_boolean.airplay_playing` through the Supervisor API
(`homeassistant_api: true`). It is on while an AirPlay session is open, and off
when the sender ends it or after shairport-sync's default `session_timeout`
(120 s) when the sender vanishes. 1.0.1 set 20 s; Viktor then had to pick the
Pi again after a pause, and 1.0.2 went back to the default.

`packages/radio.yaml` in the ha-london-config repo combines it with VLC in
`binary_sensor.pi_music_playing`. Follow music and the speaker hand-off watch
that sensor, and `radio_stops_for_phone` stops the radio when a phone starts.

## Pieces

- `Dockerfile`: Alpine with shairport-sync (built with PulseAudio and avahi),
  avahi and dbus. The Pi builds it itself in about a minute, because it only
  installs packages. The LED strip add-on compiles code, so GitHub Actions
  builds that one.
- `run.sh`: avahi announces the receiver on the Wi-Fi as host
  `living-room-music.local`, so the Pi's own name stays with Home Assistant.
  When shairport-sync or avahi exits, the add-on exits and the Supervisor
  watchdog starts it again. shairport-sync logs at verbosity 1.
- The AirPlay ID is the MD5 of the name and the Ethernet MAC
  (`b8:27:eb:8b:e7:63`, padded to 8 bytes), so it stays the same across
  restarts and changes only with the name. A sender that had the old name
  selected must pick the Pi again after a rename. A restart ends a playing
  session, and the sender does not reconnect by itself.

About 14 MB of RAM when idle (2026-11-28).

## Deploy

`./deploy.sh` copies the folder to `/addons/airplay_spotify`, has the
Supervisor install, update or rebuild it, and starts it. Bump `version` in
`config.yaml` for a change to reach the Pi as an update.

## Check it

From the SSH add-on: `sudo docker logs app_local_airplay_spotify`. AirPlay
cannot be tested from the devvm: the Sofia-London tunnel drops its audio
packets as too long. An RTSP `OPTIONS` to 192.168.8.103:5000 from the devvm
does answer. On 2026-11-28 a pyatv sender on the Pi itself streamed a silent
file; `input_boolean.airplay_playing` went on about 4 s after the start and
off when the stream ended, and the stream showed in `pactl list short
sink-inputs`.
