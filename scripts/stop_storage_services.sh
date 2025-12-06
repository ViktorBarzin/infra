#!/usr/bin/env bash

# Stop services that may become in a corrupted state if storage is suddenly disconnected


set -euxo pipefail

function scale() { kubectl scale deployment --replicas=$3 --namespace $1 $2; }

### ============================
### MAIN
### ============================
cmd="${1:-stop}"
case "$cmd" in
  stop)
    scale calibre calibre-web-automated 0
    scale redis redis 0
    scale uptime-kuma uptime-kuma 0
    scale paperless-ngx paperless-ngx 0
    scale vaultwarden vaultwarden 0
    scale immich immich-postgresql 0
    scale nextcloud nextcloud 0
    scale monitoring prometheus-server 0

    scale technitium technitium 0
    scale dbaas mysql 0
    scale dbaas postgresql 0
    ;;
  start)
    scale dbaas mysql 1
    scale dbaas postgresql 1
    scale technitium technitium 1
    scale immich immich-postgresql 1
    scale nextcloud nextcloud 1
    scale paperless-ngx paperless-ngx 1
    scale monitoring prometheus-server 1
    scale redis redis 1
    scale uptime-kuma uptime-kuma 1
    scale vaultwarden vaultwarden 1
    scale calibre calibre-web-automated 1
    ;;
    # echo "[!] Cleanup only removes links (not flushing all iptables to avoid surprises)."
    # ip netns list | grep -qw "$NS_NAME" && sudo ip netns del "$NS_NAME" || true
    # has_link "$HOST_VETH" && sudo ip link del "$HOST_VETH" || true
    # ;;
  *)
    echo "Usage: $0 [stop|start]"
    exit 1
    ;;
esac
