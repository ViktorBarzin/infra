# android-emulator — shared in-cluster Android testing instance

Android 16 (API 36, `google_apis/x86_64`) emulator running under KVM in the
cluster, so agents can natively test app/PWA changes before shipping (first
tenant: tripit). Decision record: `docs/adr/0001-android-emulator-in-cluster.md`.

## On-demand lifecycle (since 2026-06-12)

The emulator **scales to zero when idle** (no adb/VNC connections for ~1h,
checked by the `android-emulator-idle-sleeper` CronJob) and **wakes on
visit**: the wake gate owns `/` on both hostnames. Warm boot is ~90s.

- Humans: open https://android-emulator.viktorbarzin.me — it wakes the
  emulator if needed, shows a self-refreshing boot page, then hands over to
  the noVNC screen.
- Agents (before adb): wake + poll, then connect:

      curl -ks --resolve android-emulator.viktorbarzin.lan:443:10.0.20.203 https://android-emulator.viktorbarzin.lan/wake
      until curl -ks --resolve android-emulator.viktorbarzin.lan:443:10.0.20.203 https://android-emulator.viktorbarzin.lan/status | grep -q '"ready": 1'; do sleep 5; done
      adb connect 10.0.20.200:5555

## Endpoints

| What | Where |
|---|---|
| adb | `adb connect 10.0.20.200:5555` (LAN only; adb is unauthenticated — never expose publicly) |
| Screen (noVNC) | <https://android-emulator.viktorbarzin.lan/vnc.html> (LAN only) |

## Agent quickstart (from a devvm)

```bash
# one-time: user-local platform-tools
wget -qO /tmp/pt.zip https://dl.google.com/android/repository/platform-tools-latest-linux.zip
unzip -q /tmp/pt.zip -d ~/android-sdk   # → ~/android-sdk/platform-tools/adb

adb="$HOME/android-sdk/platform-tools/adb"
$adb connect 10.0.20.200:5555
$adb -s 10.0.20.200:5555 install app-debug.apk          # install an APK
$adb -s 10.0.20.200:5555 shell am start -a android.intent.action.VIEW -d https://tripit.viktorbarzin.me   # open a URL
$adb -s 10.0.20.200:5555 shell input tap 540 1200        # drive the UI
$adb -s 10.0.20.200:5555 exec-out screencap -p > /tmp/screen.png   # screenshot
```

The emulator is a single shared instance — `adb shell pm list packages`,
uninstall your test app when done, and presence-claim
(`presence claim service:android-emulator`) for long destructive sessions
(wipes, system-image changes).

## How it works

- The container image (built from `docker/`) holds only JDK 17, cmdline-tools,
  emulator native libs, Xvfb/x11vnc/noVNC and socat — ~1GB.
- The SDK proper (platform-tools, emulator, system image, AVD, snapshots)
  lives on the `android-emulator-sdk` PVC (`proxmox-lvm`); the entrypoint
  installs it idempotently. **First boot downloads ~2.5GB (≈9GB unpacked on the PVC) and takes ~15 min**
  (startup probe allows 30); subsequent restarts boot in ~1–2 min.
- The emulator runs on the GPU node (k8s-node1) with a T4 time-slice and
  `-gpu host` hardware rendering (~0.5–1 GiB VRAM while awake — scale-to-zero
  keeps it transient); if GPU init fails it falls back to swiftshader (CPU)
  automatically.

## Rebuilding the image (rare — tool/library bumps only)

```bash
cd stacks/android-emulator/docker
docker build -t forgejo.viktorbarzin.me/viktor/android-emulator:<new-tag> .
docker push forgejo.viktorbarzin.me/viktor/android-emulator:<new-tag>
# then bump var.image_tag default in variables.tf and land via CI
```

Built manually from a devvm on purpose: it changes rarely, and a one-off push
doesn't warrant CI plumbing (the off-infra-CI rule targets *repeated* build IO).

## Troubleshooting

- Pod CrashLoops with `FATAL: /dev/kvm not present` → node lost the device or
  the privileged/Kyverno exclude regressed (`android-emulator` must be in
  `security_policy_exclude_namespaces`, stacks/kyverno).
- Wedged Android (won't boot, storage full) → delete the PVC + pod: next boot
  re-downloads cleanly. Snapshots/AVD state are disposable by design.
- Different API level: set `API_LEVEL` env on the deployment (entrypoint
  installs that system image on the same PVC) or recreate the AVD.

## Resource profile (measured 2026-06-12)

- **Memory**: ~5.8Gi steady (limit 8Gi, requests 3Gi — Burstable inside the tier-1 quota).
- **CPU**: ~1.8 cores idle with the screen off; **5+ cores with the screen on**
  (any on-screen animation forces continuous swiftshader rendering + VNC
  encoding). Etiquette: turn the screen off when you finish a session —
  `adb -s 10.0.20.200:5555 shell input keyevent KEYCODE_POWER` (and the same
  to wake it).
- **Disk**: ~7G of the 30Gi PVC.

## Remote access

https://android-emulator.viktorbarzin.me (Cloudflare-proxied, Authentik-gated)
serves the same noVNC screen for off-LAN use. adb stays LAN-only by design.
