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
    HA->>B: poll /snapshot.jpg until 200 = video is live
    HA-->>U: conditional live card appears
    Note over HA,K: off, 5 min auto-off, or HA start -> replicas=0
    Note over K: camera-cap CronJob forces 0 after 15 min
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
| HA side: `input_boolean.yiko_camera`, `rest_command.yiko_camera_on/off`, `binary_sensor.yiko_camera_ready` (command_line), automations "Yiko camera on/off", generic camera "Yiko camera", card on the `vacuum-yiko` dashboard | HA London `/config/configuration.yaml`, `/config/secrets.yaml` (`k8s_yiko_camera_token`, `yiko_rtsp_password`), UI-managed entities |

## Common tasks

### Turn the camera off by hand

```sh
kubectl -n ecovacs-video-proxy scale deploy ecovacs-video-proxy --replicas=0
```

This is a transient step; the Terraform state ignores the replica count, so
nothing reverts it.

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
- Viewing from outside the London LAN goes through HA's own stream handling,
  which may fall back to HLS.
