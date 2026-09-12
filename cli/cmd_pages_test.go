package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// newPagesTestServer points the pages client at an httptest server for the
// duration of one test (the client resolves base URL + key from env).
func newPagesTestServer(t *testing.T, handler http.Handler) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	t.Setenv("PAGES_API_URL", srv.URL)
	t.Setenv("PAGES_API_KEY", "test-key")
	return srv
}

// writeTempMD writes content to <tmpdir>/<name> and returns the absolute path.
func writeTempMD(t *testing.T, name, content string) string {
	t.Helper()
	fp := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(fp, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return fp
}

// captureStdout swaps os.Stdout for a pipe while fn runs and returns what it
// printed (the publish verb writes the url/path to stdout via fmt.Println).
// Tests run sequentially (no t.Parallel here), so the global swap is safe.
func captureStdout(t *testing.T, fn func() error) (string, error) {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	outC := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(r)
		outC <- string(b)
	}()
	runErr := fn()
	w.Close()
	os.Stdout = old
	return <-outC, runErr
}

func TestPagesPublishSendsBodyAndPrintsURL(t *testing.T) {
	// (a) `pages publish <tmpfile>` sends the right JSON body (content /
	// filename=basename / status=draft default / shared=false default) with the
	// Bearer header, and prints the server's returned url then path (two lines).
	var gotPath, gotAuth, gotMethod, gotCT, gotBody string
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotPath, gotAuth, gotMethod = r.URL.Path, r.Header.Get("Authorization"), r.Method
		gotCT, gotBody = r.Header.Get("Content-Type"), string(b)
		w.Write([]byte(`{"url":"https://pages.viktorbarzin.me/my-plan.html","path":"my-plan.html"}`))
	}))
	// Nested path proves the filename is the basename, not the whole path.
	fp := writeTempMD(t, "my-plan.md", "# Title\n\nbody")

	out, err := captureStdout(t, func() error { return pagesPublish([]string{fp}) })
	if err != nil {
		t.Fatalf("pagesPublish: %v", err)
	}
	if gotMethod != "POST" || gotPath != "/publish" {
		t.Fatalf("want POST /publish, got %s %s", gotMethod, gotPath)
	}
	if gotAuth != "Bearer test-key" {
		t.Fatalf("auth header = %q, want Bearer test-key", gotAuth)
	}
	if gotCT != "application/json" {
		t.Fatalf("content-type = %q, want application/json", gotCT)
	}
	var body pagesPublishReq
	if err := json.Unmarshal([]byte(gotBody), &body); err != nil {
		t.Fatalf("request body is not valid JSON: %q", gotBody)
	}
	if body.Content != "# Title\n\nbody" {
		t.Errorf("content = %q, want the file text verbatim", body.Content)
	}
	if body.Filename != "my-plan.md" {
		t.Errorf("filename = %q, want basename my-plan.md", body.Filename)
	}
	if body.Status != "draft" {
		t.Errorf("status = %q, want default draft", body.Status)
	}
	if body.Shared {
		t.Errorf("shared = true, want default false")
	}
	// url on line one, path on line two.
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) != 2 || lines[0] != "https://pages.viktorbarzin.me/my-plan.html" || lines[1] != "my-plan.html" {
		t.Fatalf("want url then path on two lines, got %q", out)
	}
}

func TestPagesPublishSharedFlag(t *testing.T) {
	// (b) --shared sets shared=true in the body.
	var gotBody string
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.Write([]byte(`{"url":"u","path":"p"}`))
	}))
	fp := writeTempMD(t, "doc.md", "x")
	if _, err := captureStdout(t, func() error { return pagesPublish([]string{fp, "--shared"}) }); err != nil {
		t.Fatalf("pagesPublish --shared: %v", err)
	}
	var body pagesPublishReq
	if err := json.Unmarshal([]byte(gotBody), &body); err != nil {
		t.Fatalf("body not JSON: %q", gotBody)
	}
	if !body.Shared {
		t.Fatalf("--shared must set shared=true: %s", gotBody)
	}
}

