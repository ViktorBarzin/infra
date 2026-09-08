#!/usr/bin/env bash
# chrome-service POOL worker entrypoint. A stateless, ephemeral headful Chrome
# for the browser pool: same real-Chrome + Xvfb + stealth-friendly flags as the
# master, but NO noVNC and NO persistent login — the caller injects the master's
# storage_state into a fresh Playwright context per run (read-only, no write-back;
# see docs/plans/2026-07-13-chrome-service-pool-design.md). One session per pod;
# the broker reaps it via activeDeadlineSeconds / pod delete.
set -e

CHROMIUM=/opt/google/chrome/chrome
if [ ! -x "$CHROMIUM" ]; then
  echo "ERROR: google-chrome not found at $CHROMIUM (wrong image?)" >&2
  exit 1
fi
echo "[chrome-worker] using browser: $($CHROMIUM --version 2>/dev/null || echo "$CHROMIUM")"

# 1920x1080 to match the master (Viktor's bigger-screen decision); the caller's
# Playwright context viewport is what actually sizes the page, but the Xvfb
# framebuffer + window must be at least as large or the view is cut off.
Xvfb :99 -screen 0 1920x1080x24 -listen tcp -ac &
sleep 1

mkdir -p /profile/chromium-data

# Same CDP bridge as the master: stock Chrome ignores --remote-debugging-address,
# so Chrome binds 127.0.0.1:9223 and cdp_bridge.py forwards 0.0.0.0:9222 -> :9223
# (the Service / readiness probe / NetworkPolicy all stay on 9222).
python3 /scripts/cdp_bridge.py &
BRIDGE_PID=$!
trap "kill $BRIDGE_PID 2>/dev/null" EXIT

exec "$CHROMIUM" \
  --remote-debugging-port=9223 \
  --remote-allow-origins=* \
  --user-data-dir=/profile/chromium-data \
  --no-sandbox \
  --no-first-run \
  --no-default-browser-check \
  --disable-blink-features=AutomationControlled \
  --disable-features=IsolateOrigins,site-per-process \
  --autoplay-policy=no-user-gesture-required \
  --disable-dev-shm-usage \
  --password-store=basic \
  --use-mock-keychain \
  --window-position=0,0 \
  --window-size=1920,1080 \
  about:blank
