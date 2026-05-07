#!/bin/sh
# Forgejo container-package retention.
#
# For each container package owned by ${FORGEJO_OWNER}, keep newest
# ${KEEP_LAST_N} versions + always keep tag "latest". Deletes the rest via
# DELETE /api/v1/packages/{owner}/container/{name}/{version}.
#
# DRY_RUN=true logs what would be deleted but issues no DELETE calls.
#
# Required env:
#   FORGEJO_HOST   e.g. http://forgejo.forgejo.svc.cluster.local
#   FORGEJO_OWNER  e.g. viktor
#   FORGEJO_USER   PAT owner (write:package scope)
#   FORGEJO_TOKEN  PAT
#   KEEP_LAST_N    integer (default 10)
#   DRY_RUN        true|false (default true)

set -eu

apk add --no-cache curl jq >/dev/null

OWNER="${FORGEJO_OWNER}"
KEEP="${KEEP_LAST_N:-10}"
DRY="${DRY_RUN:-true}"
BASE="${FORGEJO_HOST%/}/api/v1"

AUTH_HEADER="Authorization: token $FORGEJO_TOKEN"

echo "Forgejo cleanup: owner=$OWNER keep_last=$KEEP dry_run=$DRY"
echo "API base: $BASE"

# Page through ALL container packages.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
ALL="$TMPDIR/all.json"
echo "[]" > "$ALL"

PAGE=1
while :; do
  RESP=$(curl -sf -H "$AUTH_HEADER" \
    "$BASE/packages/$OWNER?type=container&limit=50&page=$PAGE")
  COUNT=$(echo "$RESP" | jq 'length')
  if [ "$COUNT" = "0" ]; then break; fi
  jq -s '.[0] + .[1]' "$ALL" <(echo "$RESP") > "$TMPDIR/merged.json"
  mv "$TMPDIR/merged.json" "$ALL"
  PAGE=$((PAGE + 1))
  # Safety: never run away.
  if [ "$PAGE" -gt 100 ]; then break; fi
done

TOTAL=$(jq 'length' "$ALL")
echo "Found $TOTAL package version(s)."

if [ "$TOTAL" = "0" ]; then
  echo "Nothing to do."
  exit 0
fi

# Group by name and process each group.
NAMES=$(jq -r '.[].name' "$ALL" | sort -u)

DEL=0
KEPT=0

for NAME in $NAMES; do
  # All versions of this name, sorted by created_at descending.
  jq --arg n "$NAME" '
    [.[] | select(.name == $n)]
    | sort_by(.created_at) | reverse
  ' "$ALL" > "$TMPDIR/$NAME.json"

  N_VERSIONS=$(jq 'length' "$TMPDIR/$NAME.json")
  echo "[$NAME] $N_VERSIONS version(s)"

  # Build the keep set: top $KEEP + anything tagged 'latest'.
  jq -r --argjson keep "$KEEP" '
    [.[0:$keep][].version] + [.[] | select(.version == "latest") | .version]
    | unique
    | .[]
  ' "$TMPDIR/$NAME.json" > "$TMPDIR/$NAME.keep"

  # Build the delete set.
  jq -r '.[].version' "$TMPDIR/$NAME.json" \
    | grep -vxFf "$TMPDIR/$NAME.keep" > "$TMPDIR/$NAME.delete" || true

  D_COUNT=$(wc -l < "$TMPDIR/$NAME.delete" | tr -d ' ')
  K_COUNT=$(wc -l < "$TMPDIR/$NAME.keep" | tr -d ' ')
  echo "  keep=$K_COUNT delete=$D_COUNT"
  KEPT=$((KEPT + K_COUNT))

  while IFS= read -r VER; do
    [ -z "$VER" ] && continue
    URL="$BASE/packages/$OWNER/container/$NAME/$VER"
    if [ "$DRY" = "true" ]; then
      echo "  DRY_RUN would DELETE $URL"
    else
      HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
        -X DELETE -H "$AUTH_HEADER" "$URL" || echo "000")
      if [ "$HTTP" = "204" ] || [ "$HTTP" = "200" ]; then
        echo "  deleted $NAME:$VER"
      else
        echo "  FAIL $NAME:$VER HTTP $HTTP"
      fi
    fi
    DEL=$((DEL + 1))
  done < "$TMPDIR/$NAME.delete"
done

echo "Summary: kept=$KEPT to_delete=$DEL dry_run=$DRY"
