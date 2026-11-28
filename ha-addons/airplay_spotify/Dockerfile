# go-librespot's own image: Alpine with the daemon, libpulse and avahi.
FROM ghcr.io/devgianlu/go-librespot:v0.10.7

# shairport-sync is the AirPlay receiver (Alpine builds it with PulseAudio and
# avahi). dbus lets both receivers announce themselves through one avahi.
RUN apk add --no-cache shairport-sync dbus curl jq

WORKDIR /app
COPY run.sh playing.sh spotify_watch.sh ./
RUN chmod +x run.sh playing.sh spotify_watch.sh

CMD ["/app/run.sh"]
