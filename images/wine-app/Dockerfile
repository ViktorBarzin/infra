# syntax=docker/dockerfile:1.7
#
# wine-app: a generic Wine + noVNC desktop for running one Windows GUI app per
# pod. The image carries no application software and is published publicly as
# ghcr.io/viktorbarzin/wine-app. The app is described by files mounted at /app
# (app.env + install.sh, see README.md); entrypoint.sh downloads, verifies and
# installs it into a Wine prefix on the PVC (/data/prefix) on first start.
#
#   docker buildx build -t ghcr.io/viktorbarzin/wine-app:<tag> .

FROM debian:bookworm-slim AS wine
ENV DEBIAN_FRONTEND=noninteractive

# WineHQ stable, pinned. 11.0 is the version the iVMS spike proved (2026-10-17).
ARG WINE_VERSION=11.0.0.0~bookworm-1
# winetricks release 20260125, pinned by commit.
ARG WINETRICKS_COMMIT=b76e1ee79ac57d7aceb384f74518fc423265810c

RUN set -eux; \
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    mkdir -pm755 /etc/apt/keyrings; \
    curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
      | gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key; \
    curl -fsSL -o /etc/apt/sources.list.d/winehq-bookworm.sources \
      https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources; \
    apt-get update; \
    apt-get install -y --install-recommends \
      winehq-stable="$WINE_VERSION" wine-stable="$WINE_VERSION" \
      wine-stable-amd64="$WINE_VERSION" wine-stable-i386="$WINE_VERSION"; \
    apt-get install -y --no-install-recommends \
      xvfb tigervnc-standalone-server xauth x11-utils xdotool xprintidle novnc websockify openbox \
      imagemagick cabextract unzip file procps iproute2 psmisc tini osslsigncode \
      fonts-dejavu-core; \
    curl -fsSL -o /usr/local/bin/winetricks \
      "https://raw.githubusercontent.com/Winetricks/winetricks/${WINETRICKS_COMMIT}/src/winetricks"; \
    chmod 755 /usr/local/bin/winetricks; \
    apt-get purge -y gnupg; apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# noVNC opens straight into the session: scaled to the browser, reconnecting.
# Scaling is capped at 1:1. Stock noVNC also scales UP when the browser window
# is larger than the screen, which blurs every glyph; capped, a large window
# shows the session pixel for pixel and only a smaller one is scaled down.
RUN set -eux; \
    printf '%s\n' '{"autoconnect": true, "reconnect": true, "reconnect_delay": 2000, "resize": "scale", "shared": true}' \
      > /usr/share/novnc/defaults.json; \
    printf '%s\n' '<!doctype html><meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=1&resize=scale&reconnect=1">' \
      > /usr/share/novnc/index.html; \
    sed -i 's|^\(        this\._rescale(scaleRatio);\)$|        scaleRatio = Math.min(scaleRatio, 1);\n\1|' /usr/share/novnc/core/display.js; \
    grep -q 'scaleRatio = Math.min(scaleRatio, 1);' /usr/share/novnc/core/display.js

RUN useradd -m -u 1000 -s /bin/bash app \
    && mkdir /data /app && chown app:app /data \
    && mkdir -p -m1777 /tmp/.X11-unix

USER app
ENV HOME=/home/app \
    WINEPREFIX=/data/prefix \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    DISPLAY=:0
WORKDIR /home/app

FROM wine AS final
# Pre-fetch the Microsoft core fonts into the winetricks download cache, so a
# first start does not depend on the font mirrors. winetricks needs a prefix
# to run, so a throwaway one is created and deleted again.
# The prefix is booted before any X server starts: running the very first
# wineboot under xvfb-run failed with "could not load kernel32.dll".
RUN set -eux; \
    export WINEPREFIX="$HOME/fontprefix"; \
    wineboot -i; wineserver -w; \
    Xvfb :5 -nolisten tcp & xvfb=$!; sleep 1; \
    DISPLAY=:5 winetricks -q corefonts; wineserver -w; \
    kill $xvfb; \
    test -n "$(ls "$HOME/.cache/winetricks/corefonts/")"; \
    rm -rf "$HOME/fontprefix" /tmp/.wine-* /tmp/winetricks.*

COPY --chmod=755 entrypoint.sh app-ready wine-app-lib.sh /usr/local/bin/

EXPOSE 6080
# Plain tini (no -g): SIGTERM goes to entrypoint.sh only, which shuts Wine
# down in order instead of every Wine process receiving the signal at once.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
