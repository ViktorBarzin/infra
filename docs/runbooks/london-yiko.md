# London robot vacuum "Yiko": camera and Ecovacs access

Yiko is the Ecovacs DEEBOT X8 PRO OMNI in the London flat (class `n0vyif`, on
the London LAN at 192.168.8.175). Home Assistant London controls it through the
core `ecovacs` integration. Its camera is shown on demand through a bridge in
the cluster (`stacks/ecovacs-video-proxy`).

## How the camera works

```mermaid
sequenceDiagram
    participant U as Person on the Yiko dashboard
    participant HA as HA London
    participant K as k8s API 10.0.20.100:6443
    participant B as ecovacs-video-proxy pod
    participant E as Ecovacs cloud + AWS Kinesis
    participant R as Yiko
    U->>HA: turn on input_boolean.yiko_camera
    HA->>K: PATCH deployments/scale replicas=1 (camera-switch token)
    K->>B: start pod
    B->>E: login (stored token), start live view, WebRTC signaling
    E-->>R: open camera
    R-->>B: H.264 over WebRTC (direct UDP, or Kinesis TURN)
    B-->>HA: RTSP 10.0.20.200:8554/live
    HA->>B: poll /snapshot.jpg every 5 s (only while the toggle is on) until 200 = video is live
    HA-->>U: conditional live card appears
    Note over HA,K: off, 5 min auto-off, or HA start -> replicas=0
    Note over K: camera-cap CronJob (every 15 min) forces 0 once a pod has run 15 min
```

- The bridge is the unmodified third-party image
  `ghcr.io/c4talyst/ecovacs-deebot-video-proxy`, pinned by digest to release
  1.1.1 (commit `1b08ccb`). Before adoption, every file in the image was compared
  with the audited source, and the bundled MediaMTX binary with the official
  v1.21.2 release. Both matched.
- `ACTIVE_ONLY_VIDEO=false`: the bridge streams for as long as the pod runs. The
  Deployment sits at 0 replicas, so the robot's camera and headlights are off
  unless someone has turned the camera on.
- HA London holds a ServiceAccount token (`camera-switch`) whose Role allows only
  `get`/`patch` on this one Deployment and its scale subresource.

## Pieces and where they live

| Piece | Where |
|---|---|
| Bridge Deployment, LB Service (10.0.20.200:8554 RTSP, :8080 HTTP), RBAC, camera-cap CronJob | `stacks/ecovacs-video-proxy/main.tf` |
| Bridge secrets (env vars, one key per variable) | Vault `secret/ecovacs-video-proxy` |
| Alerts `YikoCameraLeftOn`, `YikoCameraStartFailed` | `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl`, group "Yiko camera" |
| HA side, YAML (needs an HA restart to change) | `/config/configuration.yaml`: `rest_command.yiko_camera_scale` (PATCH replicas), `command_line` `binary_sensor.yiko_camera_ready` (curl /snapshot.jpg, on when 200; its own `scan_interval` is 3600 s, and the automation below refreshes it every 5 s while the camera is on). Secrets in `/config/secrets.yaml`: `k8s_yiko_camera_bearer`, `yiko_rtsp_password`, `yiko_camera_ready_cmd` |
| HA side, UI-managed | `input_boolean.yiko_camera`; automation `automation.yiko_camera` (id `yiko_camera`: on → replicas 1; off, 5 min on, or HA start → replicas 0); automation `automation.yiko_camera_ready_poll` (id `yiko_camera_ready_poll`: `homeassistant.update_entity` on the ready sensor every 5 s while `input_boolean.yiko_camera` is on, and once 30 s after it turns off; added 2026-11-04 so the Pi 3 no longer runs a failing curl and logs an error every 5 s while the bridge is at 0 replicas); generic camera `camera.yiko` "Yiko camera" (stream `rtsp://10.0.20.200:8554/live` over TCP, still image `/snapshot.jpg`, user `yiko`); Camera card + conditional live `picture-entity` in the first section of the `vacuum-yiko` dashboard |

## Common tasks

### Turn the camera off by hand

```sh
kubectl -n ecovacs-video-proxy scale deploy ecovacs-video-proxy --replicas=0
```

This is a transient step; the Terraform state ignores the replica count, so
nothing reverts it.

### Send Yiko to one room, for example to take a photo there

Run `homelab ha yiko photo <room>` (v0.40). It starts the HA London script
`script.yiko_photo` (fields `room`, `shots`), waits for it, and downloads the
photos this run wrote from `/media/yiko/<room>-<n>.jpg` through HA's
authenticated `/media/local/` URL. `homelab ha yiko clean <room>` and `dock`
send the raw commands below. `photo` and `clean` refuse 22:00-08:00 London
time without `--night`. The script is in `/config/scripts.yaml`
(ha-london-config `38734dd`). It does these steps:

1. Sets `select.yiko_work_mode` to `vacuum`, so the floor stays dry.
2. Starts a clean of the room with a raw `clean_V2` command (table below).
3. Turns on `input_boolean.yiko_camera`.
4. Waits up to 60 s for `sensor.yiko_area_cleaned` to change. A new job resets
   it to 0, so no change means the robot rejected the start.
5. Waits up to 4 min for that sensor to reach 1 m². The robot cleans only the
   target room, so this means it is inside the room.
6. Waits for `binary_sensor.yiko_camera_ready`, then for each photo: pause,
   `camera.snapshot`, resume, 8 s.
7. Stops the job, sends Yiko to the dock, restores the work mode and turns the
   camera off. It returns `{room, job_started, arrived, camera_ready, files}`.

