package main

import (
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestYikoPreflight(t *testing.T) {
	cases := []struct {
		name     string
		set      map[string]map[string]any
		needIdle bool
		want     string // "" = allowed
	}{
		{"healthy", nil, true, ""},
		{"low battery", map[string]map[string]any{"sensor.yiko_battery": {"state": "15"}}, false, "battery"},
		{"battery unknown is allowed", map[string]map[string]any{"sensor.yiko_battery": {"state": "unknown"}}, false, ""},
		{"robot error", map[string]map[string]any{"sensor.yiko_error": {"state": "102", "attributes": map[string]any{"description": "HostHang"}}}, false, "error 102"},
		{"photo running", map[string]map[string]any{"script.yiko_photo": {"state": "on"}}, true, "photo"},
		{"photo running, idle not needed", map[string]map[string]any{"script.yiko_photo": {"state": "on"}}, false, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFakeYikoHA()
			for e, kv := range c.set {
				f.set(e, kv)
			}
			api := startFakeYikoHA(t, f)
			err := yikoPreflight(api, c.needIdle)
			if c.want == "" && err != nil {
				t.Fatalf("want allowed, got %v", err)
			}
			if c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)) {
				t.Fatalf("want an error containing %q, got %v", c.want, err)
			}
		})
	}
}

func TestYikoBudget(t *testing.T) {
	path := filepath.Join(t.TempDir(), "budget.json")
	t0 := time.Date(2026, 11, 14, 10, 0, 0, 0, time.UTC)
	if err := yikoTakeBudget(path, "move", 2, 3, t0); err != nil {
		t.Fatalf("first take: %v", err)
	}
	// persisted: a fresh call sees the 2 already used
	err := yikoTakeBudget(path, "move", 2, 3, t0.Add(time.Minute))
	if err == nil || !strings.Contains(err.Error(), "limit") {
		t.Fatalf("over budget should fail with a limit error, got %v", err)
	}
	// another kind has its own budget
	if err := yikoTakeBudget(path, "camera", 1, 1, t0.Add(time.Minute)); err != nil {
		t.Fatalf("camera budget: %v", err)
	}
	// an hour later the old entries have expired
	if err := yikoTakeBudget(path, "move", 3, 3, t0.Add(61*time.Minute)); err != nil {
		t.Fatalf("after an hour: %v", err)
	}
}

func TestYikoManualArmsAutoDockFirst(t *testing.T) {
	f := newFakeYikoHA()
	api := startFakeYikoHA(t, f)
	useFakeSleep(t)
	old := yikoBudgetPath
	yikoBudgetPath = func() string { return filepath.Join(t.TempDir(), "b.json") }
	t.Cleanup(func() { yikoBudgetPath = old })
	d, _ := parseYikoDrive("drive", []string{"forward", "30"})
	if err := yikoManual(api, d); err != nil {
		t.Fatal(err)
	}
	calls := f.callLog()
	if len(calls) < 3 || !strings.HasPrefix(calls[0], "script.turn_on ") || !strings.Contains(calls[0], "script.yiko_auto_dock") {
		t.Fatalf("calls = %v; want the auto-dock script armed before the first move", calls)
	}
}

func TestYikoManualBlockedSendsNothing(t *testing.T) {
	f := newFakeYikoHA()
	f.set("sensor.yiko_battery", map[string]any{"state": "10"})
	api := startFakeYikoHA(t, f)
	useFakeSleep(t)
	old := yikoBudgetPath
	yikoBudgetPath = func() string { return filepath.Join(t.TempDir(), "b.json") }
	t.Cleanup(func() { yikoBudgetPath = old })
	d, _ := parseYikoDrive("turn", []string{"left", "90"})
	if err := yikoManual(api, d); err == nil {
		t.Fatal("low battery should block the turn")
	}
	if calls := f.callLog(); len(calls) != 0 {
		t.Fatalf("a blocked command must send nothing, sent %v", calls)
	}
}

func TestYikoMoveCount(t *testing.T) {
	d, _ := parseYikoDrive("drive", []string{"forward", "100"}) // 5 s in 2.5 s chunks
	if n := yikoMoveCount(d); n != 4 {
		t.Fatalf("drive 100 cm = %d commands; want 2 chunks x (start+stop) = 4", n)
	}
	d, _ = parseYikoDrive("turn", []string{"right", "270"}) // 3 chunks of 90
	if n := yikoMoveCount(d); n != 6 {
		t.Fatalf("turn 270 = %d commands; want 6", n)
	}
}
