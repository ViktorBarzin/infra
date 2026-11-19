# systemd-journal-remote, the receiver for systemd-journal-upload. Hosts outside
# the cluster (ha-london today) upload their journal over HTTP; this container
# writes it to journal files in /var/log/journal/remote/, one file set per
# sending host, and the alloy-journal pod's Alloy reads them into Loki.
# Built on GHA (.github/workflows/build-journal-remote.yml), tag = VERSION.
FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd-journal-remote \
 && rm -rf /var/lib/apt/lists/*
COPY journal-remote.conf /etc/systemd/journal-remote.conf
EXPOSE 19532
ENTRYPOINT ["/usr/lib/systemd/systemd-journal-remote", "--listen-http=19532", "--output=/var/log/journal/remote/"]
