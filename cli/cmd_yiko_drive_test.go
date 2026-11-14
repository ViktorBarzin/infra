package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

// fakeClock records sleeps instead of waiting, so drive timing is testable.
func useFakeSleep(t *testing.T) *[]time.Duration {
	t.Helper()
	var slept []time.Duration
	old := yikoSleep
	yikoSleep = func(d time.Duration) { slept = append(slept, d) }
	t.Cleanup(func() { yikoSleep = old })
	return &slept
}

// moveCalls returns the params of each `move` send_command, in order.
func moveCalls(t *testing.T, f *fakeYikoHA) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, c := range f.callLog() {
		if !strings.HasPrefix(c, "vacuum.send_command ") {
			continue
		}
		var body map[string]any
		_ = json.Unmarshal([]byte(strings.TrimPrefix(c, "vacuum.send_command ")), &body)
		if body["command"] != "move" {
			continue
		}
		out = append(out, body["params"].(map[string]any))
	}
	return out
}

func TestParseYikoDriveArgs(t *testing.T) {
	d, err := parseYikoDrive("drive", []string{"forward", "50"})
	if err != nil || d.act != "forward" || d.dur != 2500*time.Millisecond {
		t.Fatalf("drive forward 50 = %+v, %v; want forward 2.5s (20 cm/s)", d, err)
	}
	d, err = parseYikoDrive("drive", []string{"backward", "20"})
	if err != nil || d.act != "backward" || d.dur != time.Second {
		t.Fatalf("drive backward 20 = %+v, %v", d, err)
	}
	d, err = parseYikoDrive("turn", []string{"left", "90"})
	if err != nil || d.act != "spinLeft" || d.a != 90 || d.dur != 1800*time.Millisecond {
		t.Fatalf("turn left 90 = %+v, %v; want spinLeft a=90 1.8s at 50 deg/s", d, err)
	}
	d, err = parseYikoDrive("turn", []string{"right"})
	if err != nil || d.act != "spinRight" || d.dur != 1800*time.Millisecond {
		t.Fatalf("turn right (default 90) = %+v, %v", d, err)
	}
	if d, err := parseYikoDrive("drive", []string{"forward", "30", "--night"}); err != nil || !d.night {
		t.Fatalf("--night = %+v, %v", d, err)
	}
	for _, bad := range [][]string{
		{},
		{"sideways", "10"},
		{"forward"}, // drive needs a distance
		{"forward", "0"},
		{"forward", "301"}, // over the cap
		{"forward", "ten"},
		{"forward", "10", "--bogus"},
		{"forward", "10", "20"},
		{"--help"},
	} {
		if _, err := parseYikoDrive("drive", bad); err == nil {
			t.Errorf("parseYikoDrive(drive, %q) should fail", bad)
		}
	}
	for _, bad := range [][]string{{"up", "90"}, {"left", "0"}, {"left", "361"}} {
		if _, err := parseYikoDrive("turn", bad); err == nil {
			t.Errorf("parseYikoDrive(turn, %q) should fail", bad)
		}
	}
}

func TestYikoMoveShort(t *testing.T) {
	f := newFakeYikoHA()
	api := startFakeYikoHA(t, f)
	slept := useFakeSleep(t)
	if err := yikoMove(api, yikoDrive{act: "forward", a: 0, dur: 2 * time.Second}); err != nil {
		t.Fatal(err)
	}
	calls := moveCalls(t, f)
	if len(calls) != 2 || calls[0]["act"] != "forward" || calls[0]["a"] != float64(0) || calls[1]["act"] != "stop" {
		t.Fatalf("move calls = %v; want forward(a=0) then stop", calls)
	}
	if len(*slept) != 1 || (*slept)[0] != 2*time.Second {
		t.Fatalf("slept %v; want one 2s wait", *slept)
	}
}

