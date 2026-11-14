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
	"time"
)

// fakeYikoHA is a minimal Home Assistant REST API: entity states, service calls
// (recorded), and /media/local files with a Last-Modified time.
type fakeYikoHA struct {
	mu       sync.Mutex
	states   map[string]map[string]any
	calls    []string // "domain.service <json body>"
	media    map[string]time.Time
	camera   []byte // served at /api/camera_proxy/camera.yiko when set
	onCall   func(f *fakeYikoHA, svc string, body map[string]any)
	authSeen string
}

func newFakeYikoHA() *fakeYikoHA {
	return &fakeYikoHA{
		states: map[string]map[string]any{
			"vacuum.yiko": {"state": "docked", "attributes": map[string]any{
				"rooms": map[string]any{"corridor": 1, "kitchen": 4, "bedroom1": []any{6, 9}},
			}},
			"script.yiko_photo":               {"state": "off", "attributes": map[string]any{"last_triggered": "2026-11-13T15:49:13+00:00"}},
			"sensor.yiko_area_cleaned":        {"state": "4", "last_changed": "2026-11-13T13:07:30+00:00"},
			"sensor.yiko_battery":             {"state": "100"},
			"sensor.yiko_station_state":       {"state": "idle"},
			"select.yiko_work_mode":           {"state": "vacuum_and_mop"},
			"input_boolean.yiko_camera":       {"state": "off"},
			"binary_sensor.yiko_camera_ready": {"state": "off"},
		},
		media: map[string]time.Time{},
	}
}

func (f *fakeYikoHA) set(entity string, kv map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for k, v := range kv {
		f.states[entity][k] = v
	}
}

