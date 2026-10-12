#!/bin/sh
# Roll a first-party app onto the image its GitHub Actions build just pushed.
# Run by .woodpecker/first-party-deploy.yml; the header there describes the
# trigger. Tests: scripts/first_party_deploy_test.py.
#
# Inputs (Woodpecker manual-pipeline variables, so plain env vars here):
#   APP           one of the apps in the table below
#   IMAGE_TAG     the tag the build pushed
#   IMAGE_DIGEST  optional sha256:<64 hex>; the image becomes tag@digest
#
# The caller picks the app and the tag. Namespace, Deployment, containers and
# image repository come from the table, so a trigger can only move a listed
# app onto another tag of its own image.
set -eu

app="${APP:-}"
tag="${IMAGE_TAG:-}"
digest="${IMAGE_DIGEST:-}"

# Validate before anything reaches a command line.
if ! printf '%s' "$tag" | grep -Eqx '[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}'; then
  echo "refusing IMAGE_TAG '$tag'" >&2
  exit 1
fi
ref="$tag"
if [ -n "$digest" ]; then
  if ! printf '%s' "$digest" | grep -Eqx 'sha256:[a-f0-9]{64}'; then
    echo "refusing IMAGE_DIGEST '$digest'" >&2
    exit 1
  fi
  ref="$tag@$digest"
fi

g=ghcr.io/viktorbarzin

# One line per Deployment: namespace, deployment, then container=image pairs.
# `set image` addresses init containers by name as well.
case "$app" in
  excalidraw)
    targets="excalidraw excalidraw excalidraw=$g/excalidraw-library:$ref" ;;
  interview-prep-app)
    targets="interview-prep-app interview-prep-app interview-prep-app=$g/interview-prep-app:$ref" ;;
  k8s-portal)
    targets="k8s-portal k8s-portal portal=$g/k8s-portal:$ref" ;;
  learning)
    targets="learning learning learning=$g/learning:$ref" ;;
  pages-publish)
    targets="pages-publish pages-publish pages-publish=$g/pages-publish:$ref" ;;
  repowise)
    r="$g/repowise:$ref"
    targets="repowise repowise cross-repo=$r api=$r web=$r sync=$r" ;;
  trading-bot)
    # One build tags both images with the same 0.1.N, so they move together.
    s="$g/trading-bot-service:$ref"
    targets="trading-bot trading-bot-frontend dashboard=$g/trading-bot-dashboard:$ref api-gateway=$s
trading-bot trading-bot-workers signal-generator=$s learning-engine=$s market-data=$s meet-kevin-watcher=$s kevin-signal-bridge=$s trade-executor=$s" ;;
  *)
    echo "unknown APP '$app'" >&2
    exit 1 ;;
esac

# Set every Deployment first, then wait on each, so a slow rollout does not
# hold back the next one. A Deployment scaled to 0 (Sablier idle, or parked)
# reports success at once and starts on the new image when it next scales up.
rollouts=""
nl='
'
IFS="$nl"
for line in $targets; do
  IFS=' '
  # shellcheck disable=SC2086 # splitting the line into words is the point
  set -- $line
  ns=$1
  deploy=$2
  shift 2
  echo "kubectl -n $ns set image deployment/$deploy $*"
  kubectl -n "$ns" set image "deployment/$deploy" "$@"
  rollouts="$rollouts$ns/$deploy$nl"
  IFS="$nl"
done

for r in $rollouts; do
  kubectl -n "${r%%/*}" rollout status "deployment/${r#*/}" --timeout=300s
done
