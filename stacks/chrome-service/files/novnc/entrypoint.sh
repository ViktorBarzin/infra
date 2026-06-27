#!/usr/bin/env bash
# Connect to the chrome-service container's Xvfb (shared pod network, TCP)
# and serve the noVNC HTML5 client + websockify bridge on :6080.
set -e

# Containerd grants pods an effectively unbounded RLIMIT_NOFILE (2^31). x11vnc
# sweeps the WHOLE fd table with fcntl on every client connection, so each VNC
# connect hangs for ~forever and the noVNC client sits on "Connecting" until it
# times out. Cap it before launching x11vnc. (Same fix as the android-emulator
# stack; see docs/architecture/chrome-service.md "noVNC fd-sweep".)
ulimit -n 65536

for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if echo > /dev/tcp/127.0.0.1/6099 2>/dev/null; then
    echo "Xvfb TCP up after attempt $i"
    break
  fi
  echo "waiting for Xvfb TCP 6099 attempt=$i"
  sleep 2
done

# Both x11vnc and websockify run as supervised children of this entrypoint (PID
# 1) so their logs land on container stdout and the `wait -n` at the end can catch
# either one dying. `-noshm` skips MIT-SHM probes that fail across container
# boundaries (each container has its own /dev/shm); `-noxdamage` skips XDAMAGE
# which Xvfb doesn't expose; `-quiet` keeps the polling chatter out of pod logs.
echo "starting x11vnc -> :5900"
x11vnc -display localhost:99 -nopw -listen 0.0.0.0 -rfbport 5900 \
       -forever -shared -noshm -noxdamage -quiet 2>&1 &

for i in 1 2 3 4 5 6 7 8 9 10; do
  if echo > /dev/tcp/127.0.0.1/5900 2>/dev/null; then
    echo "x11vnc bound 5900 after attempt $i"
    break
  fi
  echo "waiting for x11vnc :5900 attempt=$i"
  sleep 2
done

if ! echo > /dev/tcp/127.0.0.1/5900 2>/dev/null; then
  echo "ERROR: x11vnc did not bind 5900"
  exit 1
fi

echo "starting websockify -> :6080"
# Run websockify in the background (it was `exec`ed before) so BOTH it and x11vnc
# are supervised. x11vnc attaches to the chrome-service container's Xvfb over
# localhost:6099 (shared pod network); when that container restarts, x11vnc loses
# its X connection and exits. Previously websockify was PID 1 and x11vnc was an
# unsupervised child, so a dead x11vnc was never relaunched: :5900 stayed dead and
# the noVNC view went black until a manual pod restart. Now if EITHER process
# exits, `wait -n` returns and we exit non-zero so the kubelet restarts this
# container, which re-waits for Xvfb and relaunches x11vnc — the bridge self-heals
# across browser-container restarts. (Same supervision pattern as the
# android-emulator stack's entrypoint.)
websockify --web=/usr/share/novnc 6080 localhost:5900 &

wait -n || true
echo "novnc: a supervised process (x11vnc or websockify) exited; exiting so the kubelet restarts this container." >&2
exit 1