func TestPagesPublishStatusFlag(t *testing.T) {
	// (c) --status approved overrides the draft default.
	var gotBody string
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.Write([]byte(`{"url":"u"}`))
	}))
	fp := writeTempMD(t, "doc.md", "x")
	if _, err := captureStdout(t, func() error { return pagesPublish([]string{fp, "--status", "approved"}) }); err != nil {
		t.Fatalf("pagesPublish --status: %v", err)
	}
	var body pagesPublishReq
	if err := json.Unmarshal([]byte(gotBody), &body); err != nil {
		t.Fatalf("body not JSON: %q", gotBody)
	}
	if body.Status != "approved" {
		t.Fatalf("--status approved must set status=approved: %s", gotBody)
	}
}

func TestPagesPublishRequiresAPIKey(t *testing.T) {
	// (d) no PAGES_API_KEY → clear error, and no network call is attempted.
	hit := false
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = true
	}))
	t.Setenv("PAGES_API_KEY", "") // firstEnv treats "" as unset
	fp := writeTempMD(t, "doc.md", "content")
	err := pagesPublish([]string{fp})
	if err == nil || !strings.Contains(err.Error(), "no pages API key") {
		t.Fatalf("missing key must error with 'no pages API key', got %v", err)
	}
	if hit {
		t.Fatalf("must not reach the API with no key")
	}
}

func TestPagesPublishMissingFile(t *testing.T) {
	hit := false
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = true
	}))
	err := pagesPublish([]string{"/no/such/file.md"})
	if err == nil || !strings.Contains(err.Error(), "/no/such/file.md") {
		t.Fatalf("missing file must error clearly with the path, got %v", err)
	}
	if hit {
		t.Fatalf("must not reach the API when the file cannot be read")
	}
}

func TestPagesPublishRequiresPath(t *testing.T) {
	hit := false
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = true
	}))
	err := pagesPublish([]string{"--shared"})
	if err == nil || !strings.Contains(err.Error(), "usage:") {
		t.Fatalf("no path must print usage, got %v", err)
	}
	if hit {
		t.Fatalf("must not reach the API without a path")
	}
}