Measured 2026-11-13: about 70 s from the start to inside the corridor, and
2 min 20 s for a whole run with 6 photos.

Raw commands (`vacuum.send_command`, command `clean_V2`). HA's own `spot_area`
does not work on firmware 1.134.0: the robot answers `20011 unknown type` to
the `spotArea` clean type.

| Action | `params` |
|---|---|
| Clean one room | `{"act":"start","content":{"type":"freeClean","value":"1,<room id>"}}` |
| Pause | `{"act":"pause","content":{"type":""}}` |
| Resume | `{"act":"resume"}` |
| Stop | `{"act":"stop","content":{"type":""}}`, then `vacuum.return_to_base` |

- Room ids are in the `rooms` attribute of `vacuum.yiko` (corridor 1, balcony 3,
  kitchen 4, bedroom1 6, kids_room 7). The dock is in the living room.
- In an HA template, render `params` as one dict
  (`{{ {'act': 'start', 'content': {...}} }}`). A template that renders the
  bare text `1,1` becomes a list, and the robot answers `20011 format error`.
- During a `freeClean` job HA can show `docked` or `idle`. The raw command
  `getWorkState` gives the real state (`robotState.state`, `paused`). HA shows
  raw replies only with `logger.set_level` `deebot_client: debug`, in
  `docker logs homeassistant`.
- `getPos` always answers `invalid: 1`, and the `mapPoint` go-to command answers
  `ok` but the robot does not move.
- Photos taken while the robot moves are blurred and show its laser lines.
  Photos taken while it is paused are sharp.
- A start sent while the robot docks and empties its bin did nothing. Wait about
  30 s after it docks.
- The camera failed with `20303` while the robot was idle on the dock. The
  stream started once the robot was out cleaning.

### HA London: Ecovacs integration says "Device verification required"

Ecovacs sometimes asks a known client to verify again by email (it happened to
HA on 2026-10-31). HA opens a reauth flow; complete it:

1. WebSocket `config_entries/flow/progress` lists the `ecovacs` reauth flow.
2. `POST /api/config/config_entries/flow/<flow_id>` with `{"password": ...}`
   (Vaultwarden item `ecovacs.com`). Ecovacs emails a 6-digit code to the
   account address.
3. `POST` the same URL with `{"verification_code": "<code>"}`. The answer is
   `reauth_successful`.

### Bridge logs "Device verification required"

The bridge has its own Ecovacs client ID (`ECOVACS_DEVICE_ID` in Vault). If
Ecovacs re-challenges it, verify it again with the bridge's own auth code
(`src/ecovacs_auth.py` from the pinned image): `authenticate()` raises the
error, `request_email_verification_code()` sends the email,
`verify_device_code(code)` then `authenticate()` completes it. Write the new
`ECOVACS_ACCESS_TOKEN` and `ECOVACS_USER_ID` back to Vault; ESO refreshes the
Secret within the hour (or force it with an annotation on the ExternalSecret).

### Updating the bridge image

The digest pin is deliberate. To move to a newer release:

1. Review the upstream diff since `1b08ccb` (look for new network destinations,
   credential handling, and changes to `web_ui.py` auth).
2. Pull the new image by digest and compare `/app` with the reviewed commit and
   `/usr/local/bin/mediamtx` with the official MediaMTX release.
3. Change `local.image` in `stacks/ecovacs-video-proxy/main.tf`.

### Revoking HA's access

Delete the `camera-switch-token` Secret in the `ecovacs-video-proxy` namespace
and re-apply the stack to mint a new one, then update `k8s_yiko_camera_token`
in HA London's `secrets.yaml`.

## Measured behaviour (2026-11-01)

| Step | Time |
|---|---|
| Image pull, first start on a node (400 MB) | 61 s |
| Container start to Ecovacs login | 2-9 s |
| Login to first frame, robot free | 3 s |
| Tap on the card to "Live", image cached and robot free | 19 s |

- **Robot cooldown.** For roughly 3-5 minutes after a video session ends, the
  robot refuses a new one: Ecovacs answers `start_watch` with
  `20303 send cmd to mqserver error`. The bridge retries with a growing delay
  (up to 30 s), so the card stays on "Starting…" until the robot accepts. Ending
  the session cleanly first (`POST /api/robot/sleep`) made no difference. The
  robot answers ordinary commands normally during this time.
- **Image cache.** Nodes delete images unused for 7 days, so the first start
  after a quiet week, or on a different node, pulls the image again (about a
  minute).
- The direct WebRTC path works across the tunnel. The bridge logs a harmless
  `STUN transaction failed (403 - Forbidden IP)` from the Kinesis TURN
  fallback, which it does not need.
- HA plays the stream over WebRTC (`ha-web-rtc-player`, 1280x720) in a browser
  outside the London LAN.

## Known limits

- Start-up takes the pod start, an Ecovacs login and the WebRTC handshake. The
  live card appears only once `/snapshot.jpg` answers 200.
- HA's `rest_command` calls the k8s API with `verify_ssl: false`, over the
  site-to-site WireGuard tunnel, because the API server certificate is signed by
  the cluster CA, which HA London does not trust.
- Known weak points of the unmodified bridge, accepted because it is reachable
  only from the LAN and tunnel, with credentials, for minutes at a time: it runs
  as root, its web UI session key derives from the RTSP credentials, it accepts
  credentials in query strings, and it logs the one-time verification code.
- A camera re-opened within a few minutes of closing waits out the robot
  cooldown described above.
