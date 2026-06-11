#!/usr/bin/env bash
# Boot sequence: ensure SDK + AVD on the PVC (/sdk), bring up a virtual
# display with browser viewing (Xvfb → x11vnc → noVNC :6080), start the
# emulator windowed into it, and expose its adbd on :5555 for the LAN.
set -euo pipefail

API_LEVEL="${API_LEVEL:-36}"
SYSTEM_IMAGE="system-images;android-${API_LEVEL};google_apis;x86_64"
AVD_NAME="${AVD_NAME:-lab}"
EMULATOR_RAM_MB="${EMULATOR_RAM_MB:-4096}"
SCREEN_GEOMETRY="${SCREEN_GEOMETRY:-1080x2280x24}"

[ -e /dev/kvm ] || { echo "FATAL: /dev/kvm not present — pod needs the kvm hostPath + privileged"; exit 1; }

mkdir -p "$ANDROID_USER_HOME"

# --- SDK packages on the PVC (idempotent; first boot downloads ~2.5GB) ------
if [ ! -x /sdk/platform-tools/adb ] || [ ! -x /sdk/emulator/emulator ] || \
   [ ! -d "/sdk/system-images/android-${API_LEVEL}" ]; then
  echo "Installing SDK packages into /sdk (first boot)..."
  # (yes || true): yes dies of SIGPIPE (141) when sdkmanager stops reading,
  # which set -o pipefail would otherwise turn into a fatal error.
  (yes || true) | sdkmanager --sdk_root=/sdk --licenses >/dev/null
  sdkmanager --sdk_root=/sdk "platform-tools" "emulator" "$SYSTEM_IMAGE"
fi

# --- AVD (idempotent) --------------------------------------------------------
if ! avdmanager list avd -c | grep -qx "$AVD_NAME"; then
  echo "Creating AVD '$AVD_NAME' (${SYSTEM_IMAGE}, pixel_7)..."
  (echo no || true) | avdmanager create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" --device pixel_7
  cat >> "${ANDROID_AVD_HOME}/${AVD_NAME}.avd/config.ini" <<EOF
hw.ramSize=${EMULATOR_RAM_MB}
disk.dataPartition.size=8192M
hw.keyboard=yes
EOF
fi

# --- virtual display + browser viewing ---------------------------------------
export DISPLAY=:0
Xvfb :0 -screen 0 "$SCREEN_GEOMETRY" -nolisten tcp &
sleep 1
openbox &
x11vnc -display :0 -nopw -forever -shared -quiet -bg
websockify --web /usr/share/novnc 6080 localhost:5900 &

# --- emulator -----------------------------------------------------------------
# swiftshader = CPU rendering (no GPU dependency); KVM does the heavy lifting.
emulator -avd "$AVD_NAME" \
  -gpu swiftshader_indirect -accel on \
  -memory "$EMULATOR_RAM_MB" \
  -no-audio -no-boot-anim \
  &

adb wait-for-device
echo "Emulator up; waiting for boot completion..."
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  sleep 3
done
echo "Boot completed."

# Expose the emulator's adbd (localhost:5555) to the pod network. Plain TCP,
# no auth — reachable only inside the LAN via the MetalLB IP.
socat TCP-LISTEN:5555,fork,reuseaddr TCP:127.0.0.1:5555 &

# Supervise: if any background process dies, exit so the pod restarts.
wait -n
echo "A supervised process exited; restarting pod." >&2
exit 1