func TestPagesPublishSurfacesAPIError(t *testing.T) {
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"detail":"boom"}`, http.StatusInternalServerError)
	}))
	fp := writeTempMD(t, "doc.md", "x")
	err := pagesPublish([]string{fp})
	if err == nil || !strings.Contains(err.Error(), "500") || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("non-2xx must surface status + body, got %v", err)
	}
}

func TestPagesCommandsRegistered(t *testing.T) {
	var found *Command
	for i, c := range pagesCommands() {
		if strings.Join(c.Path, " ") == "pages publish" {
			found = &pagesCommands()[i]
		}
	}
	if found == nil {
		t.Fatalf("pages publish not registered")
	}
	if found.Tier != TierWrite {
		t.Errorf("pages publish tier = %q, want write", found.Tier)
	}
}

func TestResolvePagesBase(t *testing.T) {
	t.Setenv("PAGES_API_URL", "")
	if got := resolvePagesBase(); got != defaultPagesURL {
		t.Errorf("resolvePagesBase() = %q, want default %q", got, defaultPagesURL)
	}
	t.Setenv("PAGES_API_URL", "https://p.example/") // trailing slash trimmed
	if got := resolvePagesBase(); got != "https://p.example" {
		t.Errorf("resolvePagesBase() = %q, want https://p.example", got)
	}
}

func TestPagesPreviewWritesPageAndAssets(t *testing.T) {
	// The whole point of preview is that the caller ends up with files it can
	// open: the page at the top of the dir, the assets under assets/ where the
	// page's absolute /assets/... links expect them.
	var gotPath, gotMethod, gotBody string
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotPath, gotMethod, gotBody = r.URL.Path, r.Method, string(b)
		w.Write([]byte(`{"filename":"2026-01-01-x.html","html":"<h1>x</h1>","assets":{"assets/page.css":"body{}"}}`))
	}))
	fp := writeTempMD(t, "2026-01-01-x.md", "# X\n")
	dir := t.TempDir()

	out, err := captureStdout(t, func() error {
		return pagesPreview([]string{fp, "--status", "done", "--out", dir})
	})
	if err != nil {
		t.Fatalf("pagesPreview: %v", err)
	}
	if gotMethod != "POST" || gotPath != "/preview" {
		t.Fatalf("want POST /preview, got %s %s", gotMethod, gotPath)
	}
	var body pagesPreviewReq
	if err := json.Unmarshal([]byte(gotBody), &body); err != nil {
		t.Fatalf("request body is not valid JSON: %q", gotBody)
	}
	if body.Filename != "2026-01-01-x.md" || body.Status != "done" {
		t.Errorf("body = %+v, want the basename and status done", body)
	}

	page := filepath.Join(dir, "2026-01-01-x.html")
	if b, err := os.ReadFile(page); err != nil || string(b) != "<h1>x</h1>" {
		t.Fatalf("page file = %q / %v, want the rendered html", b, err)
	}
	if b, err := os.ReadFile(filepath.Join(dir, "assets", "page.css")); err != nil || string(b) != "body{}" {
		t.Fatalf("asset file = %q / %v, want the stylesheet", b, err)
	}
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) != 2 || lines[0] != page || lines[1] != dir {
		t.Fatalf("want page path then dir on two lines, got %q", out)
	}
}

func TestPagesPreviewDefaultsToATempDirNamedForThePage(t *testing.T) {
	// No --out: a stable path per page, so re-previewing the same doc replaces
	// the previous render instead of leaving a trail of directories.
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte(`{"filename":"2026-01-01-y.html","html":"<h1>y</h1>","assets":{}}`))
	}))
	fp := writeTempMD(t, "2026-01-01-y.md", "# Y\n")

	out, err := captureStdout(t, func() error { return pagesPreview([]string{fp}) })
	if err != nil {
		t.Fatalf("pagesPreview: %v", err)
	}
	want := filepath.Join(os.TempDir(), "homelab-pages-preview", "2026-01-01-y")
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) != 2 || lines[1] != want {
		t.Fatalf("dir = %q, want %q", out, want)
	}
	t.Cleanup(func() { os.RemoveAll(want) })
	if _, err := os.Stat(filepath.Join(want, "2026-01-01-y.html")); err != nil {
		t.Fatalf("page not written to the default dir: %v", err)
	}
}

func TestPagesPreviewRefusesAnAssetPathOutsideTheDir(t *testing.T) {
	// The server is ours, so this is belt and braces — but a path-traversing
	// asset key is the one thing a compromised or buggy server could use to
	// write through this client, so it must not depend on the server's charset.
	newPagesTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte(`{"filename":"x.html","html":"<h1>x</h1>","assets":{"../../pwned":"x"}}`))
	}))
	fp := writeTempMD(t, "x.md", "# X\n")
	dir := t.TempDir()

	_, err := captureStdout(t, func() error { return pagesPreview([]string{fp, "--out", dir}) })
	if err == nil {
		t.Fatal("want an error for an asset path escaping the output dir")
	}
	if !strings.Contains(err.Error(), "refusing asset path") {
		t.Fatalf("error = %v, want it to name the refused path", err)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 0 {
		t.Fatalf("output dir is not empty after a refused asset: %v", entries)
	}
}

func TestPagesPreviewNeedsASourcePath(t *testing.T) {
	if err := pagesPreview(nil); err == nil || !strings.Contains(err.Error(), "usage:") {
		t.Fatalf("err = %v, want a usage error", err)
	}
}
