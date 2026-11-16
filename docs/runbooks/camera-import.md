# Camera import (Nikon Z5 II to Immich over Wi-Fi)

Viktor's Z5 II sends its JPEGs over Wi-Fi to an SFTP inbox in the cluster, and
an Immich CLI loop moves each photo into Immich on his account. Nothing needs a
USB cable. Stack: `stacks/camera-import/`.

## How it works

```
Z5 II ──Wi-Fi──> London Flint ──WireGuard──> 10.0.20.213:22 (SFTPGo)
                                                │ atomic rename into
                                                ▼ /srv/nfs/camera-import/incoming
                                     uploader: immich upload --delete (every 30 s)
                                                ▼
                                     Immich (Viktor's timeline)
```

- **SFTPGo** (`sftpgo` container) has one user, `camera`. Uploads go to
  `/srv/data/.tmp` and are renamed into `incoming/` only when complete, so an
  interrupted transfer leaves nothing behind.
- **Uploader** (`uploader` container, `uploader.sh`) runs the official Immich
  CLI on `incoming/`. The CLI deletes a file after Immich has it, as a new
  asset or a duplicate. A file Immich rejects stays and is retried every round.
- The camera keeps every photo on its SD card. "Delete after upload" stays off.
- Only the camera's Wi-Fi network matters: any site whose router routes
  `10.0.0.0/8` to Sofia (London, Valchedrym, Mladost 3, the Sofia LAN) works.

| what | where |
|---|---|
| SFTP address | `10.0.20.213`, port 22, protocol SFTP |
| user | `camera` |
| password | Vault `secret/camera-import`, key `sftp_password` |
| Immich key | Vault `secret/camera-import`, key `immich_api_key` (Immich key "camera-import", permissions `asset.upload`, `user.read`, `apiKey.read`) |
| SSH host keys | Vault `secret/camera-import`, keys `host_key_rsa`, `host_key_ecdsa`, `host_key_ed25519` |
| inbox on disk | Proxmox host `/srv/nfs/camera-import/{incoming,.tmp}`, owned by uid 1000 |

## Set up the camera (once)

The camera holds one wireless link at a time, so SnapBridge stays unpaired.

1. Network menu > **Connect to FTP server** > **Network settings** >
   **Create profile** > **Connection wizard** > **Configure manually**. Name it
   `Home`.
2. **Search for Wi-Fi network**, pick the home SSID (London: `5G-Tower Admin`),
   enter its password. IP address: **Obtain automatically**.
3. Server type **SFTP**. Address `10.0.20.213`. Port `22`.
4. **Enter user ID**: `camera` and the password from Vault. Destination:
   **Home folder**.
5. **Connect to FTP server** > **Options**: **Auto upload** ON,
   **Upload RAW + JPEG as** JPEG, **Delete after upload** OFF,
   **Keep connection** ON.

Photos already on the card: Playback > `i` > **Filtered playback**, then `i` >
**Select all for upload (FTP)**. A photo shows a blue upload icon once the
server has it.

## Check it

```sh
kubectl -n camera-import logs deploy/camera-import -c uploader --tail=20   # "Successfully uploaded N new assets"
kubectl -n camera-import logs deploy/camera-import -c sftpgo --tail=20     # logins and uploads
ssh root@192.168.1.127 ls -la /srv/nfs/camera-import/incoming             # should be empty between rounds
```

Upload a test file from the devvm:

```sh
curl -k --netrc-file <(printf 'machine 10.0.20.213 login camera password %s\n' \
  "$(vault kv get -field=sftp_password secret/camera-import)") \
  -T photo.jpg sftp://10.0.20.213/photo.jpg
```

## Alerts

- **CameraImportStuck**: a photo has waited in `incoming/` for over an hour.
  The uploader log names each failed file and Immich's reason. Common causes:
  Immich down, or the API key revoked (the CLI prints `Failed to connect to
  server ... 401`). A new key needs the three permissions above.
- **CameraImportUploaderStale**: the uploader has not pushed its metrics for
  30 minutes. The pod is down or the Pushgateway is unreachable.
- Uptime Kuma `[Internal] camera-import` probes SFTPGo's `/healthz`.

## Change the password

Write a new `sftp_password` to Vault `secret/camera-import` (keep the other
keys: `vault kv patch`). ESO refreshes within an hour and Reloader restarts the
pod; force it sooner with
`kubectl -n camera-import annotate externalsecret camera-import-secrets force-sync=$(date +%s) --overwrite`.
Then enter the new password in the camera profile.

## Gotchas

- Nikon's manual says FTP servers "running third-party software are not
  supported". SFTPGo is third-party; this is the support disclaimer, not a
  protocol limit.
- Videos never upload automatically; send them from playback by hand.
- The inbox is under `/srv/nfs`, so `offsite-sync-backup` may copy a photo
  that waits there over midnight to the Synology. It leaves on the next
  monthly full sync.
