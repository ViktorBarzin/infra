# Quick Task 1: Fix Broken Demo Streams and Improve Health Checking

## Objective

Replace the broken Akamai live test stream (whose variant playlists return 404 despite master playlist returning 200) with a working test stream, and improve the health checker to validate variant playlists so broken streams are caught before being displayed to users. Rebuild and deploy the updated image.

## Context

- The F1 streaming site at f1.viktorbarzin.me has 3 demo streams
- Akamai live test stream (`cph-p2p-msl.akamaized.net/hls/live/2000341/test/master.m3u8`) has a working master playlist but all variant playlists return 404
- Current health check only validates the master playlist URL (checks for `#EXTM3U`), missing the broken variants
- When hls.js tries to load the variant through the proxy, it gets 502 errors
- The other 2 streams (Big Buck Bunny, Apple Bipbop) work correctly end-to-end
- Confirmed working replacement: Tears of Steel (`demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8`) - all variants return 200

## Tasks

### Task 1: Replace broken Akamai stream URL in demo extractor

**files:** `stacks/f1-stream/files/backend/extractors/demo.py`
**action:** Replace the Akamai live test stream URL with Tears of Steel. Update the title, quality, and any other metadata.
**verify:** Run the demo extractor's URL through curl to confirm master and variant playlists both return 200.
**done:** Demo extractor returns 3 working stream URLs, none of which have broken variants.

Replace:
- URL: `https://cph-p2p-msl.akamaized.net/hls/live/2000341/test/master.m3u8`
- Title: "Akamai Live Test Stream"
- Quality: "" (empty)

With:
- URL: `https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8`
- Title: "Tears of Steel (Test Stream)"
- Quality: "1080p"

### Task 2: Improve health checker to validate variant playlists

**files:** `stacks/f1-stream/files/backend/health.py`
**action:** After the existing health check passes (master playlist has `#EXTM3U`), if the playlist is a master playlist (contains `#EXT-X-STREAM-INF:`), extract the first variant URI and do a HEAD/GET check on it. Mark the stream as unhealthy if the variant returns non-200.
**verify:** A stream with a broken variant (like the old Akamai one) would be marked `is_live=False`.
**done:** Health checker validates at least one variant playlist when the stream is a master playlist.

### Task 3: Rebuild Docker image and deploy

**files:** `stacks/f1-stream/main.tf`
**action:** Build new Docker image with tag v5.1.0, push to registry, update Terraform deployment image tag, apply the stack.
**verify:** `curl https://f1.viktorbarzin.me/streams` returns 3 streams all with `is_live: true`. Visit f1.viktorbarzin.me/watch in browser and confirm all 3 streams play.
**done:** All 3 demo streams are playable in the browser at f1.viktorbarzin.me/watch.
