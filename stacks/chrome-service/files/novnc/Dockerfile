FROM docker.io/library/ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      x11vnc \
      novnc \
      websockify \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# noVNC ships /usr/share/novnc/vnc.html; alias to index.html so / works.
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

EXPOSE 6080

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
