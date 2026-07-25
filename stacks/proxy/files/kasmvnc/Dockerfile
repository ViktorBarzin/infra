# Custom KasmVNC + Chrome browser image for the proxy per-user browsers.
#
# Built off-infra on GHA -> ghcr (ADR-0002). Based on LinuxServer's KasmVNC
# baseimage, which gives us what plain noVNC can't: AUDIO passthrough (PulseAudio
# -> browser over the same WebSocket, no TURN), client-driven DYNAMIC RESOLUTION,
# and H.264/WebCodecs video good for FullHD — all over the existing Traefik/WSS
# ingress. Serves HTTP on CUSTOM_PORT for reverse-proxy use; PASSWORD unset =
# no KasmVNC auth (the unguessable /s/<token> ingress is the gate). infra#81.
FROM lscr.io/linuxserver/baseimage-kasmvnc:ubuntujammy

# Real Google Chrome (the jammy `chromium` apt package is a snap stub that fails
# headless). Non-snap, headless-capable, matches the old chrome-service image.
# The LinuxServer base ships a NodeSource apt source (node_18.x) that now 404s,
# which fails `apt-get update`; drop it (node is already installed in the base).
RUN grep -rl nodesource /etc/apt/sources.list.d/ 2>/dev/null | xargs -r rm -f; \
    apt-get update && \
    apt-get install -y --no-install-recommends wget gnupg ca-certificates fonts-liberation wmctrl xdotool && \
    wget -qO- https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# /defaults/autostart is run by the KasmVNC session (abc user) as the single app.
COPY root/ /
