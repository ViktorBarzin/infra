package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func writeBundleDir(t *testing.T, files map[string][]byte) string {
	t.Helper()
	dir := t.TempDir()
	for name, b := range files {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestBundleFiles(t *testing.T) {
	png := []byte{0x89, 'P', 'N', 'G', 0x00, 0xff}
	dir := writeBundleDir(t, map[string][]byte{
		"index.html":  []byte("<!doctype html>"),
		"data.json":   []byte(`{"a":1}`),
		"og.png":      png,
		"lib/map.js":  []byte("export {}"),
		".DS_Store":   []byte("junk"),
		"lib/.hidden": []byte("junk"),
	})
	got, err := bundleFiles(dir)
	if err != nil {
		t.Fatal(err)
	}
	want := []bundleFile{
		{Path: "data.json", Content: `{"a":1}`, Encoding: "utf-8"},
		{Path: "index.html", Content: "<!doctype html>", Encoding: "utf-8"},
		{Path: "lib/map.js", Content: "export {}", Encoding: "utf-8"},
		{Path: "og.png", Content: base64.StdEncoding.EncodeToString(png), Encoding: "base64"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("bundleFiles:\n got %+v\nwant %+v", got, want)
	}
}

func TestBundleFilesEmptyDirIsAnError(t *testing.T) {
	if _, err := bundleFiles(t.TempDir()); err == nil {
		t.Fatal("an empty bundle must not publish (it would wipe the live page)")
	}
}

func TestShowcasePublishPostsBundleWithBundleToken(t *testing.T) {
	var gotAuth, gotPath string
	var gotBody struct {
		Files []bundleFile `json:"files"`
	}
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotPath = r.Header.Get("Authorization"), r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		_, _ = w.Write([]byte(`{"url":"https://pages.example/homelab/","path":"pages/showcase/homelab","committed":true,"files":1}`))
	}))
	t.Setenv("PAGES_BUNDLE_TOKEN", "bundle-tok")
	dir := writeBundleDir(t, map[string][]byte{"index.html": []byte("hi")})

	out, err := captureStdout(t, func() error { return showcasePublish([]string{"--dir", dir}) })
	if err != nil {
		t.Fatal(err)
	}
	if gotPath != "/publish-bundle" || gotAuth != "Bearer bundle-tok" {
		t.Fatalf("posted to %q with %q; want /publish-bundle with the bundle token, not PAGES_API_KEY", gotPath, gotAuth)
	}
	if len(gotBody.Files) != 1 || gotBody.Files[0].Path != "index.html" {
		t.Fatalf("body files = %+v", gotBody.Files)
	}
	if out == "" {
		t.Fatal("publish should print the served URL")
	}
}

func TestShowcasePublishNeedsToken(t *testing.T) {
	t.Setenv("PAGES_BUNDLE_TOKEN", "")
	dir := writeBundleDir(t, map[string][]byte{"index.html": []byte("hi")})
	if err := showcasePublish([]string{"--dir", dir}); err == nil {
		t.Fatal("expected an error without PAGES_BUNDLE_TOKEN")
	}
}
