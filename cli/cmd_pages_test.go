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
