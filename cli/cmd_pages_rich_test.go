package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// recordServer answers every POST with reply and keeps the last path + body.
func recordServer(t *testing.T, reply string) (*string, *map[string]any) {
	t.Helper()
	var gotPath string
	got := map[string]any{}
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		b, _ := io.ReadAll(r.Body)
		got = map[string]any{}
		_ = json.Unmarshal(b, &got)
		w.Write([]byte(reply))
	}))
	return &gotPath, &got
}

func TestPagesPublishHTMLFileSendsAOneFileBundle(t *testing.T) {
	p, body := recordServer(t, `{"url":"https://pages.viktorbarzin.me/2026-11-12-viewer.html","path":"wizard/2026-11-12-viewer.html"}`)
	fp := writeTempMD(t, "viewer.html", "<title>V</title>")
	out, err := captureStdout(t, func() error { return pagesPublish([]string{fp, "--status", "done"}) })
	if err != nil {
		t.Fatal(err)
	}
	if *p != "/publish-bundle" {
		t.Fatalf("path = %q", *p)
	}
	b := *body
	if b["name"] != "viewer.html" || b["status"] != "done" || b["public"] != false {
		t.Fatalf("body = %v", b)
	}
	files := b["files"].([]any)
	if len(files) != 1 || files[0].(map[string]any)["path"] != "viewer.html" {
		t.Fatalf("files = %v", files)
	}
	if !strings.HasPrefix(out, "https://pages.viktorbarzin.me/2026-11-12-viewer.html\n") {
		t.Fatalf("out = %q", out)
	}
}

func TestPagesPublishDirSendsEveryFileAndSkipsDotfiles(t *testing.T) {
	p, body := recordServer(t, `{"url":"u","path":"wizard/2026-11-12-demo","public_url":"https://pages.viktorbarzin.me/p/abc/"}`)
	dir := filepath.Join(t.TempDir(), "demo")
	for name, data := range map[string]string{
		"index.md":        "# Demo",
		"img/a.png":       "\x89PNG",
		".DS_Store":       "junk",
		".git/config":     "nope",
		"img/.hidden.png": "nope",
	} {
		fp := filepath.Join(dir, name)
		os.MkdirAll(filepath.Dir(fp), 0o755)
		os.WriteFile(fp, []byte(data), 0o644)
	}
	out, err := captureStdout(t, func() error { return pagesPublish([]string{dir + "/", "--public", "--shared"}) })
	if err != nil {
		t.Fatal(err)
	}
	if *p != "/publish-bundle" {
		t.Fatalf("path = %q", *p)
	}
	b := *body
	if b["name"] != "demo" || b["public"] != true || b["shared"] != true {
		t.Fatalf("body = %v", b)
	}
	var paths []string
	for _, f := range b["files"].([]any) {
		m := f.(map[string]any)
		paths = append(paths, m["path"].(string))
		if m["path"] == "img/a.png" {
			raw, _ := base64.StdEncoding.DecodeString(m["content"].(string))
			if m["encoding"] != "base64" || string(raw) != "\x89PNG" {
				t.Fatalf("binary file not base64: %v", m)
			}
		}
	}
	sort.Strings(paths)
	if strings.Join(paths, ",") != "img/a.png,index.md" {
		t.Fatalf("paths = %v", paths)
	}
	if !strings.Contains(out, "https://pages.viktorbarzin.me/p/abc/") {
		t.Fatalf("public url not printed: %q", out)
	}
}

func TestPagesPublishMarkdownPublicFlag(t *testing.T) {
	p, body := recordServer(t, `{"url":"u","path":"wizard/x.html","public_url":"https://pages.viktorbarzin.me/p/t/"}`)
	fp := writeTempMD(t, "x.md", "# X")
	out, err := captureStdout(t, func() error { return pagesPublish([]string{fp, "--public"}) })
	if err != nil {
		t.Fatal(err)
	}
	if *p != "/publish" || (*body)["public"] != true {
		t.Fatalf("path %q body %v", *p, *body)
	}
	if !strings.Contains(out, "public: https://pages.viktorbarzin.me/p/t/") {
		t.Fatalf("out = %q", out)
	}
}

func TestPagesPublishDirOverTheLimitFailsLocally(t *testing.T) {
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("must not call the API")
	}))
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "index.html"), []byte("x"), 0o644)
	big := make([]byte, pagesMaxFileBytes+1)
	os.WriteFile(filepath.Join(dir, "clip.mp4"), big, 0o644)
	err := pagesPublish([]string{dir})
	if err == nil || !strings.Contains(err.Error(), "clip.mp4") {
		t.Fatalf("err = %v", err)
	}
}

