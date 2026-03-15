FROM crocodilestick/calibre-web-automated:latest

# Pre-install the universal-calibre mod at build time (avoids apt-get on every container start)
ENV DOCKER_MODS=linuxserver/mods:universal-calibre
RUN /docker-mods || true
# Clear the env so it doesn't re-run at startup
ENV DOCKER_MODS=
