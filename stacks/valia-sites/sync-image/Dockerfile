# valia-sites-sync: everything the 10-min Content-folder mirror needs, baked in
# (no runtime installs — CronJob pods must not apk/npm on every start).
# rclone pinned to match the proven stem95su version; wrangler pinned to major 4.
FROM node:22-alpine

RUN apk add --no-cache curl unzip ca-certificates jq \
    && curl -fsSL https://downloads.rclone.org/v1.74.3/rclone-v1.74.3-linux-amd64.zip -o /tmp/rclone.zip \
    && unzip -j /tmp/rclone.zip '*/rclone' -d /usr/local/bin \
    && chmod +x /usr/local/bin/rclone \
    && rm /tmp/rclone.zip \
    && npm install -g wrangler@4 \
    && npm cache clean --force

# wrangler writes config/cache under $HOME; the CronJob runs as non-root node (uid 1000)
ENV HOME=/tmp