func (f *fakeYikoHA) handler(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.authSeen = r.Header.Get("Authorization")
	f.mu.Unlock()
	switch {
	case strings.HasPrefix(r.URL.Path, "/api/states/"):
		id := strings.TrimPrefix(r.URL.Path, "/api/states/")
		f.mu.Lock()
		st, ok := f.states[id]
		var b []byte
		if ok {
			m := map[string]any{"entity_id": id}
			for k, v := range st {
				m[k] = v
			}
			b, _ = json.Marshal(m)
		}
		f.mu.Unlock()
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Write(b)
	case strings.HasPrefix(r.URL.Path, "/api/services/") && r.Method == http.MethodPost:
		svc := strings.TrimPrefix(r.URL.Path, "/api/services/")
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		_ = json.Unmarshal(raw, &body)
		f.mu.Lock()
		f.calls = append(f.calls, strings.Replace(svc, "/", ".", 1)+" "+string(raw))
		hook := f.onCall
		f.mu.Unlock()
		if hook != nil {
			hook(f, strings.Replace(svc, "/", ".", 1), body)
		}
		w.Write([]byte("[]"))
	case r.URL.Path == "/api/camera_proxy/camera.yiko":
		f.mu.Lock()
		img := f.camera
		f.mu.Unlock()
		if img == nil {
			http.Error(w, "no image", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		w.Write(img)
	case strings.HasPrefix(r.URL.Path, "/media/local/"):
		f.mu.Lock()
		mt, ok := f.media[strings.TrimPrefix(r.URL.Path, "/media/local/")]
		f.mu.Unlock()
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Last-Modified", mt.UTC().Format(http.TimeFormat))
		w.Header().Set("Content-Type", "image/jpeg")
		w.Write([]byte("JPEG:" + r.URL.Path))
	default:
		http.NotFound(w, r)
	}
}

func (f *fakeYikoHA) callLog() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

func startFakeYikoHA(t *testing.T, f *fakeYikoHA) haAPI {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(f.handler))
	t.Cleanup(srv.Close)
	oldPoll, oldStart, oldRun := yikoPoll, yikoStartTimeout, yikoRunTimeout
	yikoPoll, yikoStartTimeout, yikoRunTimeout = 5*time.Millisecond, 300*time.Millisecond, 2*time.Second
	t.Cleanup(func() { yikoPoll, yikoStartTimeout, yikoRunTimeout = oldPoll, oldStart, oldRun })
	return haAPI{base: srv.URL, token: "tok", hc: srv.Client()}
}

func TestParseYikoArgs(t *testing.T) {
	o, err := parseYikoArgs("photo", []string{"corridor", "--shots", "3", "--out", "/tmp/x", "--json"})
	if err != nil || o.room != "corridor" || o.shots != 3 || o.out != "/tmp/x" || !o.json {
		t.Fatalf("parse = %+v, %v", o, err)
	}
	if o, err := parseYikoArgs("photo", []string{"kitchen"}); err != nil || o.shots != 6 {
		t.Fatalf("default shots = %+v, %v; want 6", o, err)
	}
	for _, bad := range [][]string{
		{},                            // room required
		{"corridor", "--bogus"},       // unknown flag fails closed
		{"corridor", "kitchen"},       // second positional
		{"corridor", "--shots", "0"},  // out of range
		{"corridor", "--shots", "16"}, // out of range
		{"corridor", "--shots"},       // missing value
		{"--help"},                    // help never runs the verb
	} {
		if _, err := parseYikoArgs("photo", bad); err == nil {
			t.Errorf("parseYikoArgs(photo, %q) should fail", bad)
		}
	}
	if _, err := parseYikoArgs("status", []string{"corridor"}); err == nil {
		t.Errorf("status takes no room")
	}
	if o, err := parseYikoArgs("status", []string{"--json"}); err != nil || !o.json {
		t.Errorf("status --json = %+v, %v", o, err)
	}
}

func TestYikoRoomID(t *testing.T) {
	api := startFakeYikoHA(t, newFakeYikoHA())
	if id, err := yikoRoomID(api, "corridor"); err != nil || id != 1 {
		t.Fatalf("corridor = %d, %v", id, err)
	}
	if id, err := yikoRoomID(api, "bedroom1"); err != nil || id != 6 {
		t.Fatalf("bedroom1 (list) = %d, %v; want first id 6", id, err)
	}
	_, err := yikoRoomID(api, "attic")
	if err == nil || !strings.Contains(err.Error(), "corridor") {
		t.Fatalf("unknown room should list known rooms, got %v", err)
	}
}

func TestYikoClean(t *testing.T) {
	f := newFakeYikoHA()
	f.onCall = func(f *fakeYikoHA, svc string, body map[string]any) {
		if svc == "vacuum.send_command" {
			f.set("sensor.yiko_area_cleaned", map[string]any{"state": "0", "last_changed": "2026-11-14T10:00:00+00:00"})
		}
	}
	api := startFakeYikoHA(t, f)
	if err := yikoClean(api, "kitchen"); err != nil {
		t.Fatalf("yikoClean: %v", err)
	}
	calls := f.callLog()
	if len(calls) != 1 || !strings.HasPrefix(calls[0], "vacuum.send_command ") {
		t.Fatalf("calls = %v", calls)
	}
	var body map[string]any
	_ = json.Unmarshal([]byte(strings.TrimPrefix(calls[0], "vacuum.send_command ")), &body)
	params := body["params"].(map[string]any)
	content := params["content"].(map[string]any)
	if body["command"] != "clean_V2" || params["act"] != "start" || content["type"] != "freeClean" || content["value"] != "1,4" {
		t.Fatalf("send_command body = %v; want clean_V2 freeClean value \"1,4\" (a string)", body)
	}
	if f.authSeen != "Bearer tok" {
		t.Fatalf("auth header = %q", f.authSeen)
	}
}

func TestYikoCleanNotStarted(t *testing.T) {
	api := startFakeYikoHA(t, newFakeYikoHA()) // area sensor never changes
	err := yikoClean(api, "corridor")
	if err == nil || !strings.Contains(err.Error(), "did not start") {
		t.Fatalf("want a did-not-start error, got %v", err)
	}
}

func TestYikoDock(t *testing.T) {
	f := newFakeYikoHA()
	api := startFakeYikoHA(t, f)
	if err := yikoDock(api); err != nil {
		t.Fatal(err)
	}
	calls := f.callLog()
	if len(calls) != 2 || !strings.Contains(calls[0], `"act":"stop"`) || !strings.HasPrefix(calls[1], "vacuum.return_to_base ") {
		t.Fatalf("calls = %v; want stop then return_to_base", calls)
	}
}

func TestYikoPhoto(t *testing.T) {
	f := newFakeYikoHA()
	trig := "2026-11-14T10:00:00+00:00"
	runAt, _ := time.Parse(time.RFC3339, trig)
	// an old photo from an earlier run must not be returned
	f.media["yiko/corridor-3.jpg"] = runAt.Add(-time.Hour)
	f.onCall = func(f *fakeYikoHA, svc string, body map[string]any) {
		if svc != "script.turn_on" {
			return
		}
		f.set("script.yiko_photo", map[string]any{"state": "on", "attributes": map[string]any{"last_triggered": trig}})
		go func() {
			time.Sleep(30 * time.Millisecond)
			f.mu.Lock()
			f.media["yiko/corridor-1.jpg"] = runAt.Add(70 * time.Second)
			f.media["yiko/corridor-2.jpg"] = runAt.Add(85 * time.Second)
			f.mu.Unlock()
			f.set("script.yiko_photo", map[string]any{"state": "off"})
		}()
	}
	api := startFakeYikoHA(t, f)
	out := t.TempDir()
	res, err := yikoPhoto(api, yikoOpts{room: "corridor", shots: 3, out: out})
	if err != nil {
		t.Fatalf("yikoPhoto: %v", err)
	}
	want := []string{filepath.Join(out, "corridor-1.jpg"), filepath.Join(out, "corridor-2.jpg")}
	if strings.Join(res.Files, ",") != strings.Join(want, ",") {
		t.Fatalf("files = %v; want %v", res.Files, want)
	}
	b, _ := os.ReadFile(want[0])
	if string(b) != "JPEG:/media/local/yiko/corridor-1.jpg" {
		t.Fatalf("file content = %q", b)
	}
	calls := f.callLog()
	if len(calls) != 1 || !strings.Contains(calls[0], `"entity_id":"script.yiko_photo"`) ||
		!strings.Contains(calls[0], `"room":"corridor"`) || !strings.Contains(calls[0], `"shots":3`) {
		t.Fatalf("calls = %v", calls)
	}
}

func TestYikoPhotoNoNewFiles(t *testing.T) {
	f := newFakeYikoHA()
	f.onCall = func(f *fakeYikoHA, svc string, body map[string]any) {
		f.set("script.yiko_photo", map[string]any{"state": "off", "attributes": map[string]any{"last_triggered": "2026-11-14T10:00:00+00:00"}})
	}
	api := startFakeYikoHA(t, f)
	_, err := yikoPhoto(api, yikoOpts{room: "corridor", shots: 2, out: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "no new photos") {
		t.Fatalf("want no-new-photos error, got %v", err)
	}
}

func TestYikoPhotoRefusesWhileRunning(t *testing.T) {
	f := newFakeYikoHA()
	f.set("script.yiko_photo", map[string]any{"state": "on"})
	api := startFakeYikoHA(t, f)
	_, err := yikoPhoto(api, yikoOpts{room: "corridor", shots: 2, out: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "already running") {
		t.Fatalf("want already-running error, got %v", err)
	}
	if len(f.callLog()) != 0 {
		t.Fatalf("must not call any service while a run is in progress")
	}
}

func TestYikoStatus(t *testing.T) {
	api := startFakeYikoHA(t, newFakeYikoHA())
	st, err := yikoStatus(api)
	if err != nil {
		t.Fatal(err)
	}
	if st["vacuum"] != "docked" || st["battery"] != "100" || st["work_mode"] != "vacuum_and_mop" || st["photo_script"] != "off" {
		t.Fatalf("status = %v", st)
	}
}

func TestYikoNightGuard(t *testing.T) {
	london, _ := time.LoadLocation("Europe/London")
	cases := []struct {
		at    string
		quiet bool
	}{
		{"2026-11-14T02:48:00", true},
		{"2026-11-14T21:59:00", false},
		{"2026-11-14T22:00:00", true},
		{"2026-11-14T07:59:00", true},
		{"2026-11-14T08:00:00", false},
		{"2026-07-14T07:30:00", true}, // BST: local London time, not UTC
	}
	for _, c := range cases {
		at, _ := time.ParseInLocation("2006-01-02T15:04:05", c.at, london)
		if got := yikoQuietHours(at.UTC()); got != c.quiet {
			t.Errorf("yikoQuietHours(%s) = %v; want %v", c.at, got, c.quiet)
		}
	}
	if o, err := parseYikoArgs("photo", []string{"corridor", "--night"}); err != nil || !o.night {
		t.Fatalf("--night = %+v, %v", o, err)
	}
	if _, err := parseYikoArgs("dock", []string{"--night"}); err == nil {
		t.Fatalf("dock takes no --night")
	}
	old := yikoNow
	t.Cleanup(func() { yikoNow = old })
	yikoNow = func() time.Time {
		at, _ := time.ParseInLocation("2006-01-02T15:04", "2026-11-14T02:48", london)
		return at
	}
	if err := yikoCheckHours(yikoOpts{room: "corridor"}); err == nil || !strings.Contains(err.Error(), "--night") {
		t.Fatalf("a night run without --night should be refused, got %v", err)
	}
	if err := yikoCheckHours(yikoOpts{room: "corridor", night: true}); err != nil {
		t.Fatalf("--night should allow it: %v", err)
	}
}
