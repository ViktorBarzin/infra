FROM alpine:3.22
# nsenter (util-linux-misc) to reach the host's systemd; jq for options.json.
RUN apk add --no-cache util-linux-misc jq
COPY lib.sh run.sh /app/
CMD ["/app/run.sh"]