func TestPagesShareAndUnshare(t *testing.T) {
	p, body := recordServer(t, `{"url":"https://pages.viktorbarzin.me/p/tok/","page":"wizard/x.html"}`)
	out, err := captureStdout(t, func() error { return pagesShare([]string{"https://pages.viktorbarzin.me/x.html"}) })
	if err != nil {
		t.Fatal(err)
	}
	if *p != "/share" || (*body)["page"] != "https://pages.viktorbarzin.me/x.html" {
		t.Fatalf("path %q body %v", *p, *body)
	}
	if strings.TrimSpace(out) != "https://pages.viktorbarzin.me/p/tok/" {
		t.Fatalf("out = %q", out)
	}

	p, body = recordServer(t, `{"removed":1,"page":"wizard/x.html"}`)
	out, err = captureStdout(t, func() error { return pagesUnshare([]string{"x.html", "--shared"}) })
	if err != nil {
		t.Fatal(err)
	}
	if *p != "/unshare" || (*body)["shared"] != true {
		t.Fatalf("path %q body %v", *p, *body)
	}
	if !strings.Contains(out, "removed 1 public link") {
		t.Fatalf("out = %q", out)
	}
}

func TestPagesShareNeedsAPage(t *testing.T) {
	t.Setenv("PAGES_API_KEY", "k")
	if err := pagesShare(nil); err == nil {
		t.Fatal("want usage error")
	}
}

func TestPagesShareVerbsRegistered(t *testing.T) {
	want := map[string]Tier{"pages share": TierWrite, "pages unshare": TierWrite}
	for _, c := range pagesCommands() {
		if tier, ok := want[strings.Join(c.Path, " ")]; ok {
			if c.Tier != tier {
				t.Errorf("%v tier = %q", c.Path, c.Tier)
			}
			delete(want, strings.Join(c.Path, " "))
		}
	}
	if len(want) != 0 {
		t.Fatalf("not registered: %v", want)
	}
}

func TestPagesPublishExpiresFlagAndPrintsExpiryAndWarnings(t *testing.T) {
	p, body := recordServer(t, `{"url":"u","path":"wizard/x.html","expires":"2027-02-10","warnings":["700 prose words outside the blocks; the plan budget is 600."]}`)
	fp := writeTempMD(t, "x.md", "# X")
	var out string
	errOut := captureStderr(t, func() {
		var err error
		out, err = captureStdout(t, func() error { return pagesPublish([]string{fp, "--expires", "30d"}) })
		if err != nil {
			t.Fatal(err)
		}
	})
	if *p != "/publish" || (*body)["expires"] != "30d" {
		t.Fatalf("path %q body %v", *p, *body)
	}
	if !strings.Contains(out, "expires: 2027-02-10") {
		t.Fatalf("out = %q", out)
	}
	if !strings.Contains(errOut, "warning: 700 prose words") {
		t.Fatalf("stderr = %q", errOut)
	}
}

func TestPagesPublishExpiresNeverOnADir(t *testing.T) {
	_, body := recordServer(t, `{"url":"u","path":"wizard/d","expires":null}`)
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "index.html"), []byte("x"), 0o644)
	if _, err := captureStdout(t, func() error { return pagesPublish([]string{dir, "--expires", "never"}) }); err != nil {
		t.Fatal(err)
	}
	if (*body)["expires"] != "never" {
		t.Fatalf("body = %v", *body)
	}
}

func TestPagesPublishWithoutExpiresSendsNone(t *testing.T) {
	_, body := recordServer(t, `{"url":"u","path":"p"}`)
	fp := writeTempMD(t, "y.md", "# Y")
	if _, err := captureStdout(t, func() error { return pagesPublish([]string{fp}) }); err != nil {
		t.Fatal(err)
	}
	if _, ok := (*body)["expires"]; ok {
		t.Fatalf("expires must be left out so the server applies its rule: %v", *body)
	}
}

func TestPagesUnpublish(t *testing.T) {
	p, body := recordServer(t, `{"removed":"wizard/2026-11-12-x.html","links":1}`)
	out, err := captureStdout(t, func() error { return pagesUnpublish([]string{"https://pages.viktorbarzin.me/2026-11-12-x.html"}) })
	if err != nil {
		t.Fatal(err)
	}
	if *p != "/unpublish" || (*body)["page"] != "https://pages.viktorbarzin.me/2026-11-12-x.html" {
		t.Fatalf("path %q body %v", *p, *body)
	}
	if !strings.Contains(out, "removed wizard/2026-11-12-x.html and 1 public link") {
		t.Fatalf("out = %q", out)
	}
}

func TestPagesShareExpires(t *testing.T) {
	_, body := recordServer(t, `{"url":"https://pages.viktorbarzin.me/p/t/","expires":"2026-12-12"}`)
	out, err := captureStdout(t, func() error { return pagesShare([]string{"x.html", "--expires", "30d"}) })
	if err != nil {
		t.Fatal(err)
	}
	if (*body)["expires"] != "30d" || !strings.Contains(out, "expires: 2026-12-12") {
		t.Fatalf("body %v out %q", *body, out)
	}
}

func TestPagesUnpublishRegistered(t *testing.T) {
	for _, c := range pagesCommands() {
		if strings.Join(c.Path, " ") == "pages unpublish" && c.Tier == TierWrite {
			return
		}
	}
	t.Fatal("pages unpublish not registered as write")
}

// captureStderr swaps os.Stderr while fn runs and returns what it printed.
func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = w
	outC := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(r)
		outC <- string(b)
	}()
	fn()
	w.Close()
	os.Stderr = old
	return <-outC
}
