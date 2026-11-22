# Bambuddy

Bambuddy is the 3D-print workshop for the Bambu Lab P2S in Emo's Sofia flat. It keeps every print project in one place: the model files, the design source, notes, photos, sliced plates and print history. People preview a model, slice it and print it from the web app at `https://bambuddy.viktorbarzin.me`. Agents publish the parts they design into it with `homelab print`. Stack: `stacks/bambuddy`. Upstream: [maziggy/bambuddy](https://github.com/maziggy/bambuddy), AGPL-3.0.

## Shape

```mermaid
flowchart LR
  A[Agent on the devvm] -->|"homelab print publish (X-API-Key)"| I[bambuddy.viktorbarzin.me]
  H[Viktor, Emo in a browser] -->|Authentik OIDC| I
  I --> S[Service bambuddy:80]
  S --> P[Pod: bambuddy :8000]
  P -->|localhost:3001| B[Sidecar: bambu-studio-api]
  P --> PG[(Shared CNPG Postgres, database bambuddy)]
  P --> N[(NFS /srv/nfs/bambuddy)]
  P -->|"MQTT 8883, FTPS 990, camera 322"| R[P2S at 192.168.1.110, Sofia LAN]
```

| Piece | Value |
|---|---|
| Images | `ghcr.io/maziggy/bambuddy:1.3.2` and `ghcr.io/maziggy/bambu-studio-api:bambuddy-1.3.2`. Upstream releases both together, so keep the two tags equal |
| Workload | Deployment `bambuddy`, 1 replica, `Recreate`, because Bambuddy holds one MQTT session per printer and runs its queue scheduler in the process |
| Slicer | The `bambu-studio-api` container runs the Bambu Studio CLI behind an HTTP API on port 3001. The Slice button in the library sends the model and the profiles to it and gets a `.gcode.3mf` back |
| Database | `bambuddy` on the shared CNPG cluster (`stacks/dbaas` `app_databases`). Password from the Vault static role `pg-bambuddy`, rotated Tuesdays at 10:25 UTC. Pool of 3 plus 4 overflow connections |
| Files | NFS `/srv/nfs/bambuddy` at `/app/data`: library files, the print archive, plate-detection references. The nightly NFS mirror and offsite sync carry it |
| Secrets | Vault `secret/bambuddy`: `jwt_secret_key`, `mfa_encryption_key`, `oidc_client_secret`, and `admin_password` for the local `admin` account. Vault `secret/bambuddy-agent`: `api_key` of the local `agent` account |
| Ingress | `auth = "app"`, proxied. Bambuddy's own login gates the UI and the API |

## Sign-in and access

People sign in with Authentik. The Authentik application `bambuddy` (`stacks/bambuddy/authentik.tf`) admits the Home Server Admins group, which is Viktor and Emo. Bambuddy creates the account on the first login and maps the group to its own Administrators group (`BAMBUDDY_OIDC_GROUP_MAPPING`).

Two local accounts exist:

| Account | Use |
|---|---|
| `admin` | Break-glass login and settings. Password in Vault `secret/bambuddy` `admin_password` |
| `agent` | Owns the API key that `homelab print` uses. The key has the library and projects scopes only. It cannot queue, start or stop a print |

## Agents

`homelab print publish --project "<name>" <file|dir>...` finds or creates the project and a top-level library folder of the same name linked to it, then uploads the files. A file with the same name as one already in the folder replaces it, which is how a new revision goes in. `--description`, `--url` and `--cover <image>` fill in a new project. `homelab print projects` lists the projects with their page URLs. The key comes from `BAMBUDDY_API_KEY` or Vault `secret/bambuddy-agent`, which admins and emo (policy `projects-emo`) can read.

A project folder holds the model files (`.stl`, `.3mf`), the design source (`.py`, `.scad`), a `README.md` that Bambuddy shows with the folder, renders and test-fit photos.

## The printer

Bambuddy reaches the printer directly on the Sofia LAN with its serial number and LAN access code (Vault `secret/emo/bambu-p2s`). The printer stays in cloud mode with Bambu Handy working. In that mode Bambu's authorization firmware lets other software read the status and the camera, but not start a print. Starting a print from Bambuddy needs Developer Mode on the printer, which turns off Bambu Cloud and the Handy app. That switch is Emo's decision; until then Emo prints from Bambu Studio or Handy.

The printer is powered through the Shelly plug "P2S принтер" (192.168.1.111). When the plug is off, Bambuddy shows the printer offline.

The camera allows one stream at a time. Home Assistant (ha-sofia, `ha-bambulab`) and Bambuddy share it, and the one that opens the stream first holds it.

## Upgrades

Change both image tags in `stacks/bambuddy/main.tf` to the same release. Bambuddy migrates its own schema on start. Read the release notes for changes to the `BAMBUDDY_OIDC_*` variables.
