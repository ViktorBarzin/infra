# iVMS-4200 on wine-app

The files in this directory describe Hikvision iVMS-4200 V3 (Windows client)
to the generic `ghcr.io/viktorbarzin/wine-app` image (`images/wine-app/`). The
Terraform module mounts them read-only at `/app`.

| file | purpose |
|---|---|
| `app.env` | version, installer URL + sha256 + Referer, launch path, ready window, winetricks verbs |
| `install.sh` | scripted GUI install of the client components (the installer ignores silent flags) |
| `post-start.sh` | answers the "Upgrade Detection" prompt with Disable, so automatic device firmware pushes are never enabled by accident |
| `pre-stop.sh` | stops WatchDog.exe first (it restarts the servers), then asks the client and servers to close |

## Where iVMS keeps its state

Everything is inside the Wine prefix on the PVC (`/data/prefix`), so nothing
needs symlinking. Observed on 2026-10-17 by diffing the prefix before and
after creating the super user and logging in:

| path under `drive_c` | contents |
|---|---|
| `users/Public/iVMS-4200 Site/UserData/Framework.S/System` | server database: users (the super user is written here), encrypted SQLite-style pages |
| `users/Public/iVMS-4200 Site/UserData/Framework.S/{Entity,Media,Setup.xml}` | server entities and settings |
| `users/Public/iVMS-4200 Site/UserData/DeviceManagement.S/Device` | added devices |
| `users/Public/iVMS-4200 Site/UserData/{AccessController.S,PersonalManagement.S,AlarmCenter.S,Attendance.S}` | access control, persons, events, attendance |
| `users/Public/iVMS-4200 Site/UserData/*.C/` | client-side settings and layouts |
| `users/Public/iVMS-4200 Site/UserData/Log/`, `.../Dump/` | logs and crash dumps |
| `users/Public/iVMS-4200 Site/Nginx/` | the bundled nginx config and logs |
| `Program Files (x86)/iVMS-4200 Site/iVMS-4200 Client/Client/AMRemConfig.xml` and `iVMS-4200.Video.C/*PreviewData.txt` | small client files written next to the binaries |

`UserData` was 1.8 MB with one user and no devices. A backup of
`drive_c/users/Public/iVMS-4200 Site/UserData` is the part worth keeping
outside the PVC; the rest can be reinstalled.

## Upgrades

To upgrade, bump `APP_VERSION`, `APP_INSTALLER_URL` and `APP_INSTALLER_SHA256`.
The entrypoint sees no marker for the new version and runs the new installer
over the existing prefix without wiping it. What we know and do not know yet:

- Re-running the same version (3.14.1.4 over 3.14.1.4) opens an "installation
  maintenance" page with Modify / Repair / Remove and **Remove pre-selected**.
  `install.sh` detects that page and fails without pressing anything; the
  prefix and data stay intact and the old marker stays, so the app keeps its
  data, but the pod restarts until `app.env` is fixed (tested).
- A real upgrade to a newer version has not been tried, because only 3.14.1.4
  is available. Expect its first page to differ from the fresh-install licence
  page; `install.sh` will then fail with a screenshot in the log, and the
  coordinates for that page need adding. Whether the new client migrates the
  `UserData` database on its first start is unknown. Before an upgrade, copy
  `UserData` off the PVC.

## Known gaps

- On 2026-10-17 a super user created in the same container run as the first
  install was not written to `Framework.S/System` and was gone after a
  restart, while one created after a restart was written and survived two
  further restarts. The cause is not known. The entrypoint now re-execs itself
  after an install, so the first session starts from a clean boot; with that
  change a fresh install, super user created in the first session, stop and
  new container kept the login (one run, 2026-10-17).
- `pre-stop.sh` asks the servers to close, but they were still running after
  its 15 s wait in every test, so the generic `wineboot --force` / `wineserver -k`
  ends them. The database survived those stops in the tests, but this is not a
  clean shutdown.
- The video decoder (`DecodeProcess.exe`) needs `WINEPATH` (set in `app.env`)
  to find its DLLs. Live video itself has not been tested.
- The installer shows some labels as blank boxes (font rendering in its
  layered windows). Cosmetic; the client renders normally.
