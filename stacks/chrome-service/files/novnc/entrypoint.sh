#!/usr/bin/env bash
# Connect to the chrome-service container's Xvfb (shared pod network, TCP)
# and serve the noVNC HTML5 client + websockify bridge on :6080.
set -e

for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if echo > /dev/tcp/127.0.0.1/6099 2>/dev/null; then
    echo "Xvfb TCP up after attempt $i"
    break
  fi
  echo "waiting for Xvfb TCP 6099 attempt=$i"
  sleep 2
done

# websockify runs as PID 1; x11vnc is a child so its logs land on container stdout
# `-noshm` skips MIT-SHM probes that fail across container boundaries (each
# container has its own /dev/shm); `-noxdamage` skips XDAMAGE which Xvfb
# doesn't expose; `-quiet` keeps the polling chatter out of pod logs.
echo "starting x11vnc -> :5900"
x11vnc -display localhost:99 -nopw -listen 0.0.0.0 -rfbport 5900 \
       -forever -shared -noshm -noxdamage -quiet 2>&1 &
X11VNC_PID=$!

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
exec websockify --web=/usr/share/novnc 6080 localhost:5900
