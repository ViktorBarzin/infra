---
name: traefik-rewrite-body-accept-header
description: |
  Fix for Traefik rewrite-body plugin (packruler/rewrite-body) silently skipping
  content injection (rybbit analytics, trap links, or any HTML rewriting). Use when:
  (1) rewrite-body middleware is enabled but injected content doesn't appear in responses,
  (2) curl shows original HTML with no modifications but browser works fine,
  (3) monitoring.types is set to ["text/html"] but responses aren't being rewritten,
  (4) no errors in Traefik logs despite rewrite-body being in the middleware chain.
  Root cause: the plugin checks the request Accept header (not response Content-Type)
  against monitoring.types, and curl's default Accept: */* does not match text/html.
author: Claude Code
version: 1.0.0
date: 2026-02-22
---

# Traefik Rewrite-Body Accept Header Matching

## Problem
The `packruler/rewrite-body` Traefik plugin silently skips HTML content injection
when the request's `Accept` header doesn't contain a value matching `monitoring.types`.
This means `curl` requests (which send `Accept: */*`) won't show injected content,
while browsers (which send `Accept: text/html,...`) will.

## Context / Trigger Conditions
- rewrite-body middleware is in the ingress middleware chain and shows status "enabled" in Traefik API
- `curl https://example.com/` returns original HTML with no injected content
- Browser shows injected content (rybbit script, trap links, etc.)
- No errors in Traefik logs — the plugin silently skips processing
- `monitoring.types = ["text/html"]` is configured in the middleware spec
- Middleware chain order is correct (strip-accept-encoding before rewrite-body)

## Misleading Symptoms
- Appears as if the middleware isn't working at all
- May look like a middleware ordering issue or configuration error
- `kubectl get middleware` shows the resource exists with correct spec
- Traefik API (`/api/http/middlewares/`) shows the middleware as "enabled"
- Checking the rewrite-body regex patterns seems pointless since nothing is being processed

## Root Cause
In the plugin source code, `SupportsProcessing()` checks:
```go
func (r *Rewriter) SupportsProcessing(req *http.Request) bool {
    accept := req.Header.Get("Accept")
    for _, monitoringType := range r.monitoring.Types {
        if strings.Contains(accept, monitoringType) {
            return true
        }
    }
    return false
}
```

It uses `strings.Contains(accept, "text/html")`. The curl default `Accept: */*` does
NOT contain the substring `text/html`, so the plugin returns false and skips all
processing. Browser requests include `Accept: text/html,application/xhtml+xml,...`
which does match.

## Solution
This is **working as designed** — not a bug. The fix depends on context:

### For testing with curl
Add the `Accept` header to simulate a browser:
```bash
curl -s -H "Accept: text/html,application/xhtml+xml" https://example.com/
```

### For verifying injection is working
```bash
# Check for injected content (trap links, analytics, etc.)
curl -s -H "Accept: text/html,application/xhtml+xml" https://example.com/ \
  | grep -oE 'href="https://poison[^"]*"'

# Check for rybbit analytics
curl -s -H "Accept: text/html,application/xhtml+xml" https://example.com/ \
  | grep -oE 'src="https://rybbit[^"]*"'
```

### For programmatic clients that need injection
If a non-browser client needs to receive injected content, ensure it sends
`Accept: text/html` in its request headers.

## Verification
```bash
# Without Accept header — no injection (expected)
curl -s https://example.com/ | grep -c "rybbit"
# Output: 0

# With Accept header — injection works
curl -s -H "Accept: text/html" https://example.com/ | grep -c "rybbit"
# Output: 1
```

## Notes
- This behavior is independent of the compression issue (see `traefik-rewrite-body-compression`)
- The check is on the **request** `Accept` header, not the **response** `Content-Type`
- `Accept: */*` does NOT match — `strings.Contains("*/*", "text/html")` is false
- Real AI scrapers typically send browser-like Accept headers, so trap links will be
  injected for them correctly
- API calls (which typically send `Accept: application/json`) are correctly skipped

## See Also
- `traefik-rewrite-body-compression` — Different issue: plugin fails to decompress
  gzip responses, corrupting content. That skill covers the compression fix
  (strip-accept-encoding middleware).
- `ingress-factory-migration` — Covers the ingress factory module middleware chain
