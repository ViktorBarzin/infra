package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testDrawing = `{"type":"excalidraw","version":2,"source":"excalidraw-library","elements":[{"id":"e1"}],"appState":{"viewBackgroundColor":"#ffffff"}}`

func setupDataDir(t *testing.T) {
	t.Helper()
	dataDir = t.TempDir()
}

// doDrawing sends a request to handleDrawing for the given user and returns the recorder.
func doDrawing(t *testing.T, method, id, body, user string) *httptest.ResponseRecorder {
	t.Helper()
	var reader *strings.Reader
	if body == "" {
		reader = strings.NewReader("")
	} else {
		reader = strings.NewReader(body)
	}
	req := httptest.NewRequest(method, "/api/drawings/"+id, reader)
	if user != "" {
		req.Header.Set("X-Authentik-Username", user)
	}
	w := httptest.NewRecorder()
	handleDrawing(w, req)
	return w
}

func listDrawings(t *testing.T, user string) []Drawing {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/drawings", nil)
	if user != "" {
		req.Header.Set("X-Authentik-Username", user)
	}
	w := httptest.NewRecorder()
	handleListDrawings(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("list: expected 200, got %d", w.Code)
	}
	var drawings []Drawing
	if err := json.Unmarshal(w.Body.Bytes(), &drawings); err != nil {
		t.Fatalf("list: bad JSON: %v", err)
	}
	return drawings
}

func TestPutGetRoundtrip(t *testing.T) {
	setupDataDir(t)
	if w := doDrawing(t, http.MethodPut, "foo", testDrawing, "alice"); w.Code != http.StatusOK {
		t.Fatalf("PUT: expected 200, got %d: %s", w.Code, w.Body.String())
	}
	w := doDrawing(t, http.MethodGet, "foo", "", "alice")
	if w.Code != http.StatusOK {
		t.Fatalf("GET: expected 200, got %d", w.Code)
	}
	if w.Body.String() != testDrawing {
		t.Errorf("GET: content mismatch: %s", w.Body.String())
	}
}

func TestGetMissing(t *testing.T) {
	setupDataDir(t)
	if w := doDrawing(t, http.MethodGet, "nope", "", "alice"); w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", w.Code)
	}
}

func TestListDrawings(t *testing.T) {
	setupDataDir(t)
	doDrawing(t, http.MethodPut, "one", testDrawing, "alice")
	doDrawing(t, http.MethodPut, "two", testDrawing, "alice")
	drawings := listDrawings(t, "alice")
	if len(drawings) != 2 {
		t.Fatalf("expected 2 drawings, got %d", len(drawings))
	}
	ids := map[string]bool{drawings[0].ID: true, drawings[1].ID: true}
	if !ids["one"] || !ids["two"] {
		t.Errorf("unexpected ids: %v", ids)
	}
	for _, d := range drawings {
		if d.Name != d.ID {
			t.Errorf("name should equal id: %+v", d)
		}
	}
}

func TestDelete(t *testing.T) {
	setupDataDir(t)
	doDrawing(t, http.MethodPut, "foo", testDrawing, "alice")
	if w := doDrawing(t, http.MethodDelete, "foo", "", "alice"); w.Code != http.StatusOK {
		t.Fatalf("DELETE: expected 200, got %d", w.Code)
	}
	if w := doDrawing(t, http.MethodGet, "foo", "", "alice"); w.Code != http.StatusNotFound {
		t.Fatalf("GET after delete: expected 404, got %d", w.Code)
	}
	if w := doDrawing(t, http.MethodDelete, "foo", "", "alice"); w.Code != http.StatusNotFound {
		t.Fatalf("second DELETE: expected 404, got %d", w.Code)
	}
}

func TestPerUserIsolation(t *testing.T) {
	setupDataDir(t)
	doDrawing(t, http.MethodPut, "secret", testDrawing, "alice")
	if w := doDrawing(t, http.MethodGet, "secret", "", "bob"); w.Code != http.StatusNotFound {
		t.Fatalf("bob should not see alice's drawing, got %d", w.Code)
	}
	if drawings := listDrawings(t, "bob"); len(drawings) != 0 {
		t.Fatalf("bob's list should be empty, got %d", len(drawings))
	}
}

// --- rename (PATCH) ---

func renameReq(t *testing.T, id, newName, user string) *httptest.ResponseRecorder {
	t.Helper()
	return doDrawing(t, http.MethodPatch, id, `{"name":`+strconv(newName)+`}`, user)
}

