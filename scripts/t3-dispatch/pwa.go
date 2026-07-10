// PWA install layer: t3's own web UI ships no manifest or service worker
// (checked v0.0.29-nightly.20260709 — every path SPA-fallbacks to index.html),
// so "Add to Home Screen" on a phone yields a plain browser bookmark. The
// dispatch layer fills the gap without forking upstream: it serves a minimal
// web-app manifest and injects the standalone-app head tags into proxied HTML
// documents, making t3.viktorbarzin.me installable as a chromeless home-screen
// app on iOS/Android. No service worker: t3 is useless offline (live WS to the
// instance), and skipping it avoids the stale-bundle-after-deploy PWA class.
package main

import (
	"bytes"
	"io"
	"net/http"
	"strconv"
	"strings"
)

// pwaManifest is served at /manifest.webmanifest by the dispatcher itself —
// proxied upstream it would SPA-fallback to index.html. The icon reuses the
// bundled apple-touch-icon the upstream UI already serves, so there is no
// asset to keep in sync here.
const pwaManifest = `{
  "name": "T3 Code",
  "short_name": "T3 Code",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "background_color": "#161616",
  "theme_color": "#161616",
  "icons": [{"src": "/apple-touch-icon.png", "sizes": "180x180", "type": "image/png"}]
}`

// pwaHeadTags go in front of </head> of every proxied HTML document. The
// manifest link is the modern install signal (iOS 16.4+/Android); the
// apple-* metas are the legacy-but-reliable iOS standalone signals.
const pwaHeadTags = `<link rel="manifest" href="/manifest.webmanifest"/>` +
	`<meta name="mobile-web-app-capable" content="yes"/>` +
	`<meta name="apple-mobile-web-app-capable" content="yes"/>` +
	`<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent"/>` +
	`<meta name="apple-mobile-web-app-title" content="T3 Code"/>`

// registerPWA registers the manifest endpoint on mux.
func registerPWA(mux *http.ServeMux) {
	mux.HandleFunc("/manifest.webmanifest", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/manifest+json")
		w.Header().Set("Cache-Control", "public, max-age=3600")
		_, _ = w.Write([]byte(pwaManifest))
	})
}

// injectPWATags is a httputil.ReverseProxy ModifyResponse hook that rewrites
// proxied HTML documents to include pwaHeadTags. Non-HTML, content-encoded
// (t3 serve sends HTML plain today; if that ever changes we pass through
// rather than garble), and headless bodies are left untouched. Buffering is
// safe: the only text/html upstream serves is the ~3KB SPA shell — every
// other asset carries a concrete js/css/img type.
func injectPWATags(resp *http.Response) error {
	if !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/html") ||
		resp.Header.Get("Content-Encoding") != "" {
		return nil
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	if i := bytes.Index(body, []byte("</head>")); i >= 0 {
		injected := make([]byte, 0, len(body)+len(pwaHeadTags))
		injected = append(injected, body[:i]...)
		injected = append(injected, pwaHeadTags...)
		injected = append(injected, body[i:]...)
		body = injected
		// Only a changed body gets a new length — a HEAD response is text/html
		// with an empty body whose declared length must survive untouched.
		resp.ContentLength = int64(len(body))
		resp.Header.Set("Content-Length", strconv.Itoa(len(body)))
	}
	resp.Body = io.NopCloser(bytes.NewReader(body))
	return nil
}
