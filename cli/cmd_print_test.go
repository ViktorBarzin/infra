package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// fakeBambuddy is an in-memory stand-in for the Bambuddy API endpoints that
// `homelab print` uses. It records every request as "METHOD path?query".
type fakeBambuddy struct {
	mu       sync.Mutex
	calls    []string
	projects []map[string]any
	folders  []map[string]any
	files    []map[string]any
	uploads  map[string]string // filename -> content
	covers   map[int]string
	nextID   int
	key      string
}

func newFakeBambuddy(t *testing.T) (*fakeBambuddy, *httptest.Server) {
	t.Helper()
	f := &fakeBambuddy{uploads: map[string]string{}, covers: map[int]string{}, nextID: 100, key: "test-key"}
	srv := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(srv.Close)
	t.Setenv("BAMBUDDY_URL", srv.URL)
	t.Setenv("BAMBUDDY_API_KEY", "test-key")
	return f, srv
}

func (f *fakeBambuddy) id() int { f.nextID++; return f.nextID }

func (f *fakeBambuddy) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	call := r.Method + " " + r.URL.Path
	if r.URL.RawQuery != "" {
		call += "?" + r.URL.RawQuery
	}
	f.calls = append(f.calls, call)
	if r.Header.Get("X-API-Key") != f.key {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	writeJSON := func(v any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(v)
	}
	p := r.URL.Path
	switch {
	case r.Method == "GET" && p == "/api/v1/projects/":
		writeJSON(f.projects)
	case r.Method == "POST" && p == "/api/v1/projects/":
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		body["id"] = f.id()
		f.projects = append(f.projects, body)
		writeJSON(body)
	case r.Method == "PATCH" && strings.HasPrefix(p, "/api/v1/projects/"):
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		id := strings.TrimSuffix(strings.TrimPrefix(p, "/api/v1/projects/"), "/")
		for _, pr := range f.projects {
			if anyID(pr["id"]) == id {
				for k, v := range body {
					pr[k] = v
				}
				writeJSON(pr)
				return
			}
		}
		w.WriteHeader(http.StatusNotFound)
	case r.Method == "POST" && strings.HasSuffix(p, "/cover-image"):
		_ = r.ParseMultipartForm(1 << 20)
		file, hdr, _ := r.FormFile("file")
		b, _ := io.ReadAll(file)
		var pid int
		for _, pr := range f.projects {
			if strings.Contains(p, "/"+anyID(pr["id"])+"/") {
				pid = int(pr["id"].(int))
			}
		}
		f.covers[pid] = hdr.Filename + ":" + string(b)
		writeJSON(map[string]any{"ok": true})
	case r.Method == "GET" && p == "/api/v1/library/folders/":
		writeJSON(f.folders)
	case r.Method == "POST" && p == "/api/v1/library/folders/":
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		body["id"] = f.id()
		f.folders = append(f.folders, body)
		writeJSON(body)
	case r.Method == "GET" && p == "/api/v1/library/files/":
		fid := r.URL.Query().Get("folder_id")
		out := []map[string]any{}
		for _, fl := range f.files {
			if anyID(fl["folder_id"]) == fid {
				out = append(out, fl)
			}
		}
		writeJSON(out)
	case r.Method == "POST" && p == "/api/v1/library/files/":
		_ = r.ParseMultipartForm(1 << 20)
		file, hdr, err := r.FormFile("file")
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		b, _ := io.ReadAll(file)
		f.uploads[hdr.Filename] = string(b)
		fid := r.URL.Query().Get("folder_id")
		rec := map[string]any{"id": f.id(), "filename": hdr.Filename, "folder_id": atoiOr(fid)}
		f.files = append(f.files, rec)
		writeJSON(rec)
	case r.Method == "DELETE" && strings.HasPrefix(p, "/api/v1/library/files/"):
		id := strings.TrimPrefix(p, "/api/v1/library/files/")
		kept := f.files[:0]
		for _, fl := range f.files {
			if anyID(fl["id"]) != id {
				kept = append(kept, fl)
			}
		}
		f.files = kept
		writeJSON(map[string]any{"ok": true})
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func anyID(v any) string {
	switch n := v.(type) {
	case int:
		return intToString(n)
	case float64:
		return intToString(int(n))
	}
	return ""
}

func intToString(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

func atoiOr(s string) int {
	var n int
	_ = json.Unmarshal([]byte(s), &n)
	return n
}

func writeFile(t *testing.T, dir, name, content string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestPrintPublishCreatesProjectFolderAndUploads(t *testing.T) {
	f, srv := newFakeBambuddy(t)
	dir := t.TempDir()
	stl := writeFile(t, dir, "bracket.stl", "solid bracket")
	readme := writeFile(t, dir, "README.md", "# Bracket\nnotes")

	out, err := captureStdout(t, func() error {
		return printPublish([]string{"--project", "Shelf bracket", "--description", "Holds the shelf", stl, readme})
	})
	if err != nil {
		t.Fatalf("publish: %v", err)
	}
	if len(f.projects) != 1 || f.projects[0]["name"] != "Shelf bracket" || f.projects[0]["description"] != "Holds the shelf" {
		t.Fatalf("project not created as asked: %+v", f.projects)
	}
	pid := f.projects[0]["id"].(int)
	if len(f.folders) != 1 || f.folders[0]["name"] != "Shelf bracket" || int(f.folders[0]["project_id"].(float64)) != pid {
		t.Fatalf("folder not created and linked to the project: %+v", f.folders)
	}
	if f.uploads["bracket.stl"] != "solid bracket" || f.uploads["README.md"] != "# Bracket\nnotes" {
		t.Fatalf("uploads wrong: %+v", f.uploads)
	}
	want := srv.URL + "/projects/" + intToString(pid)
	if !strings.Contains(out, want) {
		t.Fatalf("output %q does not name the project page %s", out, want)
	}
}

func TestPrintPublishReusesProjectAndReplacesSameName(t *testing.T) {
	f, _ := newFakeBambuddy(t)
	f.projects = []map[string]any{{"id": 7, "name": "Shelf bracket"}}
	f.folders = []map[string]any{{"id": 8, "name": "Shelf bracket", "parent_id": nil, "project_id": 7}}
	f.files = []map[string]any{{"id": 9, "filename": "bracket.stl", "folder_id": 8}, {"id": 10, "filename": "old.stl", "folder_id": 8}}
	dir := t.TempDir()
	stl := writeFile(t, dir, "bracket.stl", "solid v2")

	if _, err := captureStdout(t, func() error { return printPublish([]string{"--project", "Shelf bracket", stl}) }); err != nil {
		t.Fatalf("publish: %v", err)
	}
	for _, c := range f.calls {
		if strings.HasPrefix(c, "POST /api/v1/projects/") || strings.HasPrefix(c, "POST /api/v1/library/folders/") {
			t.Fatalf("created a duplicate: %s", c)
		}
	}
	joined := strings.Join(f.calls, "\n")
	if !strings.Contains(joined, "DELETE /api/v1/library/files/9") {
		t.Fatalf("old revision with the same name was not replaced:\n%s", joined)
	}
	if strings.Contains(joined, "DELETE /api/v1/library/files/10") {
		t.Fatalf("deleted a file it was not given:\n%s", joined)
	}
	if f.uploads["bracket.stl"] != "solid v2" {
		t.Fatalf("new revision not uploaded: %+v", f.uploads)
	}
}

func TestPrintPublishDirectoryAndCover(t *testing.T) {
	f, _ := newFakeBambuddy(t)
	dir := t.TempDir()
	writeFile(t, dir, "a.stl", "A")
	writeFile(t, dir, "b.3mf", "B")
	writeFile(t, dir, ".hidden", "H")
	if err := os.Mkdir(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	cover := writeFile(t, t.TempDir(), "render.png", "PNG")

	if _, err := captureStdout(t, func() error {
		return printPublish([]string{"--project", "Box", "--cover", cover, dir})
	}); err != nil {
		t.Fatalf("publish: %v", err)
	}
	if len(f.uploads) != 2 || f.uploads["a.stl"] != "A" || f.uploads["b.3mf"] != "B" {
		t.Fatalf("directory should upload its visible top-level files only: %+v", f.uploads)
	}
	pid := f.projects[0]["id"].(int)
	if f.covers[pid] != "render.png:PNG" {
		t.Fatalf("cover not set: %+v", f.covers)
	}
}

func TestPrintPublishNeedsProjectAndFiles(t *testing.T) {
	newFakeBambuddy(t)
	if err := printPublish([]string{"x.stl"}); err == nil || !strings.Contains(err.Error(), "--project") {
		t.Fatalf("want a --project error, got %v", err)
	}
	if err := printPublish([]string{"--project", "P"}); err == nil {
		t.Fatal("want an error with no files")
	}
}

func TestPrintKeyFallsBackToVault(t *testing.T) {
	_, srv := newFakeBambuddy(t)
	t.Setenv("BAMBUDDY_API_KEY", "")
	old := printVaultRunner
	t.Cleanup(func() { printVaultRunner = old })
	var asked string
	printVaultRunner = func(name string, argv, envv []string) (string, error) {
		asked = name + " " + strings.Join(argv, " ")
		return "test-key", nil
	}
	if _, err := captureStdout(t, func() error { return printProjects(nil) }); err != nil {
		t.Fatalf("projects with the Vault key: %v", err)
	}
	if asked != "vault kv get -field=api_key secret/bambuddy-agent" {
		t.Fatalf("asked Vault for %q", asked)
	}
	_ = srv
}

func TestPrintProjectsListsWithURLs(t *testing.T) {
	f, srv := newFakeBambuddy(t)
	f.projects = []map[string]any{{"id": 3, "name": "Fan adapter"}, {"id": 4, "name": "ESP32 case"}}
	out, err := captureStdout(t, func() error { return printProjects(nil) })
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Fan adapter", srv.URL + "/projects/3", "ESP32 case", srv.URL + "/projects/4"} {
		if !strings.Contains(out, want) {
			t.Fatalf("output %q is missing %q", out, want)
		}
	}
}

func TestPrintPublishREADMEBecomesProjectNotes(t *testing.T) {
	f, _ := newFakeBambuddy(t)
	f.projects = []map[string]any{{"id": 7, "name": "Box", "notes": "old"}}
	f.folders = []map[string]any{{"id": 8, "name": "Box", "parent_id": nil, "project_id": 7}}
	dir := t.TempDir()
	writeFile(t, dir, "README.md", "# Box\n\n| file | what |\n|---|---|\n| `a.stl` | body |\n\n<script>x</script>\n")
	writeFile(t, dir, "a.stl", "A")

	if _, err := captureStdout(t, func() error { return printPublish([]string{"--project", "Box", dir}) }); err != nil {
		t.Fatalf("publish: %v", err)
	}
	notes, _ := f.projects[0]["notes"].(string)
	for _, want := range []string{"<h1", "Box</h1>", "<table>", "<code>a.stl</code>"} {
		if !strings.Contains(notes, want) {
			t.Fatalf("notes should be the README as HTML, missing %q in %q", want, notes)
		}
	}
	if strings.Contains(notes, "<script>") {
		t.Fatalf("raw HTML from the README must not pass through: %q", notes)
	}
}

func TestPrintPublishWithoutREADMEKeepsNotes(t *testing.T) {
	f, _ := newFakeBambuddy(t)
	f.projects = []map[string]any{{"id": 7, "name": "Box", "notes": "kept"}}
	f.folders = []map[string]any{{"id": 8, "name": "Box", "parent_id": nil, "project_id": 7}}
	stl := writeFile(t, t.TempDir(), "a.stl", "A")
	if _, err := captureStdout(t, func() error { return printPublish([]string{"--project", "Box", stl}) }); err != nil {
		t.Fatalf("publish: %v", err)
	}
	if f.projects[0]["notes"] != "kept" {
		t.Fatalf("notes changed without a README: %v", f.projects[0]["notes"])
	}
}