func TestYikoMoveChunks(t *testing.T) {
	f := newFakeYikoHA()
	api := startFakeYikoHA(t, f)
	slept := useFakeSleep(t)
	// A long move is split into start-wait-stop chunks: re-sending a spin
	// while it turns cut a 180 deg turn to about 100 deg on the real robot.
	if err := yikoMove(api, yikoDrive{act: "spinLeft", a: 90, dur: 5 * time.Second, chunk: 2 * time.Second}); err != nil {
		t.Fatal(err)
	}
	calls := moveCalls(t, f)
	var acts []string
	for _, c := range calls {
		acts = append(acts, c["act"].(string))
	}
	want := "spinLeft,stop,spinLeft,stop,spinLeft,stop"
	if strings.Join(acts, ",") != want || calls[2]["a"] != float64(90) {
		t.Fatalf("move acts = %v; want %s", acts, want)
	}
	wantSleeps := []time.Duration{2 * time.Second, yikoChunkPause, 2 * time.Second, yikoChunkPause, time.Second}
	if len(*slept) != len(wantSleeps) {
		t.Fatalf("slept %v; want %v", *slept, wantSleeps)
	}
	for i := range wantSleeps {
		if (*slept)[i] != wantSleeps[i] {
			t.Fatalf("slept %v; want %v", *slept, wantSleeps)
		}
	}
}

func TestYikoChunkSizes(t *testing.T) {
	d, _ := parseYikoDrive("turn", []string{"left", "180"})
	if d.chunk != 1800*time.Millisecond {
		t.Fatalf("turn chunk = %v; want one 90 deg turn, 1.8s", d.chunk)
	}
	d, _ = parseYikoDrive("drive", []string{"forward", "100"})
	if d.chunk != 2500*time.Millisecond {
		t.Fatalf("drive chunk = %v; want 2.5s", d.chunk)
	}
}

func TestYikoStop(t *testing.T) {
	f := newFakeYikoHA()
	api := startFakeYikoHA(t, f)
	useFakeSleep(t)
	if err := yikoStop(api); err != nil {
		t.Fatal(err)
	}
	calls := moveCalls(t, f)
	if len(calls) != 1 || calls[0]["act"] != "stop" {
		t.Fatalf("stop calls = %v", calls)
	}
}

func TestYikoLook(t *testing.T) {
	f := newFakeYikoHA()
	f.onCall = func(f *fakeYikoHA, svc string, body map[string]any) {
		if svc == "input_boolean.turn_on" {
			f.set("binary_sensor.yiko_camera_ready", map[string]any{"state": "on"})
		}
	}
	api := startFakeYikoHA(t, f)
	f.camera = []byte("JPEGDATA")
	out := t.TempDir() + "/look.jpg"
	path, err := yikoLook(api, out)
	if err != nil || path != out {
		t.Fatalf("yikoLook = %q, %v", path, err)
	}
	b, _ := os.ReadFile(out)
	if string(b) != "JPEGDATA" {
		t.Fatalf("snapshot content = %q", b)
	}
	if calls := f.callLog(); len(calls) != 1 || !strings.HasPrefix(calls[0], "input_boolean.turn_on ") {
		t.Fatalf("calls = %v; want the camera switched on once", calls)
	}
}

func TestYikoLookRestartsStaleCamera(t *testing.T) {
	// HA switches the camera off after 10 min while the ready sensor still says
	// on; the snapshot then fails, and look must restart the camera once.
	f := newFakeYikoHA()
	f.set("binary_sensor.yiko_camera_ready", map[string]any{"state": "on"})
	f.onCall = func(f *fakeYikoHA, svc string, body map[string]any) {
		switch svc {
		case "input_boolean.turn_off":
			f.set("binary_sensor.yiko_camera_ready", map[string]any{"state": "off"})
		case "input_boolean.turn_on":
			f.mu.Lock()
			f.camera = []byte("FRESH")
			f.mu.Unlock()
			f.set("binary_sensor.yiko_camera_ready", map[string]any{"state": "on"})
		}
	}
	api := startFakeYikoHA(t, f)
	useFakeSleep(t)
	out := t.TempDir() + "/look.jpg"
	if _, err := yikoLook(api, out); err != nil {
		t.Fatalf("yikoLook: %v", err)
	}
	b, _ := os.ReadFile(out)
	if string(b) != "FRESH" {
		t.Fatalf("snapshot = %q; want the frame after the restart", b)
	}
	calls := f.callLog()
	if len(calls) != 2 || !strings.HasPrefix(calls[0], "input_boolean.turn_off ") || !strings.HasPrefix(calls[1], "input_boolean.turn_on ") {
		t.Fatalf("calls = %v; want camera off then on", calls)
	}
}

func TestYikoLookCameraNeverReady(t *testing.T) {
	api := startFakeYikoHA(t, newFakeYikoHA())
	_, err := yikoLook(api, t.TempDir()+"/x.jpg")
	if err == nil || !strings.Contains(err.Error(), "dock") {
		t.Fatalf("want a camera-not-ready error that mentions the dock, got %v", err)
	}
}
