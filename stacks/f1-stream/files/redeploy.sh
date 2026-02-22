#!/usr/bin/env bash
set -e

docker build -t viktorbarzin/f1-stream .
docker push viktorbarzin/f1-stream
kubectl -n f1-stream rollout restart deployment f1-stream
