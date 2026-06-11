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