// strconv JSON-quotes a string without importing encoding/json for a one-liner.
func strconv(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func TestRenameSuccess(t *testing.T) {
	setupDataDir(t)
	doDrawing(t, http.MethodPut, "foo", testDrawing, "alice")
	w := renameReq(t, "foo", "bar", "alice")
	if w.Code != http.StatusOK {
		t.Fatalf("PATCH: expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("PATCH: bad JSON: %v", err)
	}
	if resp["id"] != "bar" || resp["status"] != "renamed" {
		t.Errorf("unexpected response: %v", resp)
	}
	if w := doDrawing(t, http.MethodGet, "bar", "", "alice"); w.Code != http.StatusOK || w.Body.String() != testDrawing {
		t.Errorf("GET new id: code=%d content=%q", w.Code, w.Body.String())
	}
	if w := doDrawing(t, http.MethodGet, "foo", "", "alice"); w.Code != http.StatusNotFound {
		t.Errorf("GET old id: expected 404, got %d", w.Code)
	}
}

func TestRenameConflict(t *testing.T) {
	setupDataDir(t)
	doDrawing(t, http.MethodPut, "a", testDrawing, "alice")
	doDrawing(t, http.MethodPut, "b", testDrawing, "alice")
	if w := renameReq(t, "a", "b", "alice"); w.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d", w.Code)
	}
	// both drawings intact
	for _, id := range []string{"a", "b"} {
		if w := doDrawing(t, http.MethodGet, id, "", "alice"); w.Code != http.StatusOK {
			t.Errorf("drawing %q should be intact, got %d", id, w.Code)
		}
	}
}

func TestRenameMissing(t *testing.T) {
	setupDataDir(t)
	if w := renameReq(t, "nope", "new", "alice"); w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", w.Code)
	}
}

func TestRenameSameName(t *testing.T) {
	setupDataDir(t)
	doDrawing(t, http.MethodPut, "foo", testDrawing, "alice")
	w := renameReq(t, "foo", "foo", "alice")
	if w.Code != http.StatusOK {
		t.Fatalf("same-name rename: expected 200, got %d: %s", w.Code, w.Body.String())
	}
	if w := doDrawing(t, http.MethodGet, "foo", "", "alice"); w.Code != http.StatusOK {
		t.Errorf("drawing should be intact, got %d", w.Code)
	}
}

func TestRenameInvalidNames(t *testing.T) {
	setupDataDir(t)
	doDrawing(t, http.MethodPut, "foo", testDrawing, "alice")
	for _, name := range []string{"", "   ", "../..", "---"} {
		if w := renameReq(t, "foo", name, "alice"); w.Code != http.StatusBadRequest {
			t.Errorf("rename to %q: expected 400, got %d", name, w.Code)
		}
	}
	// malformed body
	if w := doDrawing(t, http.MethodPatch, "foo", `{not json`, "alice"); w.Code != http.StatusBadRequest {
		t.Errorf("malformed body: expected 400, got %d", w.Code)
	}
}

func TestRenameSanitization(t *testing.T) {
	setupDataDir(t)
	cases := []struct{ in, want string }{
		{"My Drawing!", "My-Drawing-"},
		{"net diag.excalidraw", "net-diag"}, // .excalidraw suffix stripped, not mangled
		{"a/b\\c", "a-b-c"},
	}
	for _, c := range cases {
		doDrawing(t, http.MethodPut, "src", testDrawing, "alice")
		w := renameReq(t, "src", c.in, "alice")
		if w.Code != http.StatusOK {
			t.Errorf("rename to %q: expected 200, got %d: %s", c.in, w.Code, w.Body.String())
			continue
		}
		var resp map[string]string
		json.Unmarshal(w.Body.Bytes(), &resp)
		if resp["id"] != c.want {
			t.Errorf("rename to %q: expected id %q, got %q", c.in, c.want, resp["id"])
		}
		// file must be inside the user dir under the sanitized name
		if _, err := os.Stat(filepath.Join(dataDir, "alice", c.want+".excalidraw")); err != nil {
			t.Errorf("rename to %q: expected file %q on disk: %v", c.in, c.want, err)
		}
		doDrawing(t, http.MethodDelete, resp["id"], "", "alice")
	}
}

func TestRenameTraversalStaysInUserDir(t *testing.T) {
	setupDataDir(t)
	doDrawing(t, http.MethodPut, "foo", testDrawing, "alice")
	w := renameReq(t, "foo", "../../../etc/passwd", "alice")
	if w.Code == http.StatusOK {
		var resp map[string]string
		json.Unmarshal(w.Body.Bytes(), &resp)
		if strings.Contains(resp["id"], "/") || strings.Contains(resp["id"], "..") {
			t.Fatalf("traversal characters survived: %q", resp["id"])
		}
		if _, err := os.Stat(filepath.Join(dataDir, "alice", resp["id"]+".excalidraw")); err != nil {
			t.Fatalf("renamed file escaped user dir: %v", err)
		}
	}
	// nothing outside the data dir
	if _, err := os.Stat(filepath.Join(dataDir, "..", "etc")); err == nil {
		t.Fatal("file escaped the data dir")
	}
}
