#!/bin/sh
set -e

CACHE_DIR="${CACHE_DIR:-/data/cache}"
POISON_URL="${POISON_URL:-https://rnsaffn.com/poison2/}"
FETCH_COUNT="${FETCH_COUNT:-50}"
MAX_CACHE_FILES="${MAX_CACHE_FILES:-100}"

mkdir -p "$CACHE_DIR"

echo "Fetching $FETCH_COUNT poison documents from $POISON_URL"

fetched=0
for i in $(seq 1 "$FETCH_COUNT"); do
  OUTPUT="$CACHE_DIR/poison_$(date +%s)_${i}.txt"
  if curl -sS --compressed -o "$OUTPUT" -m 30 "$POISON_URL" 2>/dev/null; then
    # Verify file is non-empty
    if [ -s "$OUTPUT" ]; then
      fetched=$((fetched + 1))
      echo "  [$i/$FETCH_COUNT] OK"
    else
      rm -f "$OUTPUT"
      echo "  [$i/$FETCH_COUNT] Empty response, skipped"
    fi
  else
    rm -f "$OUTPUT"
    echo "  [$i/$FETCH_COUNT] Fetch failed, skipped"
  fi
  sleep 2
done

# Clean up oldest files if cache exceeds limit
total=$(find "$CACHE_DIR" -name '*.txt' -type f | wc -l)
if [ "$total" -gt "$MAX_CACHE_FILES" ]; then
  excess=$((total - MAX_CACHE_FILES))
  find "$CACHE_DIR" -name '*.txt' -type f -printf '%T+ %p\n' | \
    sort | head -n "$excess" | cut -d' ' -f2- | xargs rm -f
  echo "Cleaned $excess old cache files"
fi

echo "Done: fetched $fetched new documents, $(find "$CACHE_DIR" -name '*.txt' -type f | wc -l) total cached"
