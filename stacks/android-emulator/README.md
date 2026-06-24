# android-emulator — shared in-cluster Android testing instance

Android 16 (API 36, `google_apis/x86_64`) emulator running under KVM in the
cluster, so agents can natively test app/PWA changes before shipping (first
tenant: tripit). Decision record: `docs/adr/0001-android-emulator-in-cluster.md`.

## On-demand lifecycle (since 2026-06-12)

The emulator **scales to zero when idle** (no user interaction for 6h —
taps/keys/app-launches/noVNC clicks, read from `dumpsys power` by the
`android-emulator-idle-sleeper` CronJob) and **wakes on visit**: the wake
gate owns `/` on both hostnames. Warm boot is ~90s. Idle is measured from
real interaction, not connection count, so a forgotten `adb connect` (left
ESTABLISHED) no longer keeps it awake — but `adb disconnect` anyway.

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
- The emulator runs on the GPU node (k8s-node1) with a T4 time-slice
  (qemu holds ~100 MiB VRAM while awake; scale-to-zero keeps it transient).
  Guest GL is deliberately SOFTWARE (llvmpipe): rendering into Xvfb pins GL
  to the X stack, and true NVIDIA headless GL would need -no-window plus the
  emulator's own streaming instead of x11vnc — not worth it at the measured
  CPU numbers below.

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

## Resource profile (measured 2026-06-12, v6 on node1)

- **Asleep (scaled to zero)**: nothing — the gate (~10m CPU/13Mi) is the only
  standing cost.
- **Awake**: settles to **~0.5–1.3 cores** with a static screen (on or off),
  ~4.8–5.2 Gi memory (limit 8 Gi, requests 3 Gi), ~100 MiB T4 VRAM. Boot
  bursts 5–9 cores for the first few minutes (dex2oat etc.).
- **Disk**: ~7 G of the 30 Gi PVC.
- Etiquette still applies for long sessions with animated content:
  `adb -s 10.0.20.200:5555 shell input keyevent KEYCODE_SLEEP` when done.

## Remote access

https://android-emulator.viktorbarzin.me (Cloudflare-proxied, Authentik-gated)
serves the same noVNC screen for off-LAN use. adb stays LAN-only by design.
