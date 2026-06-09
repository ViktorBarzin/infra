#!/bin/bash
# Phase 3: Migrate all service module state from root to individual stacks
# Each module in root state is at: module.kubernetes_cluster.module.<name>["<name>"]
# Target: state/stacks/<name>/terraform.tfstate as module.<name>

set -euo pipefail

ROOT_STATE="$(pwd)/terraform.tfstate"
STATE_DIR="$(pwd)/state/stacks"

# All 64 service modules currently in root state
MODULES=(
  actualbudget
  affine
  blog
  changedetection
  city-guesser
  coturn
  cyberchef
  dashy
  dawarich
  descheduler
  diun
ebook2audiobook
  echo
  excalidraw
  f1-stream
  forgejo
  freedify
  freshrss
  frigate
  hackmd
  health
  homepage
  immich
  isponsorblocktv
  jsoncrack
  kms
  linkwarden
  matrix
  meshcentral
  n8n
  navidrome
  netbox
  networking-toolbox
  nextcloud
  ntfy
  ollama
  onlyoffice
  openclaw
  osm_routing
  owntracks
  paperless-ngx
  plotting-book
  privatebin
  real-estate-crawler
  reloader
  resume
  rybbit
  send
  servarr
  shadowsocks
  speedtest
  stirling-pdf
  tandoor
  tor-proxy
  travel_blog
  tuya-bridge
  url
  wealthfolio
  webhook_handler
  whisper
  ytdlp
)

TOTAL=${#MODULES[@]}
SUCCESS=0
FAIL=0

echo "=== Phase 3: Service State Migration ==="
echo "Migrating $TOTAL modules from root state to individual stacks"
echo ""

for mod in "${MODULES[@]}"; do
  idx=$((SUCCESS + FAIL + 1))
  echo "[$idx/$TOTAL] Migrating: $mod"

  # Create state directory
  mkdir -p "$STATE_DIR/$mod"

  # Source address (with for_each key)
  SRC="module.kubernetes_cluster.module.${mod}[\"${mod}\"]"
  DST="module.${mod}"
  DST_STATE="$STATE_DIR/$mod/terraform.tfstate"

  if terraform state mv \
    -state="$ROOT_STATE" \
    -state-out="$DST_STATE" \
    "$SRC" "$DST" 2>&1; then
    echo "  ✓ $mod migrated successfully"
    SUCCESS=$((SUCCESS + 1))
  else
    echo "  ✗ $mod FAILED"
    FAIL=$((FAIL + 1))
  fi
  echo ""
done

echo "=== Migration Summary ==="
echo "Total:   $TOTAL"
echo "Success: $SUCCESS"
echo "Failed:  $FAIL"
