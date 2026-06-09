#!/usr/bin/env bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /tmp/powercheck-armv8 . && rsync /tmp/powercheck-armv8 Administrator@nas:~/server-power-cycle/ && rm /tmp/powercheck-armv8
rsync synology_main.sh Administrator@nas:~/server-power-cycle/
