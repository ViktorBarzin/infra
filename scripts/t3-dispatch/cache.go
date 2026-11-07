// Long-lived caching for t3's content-hashed build files.
//
// t3 serve sends every file under /assets/ with "Cache-Control: no-cache", so
// a browser revalidates all of them (about 180 requests) on each app open.
// On a slow or lossy client link that burst is where loads fail: on
// 2026-11-07, from a phone in mainland China, 98 of ~230 such requests stalled
// for 60s on the way back to the client, while t3 serve itself answered each
// one in under a millisecond. Vite names every chunk after a hash of its
// content (react-dom-BEKrT875.js), so a given name never changes meaning, and
// marking those files immutable lets the browser skip the burst after one
// good load. A new t3 release ships new names, which the no-cache index.html
// points at, so nothing stale is ever served.
package main

import (
	"net/http"
	"regexp"
)

const immutableCacheControl = "public, max-age=31536000, immutable"

// hashedAssetRe matches a single-segment Vite chunk: name, "-", an 8-char
// base64url content hash, then an extension. Files inside versioned
// subdirectories (assets/pdfjs-6.4.299/...) are not hashed per file and
// do not match.
var hashedAssetRe = regexp.MustCompile(`^/assets/[^/]+-[A-Za-z0-9_-]{8}\.[A-Za-z0-9]+$`)

func isHashedAsset(path string) bool {
	return hashedAssetRe.MatchString(path)
}

// markImmutable is a ModifyResponse step: a 200 or 304 for a hashed asset gets
// the long-lived header. A 304 carries it too, so a browser holding an entry
// from before this change upgrades it on its next revalidation.
func markImmutable(resp *http.Response) {
	if resp.Request == nil || !isHashedAsset(resp.Request.URL.Path) {
		return
	}
	if resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusNotModified {
		resp.Header.Set("Cache-Control", immutableCacheControl)
	}
}

// modifyResponse is the proxy's ModifyResponse hook for ordinary requests.
func modifyResponse(resp *http.Response) error {
	markImmutable(resp)
	return injectPWATags(resp) // HTML documents only; see pwa.go
}
