FROM alpine:3.23

# shairport-sync is the AirPlay receiver (Alpine builds it with PulseAudio and
# avahi); dbus lets it announce itself through avahi.
RUN apk add --no-cache shairport-sync avahi dbus curl jq

WORKDIR /app
COPY run.sh playing.sh ./
RUN chmod +x run.sh playing.sh

CMD ["/app/run.sh"]
