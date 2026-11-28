# AirPlay and Spotify (ha-london add-on)

Makes ha-london, the Pi 3 in the London living room, a speaker that phones play
to. It shows as **pi-london** in two places:

- the AirPlay menu of an iPhone or Mac, for YouTube Music, Apple Music,
  Spotify or any other app (shairport-sync, AirPlay 1);
- Spotify's device list (go-librespot, Spotify Connect; needs Premium).

The sound goes into the Pi's sound system like the radio's, so it plays on the
Logitech Z537 and the Livia strip follows it when Follow music is on.

## How it ties into Home Assistant

The add-on sets two toggles in Home Assistant through the Supervisor API
(`homeassistant_api: true`):

| Toggle | Set by | On while |
|---|---|---|
| `input_boolean.airplay_playing` | shairport-sync session hooks (`playing.sh`) | an AirPlay session plays; off when the sender stops, or 20 s after its packets stop (`session_timeout`) |
| `input_boolean.spotify_playing` | `spotify_watch.sh`, which reads go-librespot's `/status` every 2 s | a track plays; paused counts as off |

`packages/radio.yaml` in the ha-london-config repo combines them with VLC in
`binary_sensor.pi_music_playing`. Follow music and the speaker hand-off watch
that sensor, and `radio_stops_for_phone` stops the radio when a phone starts.

## Pieces

- `Dockerfile`: go-librespot's own image (Alpine with avahi and libpulse) plus
  Alpine's shairport-sync. The Pi builds it itself in about a minute, because it
  only installs packages. The LED strip add-on compiles code, so GitHub Actions
  builds that one.
- `run.sh`: one avahi-daemon announces both receivers on the Wi-Fi as host
  `living-room-music.local`, so the Pi's own name stays with Home Assistant.
  When any receiver exits, the add-on exits and the Supervisor watchdog starts
  it again.
- go-librespot keeps the Spotify login from the first connect in
  `/data/spotify/state.json`.

About 14 MB of RAM when idle (2026-11-28).

## Deploy

`./deploy.sh` copies the folder to `/addons/airplay_spotify`, has the
Supervisor install, update or rebuild it, and starts it. Bump `version` in
`config.yaml` for a change to reach the Pi as an update.

## Check it

From the SSH add-on: `sudo docker logs app_local_airplay_spotify`. AirPlay
cannot be tested from the devvm: the Sofia-London tunnel drops its audio
packets as too long. On 2026-11-28 a pyatv sender on the Pi itself streamed a
silent file; `input_boolean.airplay_playing` went on about 4 s after the start
and off when the stream ended, and the stream showed in `pactl list short
sink-inputs`.
