---
status: accepted
---

# The Android testing environment is a privileged KVM emulator pod in-cluster

Viktor's apps are growing Android clients (first: tripit's Capacitor shell —
see tripit ADR-0013/0014), and agents need a native Android instance to test
changes against before shipping. All K8s nodes already run with CPU type
`host`, so `/dev/kvm` works inside the cluster.

Decision (2026-06-11): one shared **Android 16 (API 36) Google-emulator
instance** runs as a privileged pod in namespace `android-emulator`
(stack `stacks/android-emulator`), with `/dev/kvm` via hostPath, adb exposed
LAN-only on the shared MetalLB IP (10.0.20.200:5555), and a noVNC screen view
at android-emulator.viktorbarzin.lan. The SDK/system-image/AVD live on a PVC;
the image is a slim manually-built shell.

## Considered options

- **devvm-local docker emulator** — rejected as the durable home: shared
  24GB workstation, ~13GB free disk, per-machine, not shared across agents.
- **Dedicated Proxmox VM** — rejected: burns scarce PVE host headroom 24/7
  and adds a whole VM lifecycle for one emulator.
- **redroid (container-native Android)** — rejected: requires binder kernel
  modules on every node (documented binderfs incompatibilities), max
  Android 15; most invasive for the least version coverage.
- **budtmo/docker-android** — rejected: turnkey but capped at Android 14;
  the native features driving the Android work (Live Updates, background
  GPS) are Android 16 behaviors, matching the real target device.
- **/dev/kvm device plugin instead of privileged** — deferred: a new
  cluster component to avoid one namespace-scoped exclude-list entry; the
  exclude pattern (kured/woodpecker/frigate/changedetection) already exists.

## Consequences

- `android-emulator` joins the Kyverno `security_policy_exclude_namespaces`
  list (privileged allowed; registry policy also bypassed in-namespace).
- adb is unauthenticated by design — the LB IP must remain LAN-only.
- Single shared instance: concurrent agent sessions share Android state;
  long destructive work should presence-claim `service:android-emulator`.
- Rendering is swiftshader (CPU) — the contended T4 stays out of the path.

## Amendment, 2026-10-10: back to CPU rendering

From 2026-06-12 the emulator ran `-gpu host` on the T4 node (k8s-node1), with
an automatic fallback to SwiftShader if the GPU launch died in its first 25s.
On 2026-10-10 it was restarting 15 to 28 times a day while awake. Two causes
came out of the logs:

- The entrypoint ran under `set -euo pipefail`, so the window-fitter subshell
  could end itself, and the pod, on one failing `xdotool` call, and a dying
  process left no reason in the log. Fixed separately (infra 192dab3a).
- The emulator segfaulted in `-gpu host` mode: 13 times in 4h, sometimes
  within 25s of launch and otherwise 2 to 40 minutes after boot. There were no
  segfaults in SwiftShader runs, including 35 minutes of continuous Chrome
  scrolling.

What `-gpu host` actually did here: the emulator draws GLES through GLX on the
Xvfb display, and Xvfb has no GPU, so GLES ran on Mesa llvmpipe (software)
while Vulkan went to the NVIDIA T4. The emulator's renderer shares buffers
between its GLES and Vulkan halves, and the NVIDIA driver rejected one such
import in the logs (`VkImageCreateInfo to import AHardwareBuffer contains
unsupported VkImageUsageFlags`). We did not capture a backtrace: an hour of
GPU mode under gdb, half of it under scrolling load, did not crash, and gdb
changes the emulator's signal timing. The link between the mixed drivers and
the crash is therefore inferred from where the crashes happened, not proven.

Decision: SwiftShader for both GLES and Vulkan, and the pod requests no GPU,
so it no longer holds a T4 seat (300 MiB in ADR-0016's chart) or pins to
node1. Measured cost under continuous scrolling: about 8.3 cores against 6.8
in GPU mode. Real GPU rendering remains possible with an X server on the
NVIDIA driver in place of Xvfb; that is a larger change and is not planned.

