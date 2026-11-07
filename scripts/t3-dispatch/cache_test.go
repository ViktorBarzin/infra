package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestIsHashedAsset(t *testing.T) {
	cases := []struct {
		path string
		want bool
	}{
		{"/assets/react-dom-BEKrT875.js", true},
		{"/assets/x-CyvehhUj.js", true},
		{"/assets/ProviderSettingsPanel.logic-CK3WbIz7.js", true},
		{"/assets/LICENSE_LIBERATION-DvFkOp_c", false}, // no extension: not a build chunk
		{"/assets/pdfjs-6.4.299/build/pdf.mjs", false}, // versioned dir, file itself unhashed
		{"/assets/index.js", false},
		{"/assets/main-abc.js", false}, // hash too short
		{"/index.html", false},
		{"/", false},
		{"/api/assets/thing-ABCDEFGH.png", false}, // user uploads, not build output
	}
	for _, c := range cases {
		if got := isHashedAsset(c.path); got != c.want {
			t.Errorf("isHashedAsset(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

// assetInstance answers like t3 serve: no-cache on everything, 304 on a
// matching If-None-Match, 404 for unknown paths.
func assetInstance() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/assets/missing-ABCDEFGH.js" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("ETag", `W/"1"`)
		if r.Header.Get("If-None-Match") == `W/"1"` {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("Content-Type", "text/javascript")
		_, _ = w.Write([]byte("export {}"))
	}))
}

func fetchAsset(t *testing.T, ts *httptest.Server, path, inm string) *httptest.ResponseRecorder {
	t.Helper()
	setTable(portOf(t, ts))
	r := httptest.NewRequest("GET", path, nil)
	asOwner(r)
	r.Header.Set("Sec-Fetch-Dest", "script")
	if inm != "" {
		r.Header.Set("If-None-Match", inm)
	}
	r.AddCookie(&http.Cookie{Name: cookieName, Value: "good"})
	w := httptest.NewRecorder()
	handler(w, r)
	return w
}

func TestHandlerMarksHashedAssetsImmutable(t *testing.T) {
	ts := assetInstance()
	defer ts.Close()

	for _, inm := range []string{"", `W/"1"`} {
		w := fetchAsset(t, ts, "/assets/react-dom-BEKrT875.js", inm)
		if got := w.Header().Get("Cache-Control"); got != immutableCacheControl {
			t.Errorf("status %d: Cache-Control = %q, want %q", w.Code, got, immutableCacheControl)
		}
	}
}

func TestHandlerLeavesOtherCachingAlone(t *testing.T) {
	ts := assetInstance()
	defer ts.Close()

	for _, p := range []string{"/assets/missing-ABCDEFGH.js", "/assets/pdfjs-6.4.299/build/pdf.mjs", "/favicon.ico"} {
		w := fetchAsset(t, ts, p, "")
		if got := w.Header().Get("Cache-Control"); got == immutableCacheControl {
			t.Errorf("%s (status %d) marked immutable", p, w.Code)
		}
	}
}
