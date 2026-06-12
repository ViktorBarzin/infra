#!/usr/bin/env bash
# Boot sequence: ensure SDK + AVD on the PVC (/sdk), bring up a virtual
# display with browser viewing (Xvfb → x11vnc → noVNC :6080), start the
# emulator windowed into it, and expose its adbd on :5555 for the LAN.
set -euo pipefail

# Containerd grants an effectively unbounded RLIMIT_NOFILE (2^31); x11vnc's
# connection handling sweeps the whole fd table with fcntl per fd, so every
# VNC connect hung for ages. Cap it for everything we launch.
ulimit -n 65536

API_LEVEL="${API_LEVEL:-36}"
SYSTEM_IMAGE="system-images;android-${API_LEVEL};google_apis;x86_64"
# Pinned emulator build (36.1.9). The sdkmanager-latest emulator (36.6.11)
# hangs before executing a single guest instruction in this pod (KVM and TCG
# alike, all gpu modes) — debugged 2026-06-11; 36.1.9 boots fine. Bump only
# after verifying a newer build actually boots here.
EMULATOR_BUILD="${EMULATOR_BUILD:-13823996}"
AVD_NAME="${AVD_NAME:-lab}"
EMULATOR_RAM_MB="${EMULATOR_RAM_MB:-4096}"
SCREEN_GEOMETRY="${SCREEN_GEOMETRY:-1080x2280x24}"

[ -e /dev/kvm ] || { echo "FATAL: /dev/kvm not present — pod needs the kvm hostPath + privileged"; exit 1; }

mkdir -p "$ANDROID_USER_HOME"

# --- SDK packages on the PVC (idempotent; first boot downloads ~2.5GB) ------
# A directory existing is NOT proof of a complete install (an interrupted
# sdkmanager leaves partial trees that avdmanager rejects with "Valid system
# image paths are: null") — so completion is tracked with a marker file
# written only after sdkmanager succeeds.
MARKER="/sdk/.sdk-install-complete-android-${API_LEVEL}"
if [ ! -f "$MARKER" ]; then
  echo "Installing SDK packages into /sdk (first boot or prior partial install)..."
  rm -rf "/sdk/system-images/android-${API_LEVEL}"
  # (yes || true): yes dies of SIGPIPE (141) when sdkmanager stops reading,
  # which set -o pipefail would otherwise turn into a fatal error.
  (yes || true) | sdkmanager --sdk_root=/sdk --licenses >/dev/null
  for attempt in 1 2 3; do
    if sdkmanager --sdk_root=/sdk "platform-tools" "emulator" "$SYSTEM_IMAGE"; then
      break
    fi
    echo "sdkmanager attempt $attempt failed; retrying in 10s..." >&2
    [ "$attempt" = 3 ] && exit 1
    sleep 10
  done
  # the package manifest is what avdmanager actually validates against
  test -f "/sdk/system-images/android-${API_LEVEL}/google_apis/x86_64/package.xml"
  touch "$MARKER"
fi

# --- pin the emulator build (replaces whatever sdkmanager installed) ---------
if [ ! -f "/sdk/.emulator-pinned-${EMULATOR_BUILD}" ]; then
  echo "Pinning emulator build ${EMULATOR_BUILD}..."
  wget -q "https://dl.google.com/android/repository/emulator-linux_x64-${EMULATOR_BUILD}.zip" -O /sdk/emu.zip
  rm -rf /sdk/emulator
  unzip -qo /sdk/emu.zip -d /sdk && rm -f /sdk/emu.zip
  rm -f /sdk/.emulator-pinned-*
  touch "/sdk/.emulator-pinned-${EMULATOR_BUILD}"
fi

# --- AVD (idempotent) --------------------------------------------------------
# avdmanager IGNORES ANDROID_SDK_ROOT (and has no --sdk_root): it derives the
# SDK root from its own toolsdir. Run it from a copy of cmdline-tools seeded
# INSIDE /sdk so it resolves the PVC as the root — otherwise it looks under
# /opt/android and reports "Valid system image paths are: null".
if [ ! -x /sdk/cmdline-tools/latest/bin/avdmanager ]; then
  mkdir -p /sdk/cmdline-tools
  cp -a /opt/android/cmdline-tools/latest /sdk/cmdline-tools/latest
fi
AVDMANAGER=/sdk/cmdline-tools/latest/bin/avdmanager
if ! "$AVDMANAGER" list avd -c | grep -qx "$AVD_NAME"; then
  echo "Creating AVD '$AVD_NAME' (${SYSTEM_IMAGE}, pixel_7)..."
  (echo no || true) | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" --device pixel_7
  cat >> "${ANDROID_AVD_HOME}/${AVD_NAME}.avd/config.ini" <<EOF
hw.ramSize=${EMULATOR_RAM_MB}
disk.dataPartition.size=8192M
hw.keyboard=yes
EOF
fi

# --- noVNC defaults: scaled view, autoconnect, self-reconnect ----------------
cat > /usr/share/novnc/defaults.json <<'JSON'
{
  "autoconnect": true,
  "reconnect": true,
  "reconnect_delay": 2000,
  "resize": "scale",
  "shared": true
}
JSON

# --- virtual display + browser viewing ---------------------------------------
export DISPLAY=:0
Xvfb :0 -screen 0 "$SCREEN_GEOMETRY" -nolisten tcp &
sleep 1
openbox &
x11vnc -display :0 -nopw -forever -shared -quiet -nolookup -bg
websockify --web /usr/share/novnc 6080 localhost:5900 &

# --- emulator -----------------------------------------------------------------
# Use the host GPU when the NVIDIA runtime injected one (driver libs +
# /dev/nvidia* appear when the pod requests nvidia.com/gpu), otherwise
# swiftshader (CPU rendering). If the GPU launch dies early, fall back to
# swiftshader automatically so the worst case equals CPU rendering.
GPU_FLAG="swiftshader_indirect"
[ -e /dev/nvidiactl ] && GPU_FLAG="host"
echo "Emulator GPU mode: $GPU_FLAG"

launch_emulator() {
  emulator -avd "$AVD_NAME" \
    -gpu "$1" -accel on \
    -memory "$EMULATOR_RAM_MB" \
    -no-audio -no-boot-anim \
    &
  EMU_PID=$!
}

launch_emulator "$GPU_FLAG"
if [ "$GPU_FLAG" = "host" ]; then
  sleep 25
  if ! kill -0 "$EMU_PID" 2>/dev/null; then
    echo "GPU launch (-gpu host) died early — falling back to swiftshader." >&2
    rm -f "${ANDROID_AVD_HOME}/${AVD_NAME}.avd"/*.lock
    launch_emulator swiftshader_indirect
  fi
fi

adb wait-for-device
echo "Emulator up; waiting for boot completion..."
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  sleep 3
done
echo "Boot completed."

# Expose the emulator's adbd (localhost:5555) to the pod network. Plain TCP,
# no auth — reachable only inside the LAN via the MetalLB IP. Bind to the pod
# IP only: the emulator itself already listens on 127.0.0.1:5555, so a
# wildcard bind fails with EADDRINUSE.
POD_IP=$(hostname -i | awk '{print $1}')
socat "TCP-LISTEN:5555,bind=${POD_IP},fork,reuseaddr" TCP:127.0.0.1:5555 &

# Supervise: if any background process dies, exit so the pod restarts.
wait -n
echo "A supervised process exited; restarting pod." >&2
exit 1
