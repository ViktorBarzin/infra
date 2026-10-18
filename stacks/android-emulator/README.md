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

An f1-stream deploy also puts it to sleep (since 2026-10-17): the f1
Transcoder rolls with a surge pod that needs the emulator's 800 gpumem on
k8s-node1, so `.woodpecker/deploy.yml` in the f1-stream repo scales the
emulator to 0 before that roll and leaves it asleep. A session on the emulator
at that moment is cut off; wake it again through the gate. The deploy's
grant is the `f1-stream-deploy-yield` Role in `gate.tf`.

The Transcoder also rolls when Reloader sees its Secret change and when a
Terraform apply changes its pod template, and neither passes through that
pipeline. So the gate watches too (since 2026-10-17): every 10 s it lists the
pods labelled `android-emulator-yields-to=gpu-seat` in namespace `f1-stream`
(the Transcoder, and since 2026-10-18 the Worker, which also requests gpumem),
and when one waits Pending with `Insufficient viktorbarzin.me/gpumem` it scales
the emulator to 0 and logs which pod it yields to. While such a pod waits,
`/wake` does not scale the emulator up: it answers `"woke": false` with
`"yielding_to": [...]`, `/status` carries the same field, and the gate does
the held-back wake by itself once nothing waits, so polling `/status` for
`"ready": 1` still works. One pod holds the emulator asleep for at most 15 min
(`YIELD_LIMIT_SECONDS`, since 2026-10-18), counted from its `PodScheduled`
timestamp. A pod still waiting after that is short of more than the
emulator's 800 gpumem (another GPU tenant took the seat), so the gate logs
why, lists it under `"gave_up_on"` in `/status`, does any held-back wake, and
wakes the emulator on visits as usual; the `PodUnschedulable` alert reports
that pod. A new pod (the next rollout) gets its own 15 min. The grant is the
`android-emulator-yield-watch` Role in namespace `f1-stream` (list pods).

`/healthz` answers JSON with `"yield_watcher"`: `alive`, `dead` (the thread
exited) or `stuck` (no finished pass for 2 min), plus `last_pass_s_ago`. It
answers 503 unless the watcher is alive, and the liveness probe restarts the
gate after a minute of that. The readiness probe uses `/readyz`, which answers
200 whenever the server is up, so a broken watcher does not take the gate (one
replica) out of its Service while it waits for that restart; visits and
`/wake` keep working.
Tests: `python3 -m unittest discover -s stacks/android-emulator`.

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
- Rendering is on the T4 (`EMULATOR_GPU=host`, since 2026-10-12). The pod
  requests a GPU time-slice and an 800 MiB VRAM seat, which places it on
  k8s-node1. The emulator runs headless (`-no-window -gpu host`) with
  `ANDROID_EGL_ON_EGL=1`, the NVIDIA EGL vendor forced, and the system
  libEGL ahead of the emulator's bundled SwiftShader one. Check the renderer
  with `adb shell dumpsys SurfaceFlinger | grep GLES:`; it should name the
  Tesla T4.
- The noVNC view shows a scrcpy window in Xvfb, not the emulator's own
  window. scrcpy starts when a viewer connects to x11vnc and stops 30s after
  the last one leaves, because its H.264 encoding runs in software inside the
  guest and costs about 2.5 cores. The first frame takes a few seconds after
  the page opens.
- `EMULATOR_GPU=swiftshader` switches back to CPU rendering, windowed
  straight into Xvfb, with no scrcpy. The older windowed `-gpu host` mode
  (2026-06 to 2026-10) mixed Mesa llvmpipe GLES with NVIDIA Vulkan and
  segfaulted; neither current mode does that. See the ADR-0001 amendments.

## Rebuilding the image

GitHub Actions (`.github/workflows/build-android-emulator.yml`) builds
`ghcr.io/viktorbarzin/android-emulator:latest` on any change under `docker/`.
The deployment pulls `:latest` with `imagePullPolicy: Always`, so the next
container start (a restart, or a wake from zero) runs the new build.

## Troubleshooting

- Pod CrashLoops with `FATAL: /dev/kvm not present` → node lost the device or
  the privileged/Kyverno exclude regressed (`android-emulator` must be in
  `security_policy_exclude_namespaces`, stacks/kyverno).
- Log ends with `Running multiple emulators with the same AVD` → stale
  `*.lock` files in `/sdk/.android/avd/lab.avd/` left by a killed pod. The
  entrypoint now deletes them before launch (infra#118); on an older image,
  `rm -f` them and delete the pod. If the emulator exits before boot, the
  entrypoint now exits too, so the pod restarts right away instead of waiting
  out the 30 min startup probe.
- Wedged Android (won't boot, storage full) → delete the PVC + pod: next boot
  re-downloads cleanly. Snapshots/AVD state are disposable by design.
- Different API level: set `API_LEVEL` env on the deployment (entrypoint
  installs that system image on the same PVC) or recreate the AVD.

## Resource profile (measured 2026-06-12, v6 on node1, GPU mode)

- **Asleep (scaled to zero)**: nothing — the gate (~10m CPU/13Mi) is the only
  standing cost.
- **Awake**: settles to **~0.5–1.3 cores** with a static screen (on or off),
  ~4.8–5.2 Gi memory (limit 8 Gi, requests 3 Gi), ~100 MiB T4 VRAM. Boot
  bursts 5–9 cores for the first few minutes (dex2oat etc.).
- Measured 2026-10-10 under continuous Chrome scrolling: ~8.3 cores with
  CPU rendering against ~6.8 cores in the old mixed GPU mode.
- Measured 2026-10-12 in the current T4 mode, emulator process only: 1.17
  cores on a static screen and 2.35 while scrolling Chrome. An open noVNC
  view adds about 2.5 cores for scrcpy. VRAM peaked at 693 MiB over 10
  minutes of Chrome scrolling.
- **Disk**: ~7 G of the 30 Gi PVC.
- Etiquette still applies for long sessions with animated content:
  `adb -s 10.0.20.200:5555 shell input keyevent KEYCODE_SLEEP` when done.

## Remote access

https://android-emulator.viktorbarzin.me (Cloudflare-proxied, Authentik-gated)
serves the same noVNC screen for off-LAN use. adb stays LAN-only by design.
