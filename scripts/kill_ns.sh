#!/usr/bin/env bash
set -e

NAMESPACE=$1
if [ -z "$NAMESPACE" ]; then
	echo "Pass in parameter namespace"
	exit 1
fi
kubectl proxy &
kubectl get namespace $NAMESPACE -o json |jq '.spec = {"finalizers":[]}' > /tmp/kill_rogue_ns.json
curl -k -H "Content-Type: application/json" -X PUT --data-binary @/tmp/kill_rogue_ns.json 127.0.0.1:8001/api/v1/namespaces/$NAMESPACE/finalize
kill %1
