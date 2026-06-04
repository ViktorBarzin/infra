#!/usr/bin/env bash
set -e

docker buildx build --platform linux/amd64 --provenance=false \
  -t viktorbarzin/f1-stream:v2.0.1 -t viktorbarzin/f1-stream:latest \
  --push .
kubectl -n f1-stream rollout restart deployment f1-stream
