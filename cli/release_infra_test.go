package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReleaseLockSerialisesAndNamesTheHolder(t *testing.T) {
	path := filepath.Join(t.TempDir(), "release.lock")
	var out strings.Builder
	first, err := acquireReleaseLock(path, time.Second, "wizard: f1-stream abc", &out)
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	_, err = acquireReleaseLock(path, 300*time.Millisecond, "emo: f1-stream def", &out)
	if err == nil {
		t.Fatalf("second acquire succeeded while the first held the lock")
	}
	if !strings.Contains(err.Error(), "wizard: f1-stream abc") {
		t.Errorf("the timeout names the holder, got %v", err)
	}
	if !strings.Contains(out.String(), "waiting") {
		t.Errorf("a blocked release says it is waiting, got %q", out.String())
	}
	first()
	second, err := acquireReleaseLock(path, time.Second, "emo: f1-stream def", &out)
	if err != nil {
		t.Fatalf("acquire after release: %v", err)
	}
	second()
}

func TestReleaseLockOpensAFileAnotherUserCreated(t *testing.T) {
	// /run/lock is sticky and fs.protected_regular refuses an O_CREAT open of
	// another user's file there, so an existing lock is opened without O_CREAT.
	// A read-only existing file stands in for "not ours to create".
	path := filepath.Join(t.TempDir(), "release.lock")
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	unlock, err := acquireReleaseLock(path, time.Second, "x", &strings.Builder{})
	if err != nil {
		t.Fatalf("acquire on an existing file: %v", err)
	}
	unlock()
}

func newFakeRegistry(t *testing.T, manifests map[string]string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/token":
			u, p, ok := r.BasicAuth()
			if !ok || u != "bot" || p != "secret" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			if !strings.Contains(r.URL.Query().Get("scope"), "repository:viktorbarzin/") {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]string{"token": "bearer-ok"})
		case strings.HasPrefix(r.URL.Path, "/v2/"):
			if r.Header.Get("Authorization") != "Bearer bearer-ok" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			body, ok := manifests[r.URL.Path]
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				_, _ = w.Write([]byte(`{"errors":[{"code":"MANIFEST_UNKNOWN"}]}`))
				return
			}
			w.Header().Set("Content-Type", "application/vnd.oci.image.manifest.v1+json")
			_, _ = w.Write([]byte(body))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

func TestReleaseRegistryManifestLookup(t *testing.T) {
	apk := `{"schemaVersion":2,"layers":[
	  {"digest":"sha256:aaaa","annotations":{"org.opencontainers.image.title":"output-metadata.json"}},
	  {"digest":"sha256:257ebe97","annotations":{"org.opencontainers.image.title":"app-release.apk"}}]}`
	srv := newFakeRegistry(t, map[string]string{
		"/v2/viktorbarzin/f1-stream/manifests/a020f2dc": `{"schemaVersion":2,"layers":[]}`,
		"/v2/viktorbarzin/f1-stream-tv/manifests/31425": apk,
	})
	defer srv.Close()
	reg := &registryClient{base: srv.URL, user: "bot", token: "secret", http: srv.Client()}

	m, ok, err := reg.manifest("ghcr.io/viktorbarzin/f1-stream", "a020f2dc")
	if err != nil || !ok || m == nil {
		t.Fatalf("existing image: %v %v %v", m, ok, err)
	}
	_, ok, err = reg.manifest("ghcr.io/viktorbarzin/f1-stream", "deadbeef")
	if err != nil || ok {
		t.Fatalf("missing tag reads as absent, got ok=%v err=%v", ok, err)
	}
	m, ok, err = reg.manifest("ghcr.io/viktorbarzin/f1-stream-tv", "31425")
	if err != nil || !ok {
		t.Fatalf("tv artifact: %v %v", ok, err)
	}
	if got := m.layerDigest("app-release.apk"); got != "257ebe97" {
		t.Errorf("layerDigest(app-release.apk) = %q", got)
	}

	bad := &registryClient{base: srv.URL, user: "bot", token: "wrong", http: srv.Client()}
	if _, _, err := bad.manifest("ghcr.io/viktorbarzin/f1-stream", "a020f2dc"); err == nil {
		t.Errorf("a refused login is an error, not an absent tag")
	}
}

func TestReleaseWoodpeckerOrderStepFailure(t *testing.T) {
	var p wpPipelineDetail
	_ = json.Unmarshal([]byte(`{"number":602,"status":"failure","workflows":[{"name":"deploy","state":"failure",
	  "children":[{"name":"git","state":"success"},{"name":"check-vars","state":"success"},{"name":"order","state":"failure"},{"name":"deploy","state":"skipped"}]}]}`), &p)
	if got := p.failedSteps(); len(got) != 1 || got[0] != "order" {
		t.Errorf("failedSteps = %v", got)
	}
	_ = json.Unmarshal([]byte(`{"number":603,"status":"success","workflows":[{"name":"deploy","state":"success","children":[{"name":"deploy","state":"success"}]}]}`), &p)
	if got := p.failedSteps(); len(got) != 0 {
		t.Errorf("failedSteps on success = %v", got)
	}
}

func TestReleaseWoodpeckerTriggerSendsVariables(t *testing.T) {
	var got map[string]interface{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/repos/10/pipelines" || r.Header.Get("Authorization") != "Bearer wp" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(`{"number":604,"status":"pending"}`))
	}))
	defer srv.Close()
	c := &wpClient{base: srv.URL, token: "wp", http: srv.Client()}
	n, err := c.startManualPipeline(10, map[string]string{"PIPELINE": "publish-tv", "TV_VERSION": "31520"})
	if err != nil || n != 604 {
		t.Fatalf("startManualPipeline = %d %v", n, err)
	}
	vars, _ := got["variables"].(map[string]interface{})
	if got["branch"] != "master" || vars["TV_VERSION"] != "31520" || vars["PIPELINE"] != "publish-tv" {
		t.Errorf("posted %v", got)
	}
}
