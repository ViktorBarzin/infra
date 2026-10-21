package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func TestAutomationCategory(t *testing.T) {
	cases := map[string]string{
		"Хол: run_mode → cloud":                           "climate",
		"Кабинет: cloud warm_floor → input_select":        "climate",
		"Heat ventilation Mikro 2":                        "climate",
		"PAX Calima — auto recover stuck BLE coordinator": "climate",
		"LED Кухня, над плот - изключване":                "lighting",
		"Switch ATS to Solar Energy":                      "energy",
		"Set Night Tariff":                                "energy",
		"UPS running on battery notification":             "energy",
		"Update Electrohold Electricity Price Monthly":    "energy",
		"Гараж RCBO — детекция на трип":                   "energy",
		"Мазе — падане на 230V (тихо известие)":           "energy",
		"R730 fan PID — keep SP within SP min / SP max":   "it",
		"R730 PSU primary enforce PSU2":                   "it",
		"Disk usage alert":                                "it",
		"rpi-sofia SD health alert":                       "it",
		"Гараж — перките на рака спряха (тихо известие)":  "it",
		"Alarm AP Exit Timer":                             "security",
		"Аларма — виеща сирена на телефона":               "security",
		"Door lock reactor":                               "security",
		"Врата гараж":                                     "security",
		"Notify on Testville person detection":            "security",
		"Bob car license plate detected":                  "security",
		"Bob car detected on camera":                      "security",
		"Start PAI socat bridge":                          "security",
		"Tuya — пазач по кръстосана проверка":             "other",
	}
	for alias, want := range cases {
		if got := automationCategory(alias); got != want {
			t.Errorf("automationCategory(%q) = %q, want %q", alias, got, want)
		}
	}
}

// homeFixture is a small ha-sofia with personal and security details in
// every free-text field, so the leak test below has something to catch.
func homeFixture() haRaw {
	st := func(id, name string, attrs map[string]any) haState {
		if attrs == nil {
			attrs = map[string]any{}
		}
		attrs["friendly_name"] = name
		return haState{EntityID: id, State: "on", Attributes: attrs}
	}
	return haRaw{
		Version:    "2026.10.2",
		Dashboards: 3,
		States: []haState{
			st("light.kitchen", "Кухня LED Алиса", nil),
			st("light.hall", "Хол", nil),
			st("climate.hol", "Хол термостат", nil),
			st("valve.zone_1", "Zone 1", nil),
			st("media_player.tv", "Sony", nil),
			st("switch.pump", "Pump", nil),
			st("sensor.solar_power", "Solar power", map[string]any{"device_class": "power"}),
			st("sensor.temp", "Temp", map[string]any{"device_class": "temperature"}),
			st("binary_sensor.door", "Door", nil),
			st("camera.testville_gate", "Testville gate NVR-MODEL-9 serial X00000000", nil),
			st("lock.front", "Front door", nil),
			st("alarm_control_panel.testville", "Testville alarm", nil),
			st("person.bob", "Bob", nil),
			st("automation.a1", "Bob car license plate detected", nil),
			st("automation.a2", "LED Спалня Алиса и Боб, гардероб - изключване", nil),
			st("automation.a3", "Хол: run_mode → cloud", nil),
			st("script.s1", "Carol getting home", nil),
		},
		Entries: []haEntry{
			{EntryID: "e1", Domain: "tuya", Title: "Bob Example's Tuya"},
			{EntryID: "e2", Domain: "hikvision_next", Title: "Testville NVR"},
			{EntryID: "e3", Domain: "template", Title: "helper"},
			{EntryID: "e4", Domain: "template", Title: "helper 2"},
			{EntryID: "e5", Domain: "esphome", Title: "esp-home"},
			{EntryID: "e6", Domain: "matter", Title: "Matter"},
			{EntryID: "e7", Domain: "mobile_app", Title: "Alice's iPhone"},
			{EntryID: "e8", Domain: "pax_ble", Title: "Calima"},
			{EntryID: "e9", Domain: "some_new_thing", Title: "Carol's gadget"},
		},
		Devices: []haDevice{
			{ConfigEntries: []string{"e1"}}, {ConfigEntries: []string{"e1"}},
			{ConfigEntries: []string{"e2"}},
			{ConfigEntries: []string{"e5"}},
			{ConfigEntries: []string{"e6"}},
			{ConfigEntries: []string{"e7"}},
			{ConfigEntries: []string{"e8"}},
			{ConfigEntries: []string{"e9"}},
			{ConfigEntries: []string{"e1"}, DisabledBy: "user"},
		},
	}
}

const homeDocFixture = `# Home automation

<!-- showcase: The house in Sofia, run by Home Assistant. -->

Intro text that is not a highlight.

## Server fans on a PID loop
<!-- showcase-highlight: server-fans -->

Home Assistant reads the **server's** temperatures and sets the fan speed.

A second paragraph with a [link](https://example.com) and ` + "`code`" + `.

## Not a highlight

Ignored.

## Solar ATS & tariffs
<!-- showcase-highlight: solar-ats -->
The transfer switch moves the house between solar and grid.
`

func TestBuildHome(t *testing.T) {
	now := time.Date(2026, 10, 21, 6, 30, 0, 0, time.UTC)
	h, err := buildHome(homeFixture(), homeDocFixture, now)
	if err != nil {
		t.Fatal(err)
	}
	if h.Site != "Sofia" || h.AsOf != "2026-10-21T06:30:00Z" || h.Stale || h.Version != "2026.10.2" {
		t.Errorf("header = %+v", h)
	}
	wantCounts := homeCounts{Devices: 8, Entities: 17, Integrations: 9, IntegrationKinds: 8, Automations: 3, Scripts: 1, Dashboards: 3}
	if h.Counts != wantCounts {
		t.Errorf("counts = %+v, want %+v", h.Counts, wantCounts)
	}
	wantKinds := []homeCount{{"lights", 2}, {"climate", 1}, {"water", 1}, {"media", 1}, {"switches", 1}, {"sensors", 3}, {"energy", 1}}
	if !reflect.DeepEqual(h.Kinds, wantKinds) {
		t.Errorf("kinds = %+v, want %+v", h.Kinds, wantKinds)
	}
	if h.Security != (homeSecurity{Cameras: 1, Locks: 1, AlarmPanels: 1}) {
		t.Errorf("security = %+v", h.Security)
	}
	wantRadios := []homeRadio{{"cloud", 2}, {"ble", 1}, {"matter", 1}, {"esphome", 1}, {"mqtt", 0}}
	if !reflect.DeepEqual(h.Radios, wantRadios) {
		t.Errorf("radios = %+v, want %+v", h.Radios, wantRadios)
	}
	wantAuto := []homeCount{{"climate", 1}, {"energy", 0}, {"lighting", 1}, {"security", 1}, {"it", 0}, {"other", 0}}
	if !reflect.DeepEqual(h.Automations, wantAuto) {
		t.Errorf("automations = %+v, want %+v", h.Automations, wantAuto)
	}
	wantInt := []homeIntegration{
		{Domain: "tuya", Name: "Tuya", Devices: 2},
		{Domain: "esphome", Name: "ESPHome", Devices: 1},
		{Domain: "pax_ble", Name: "PAX fans", Devices: 1},
		{Domain: "some_new_thing", Name: "Some New Thing", Devices: 1},
	}
	if !reflect.DeepEqual(h.Integrations, wantInt) {
		t.Errorf("integrations = %+v, want %+v", h.Integrations, wantInt)
	}
	if len(h.Highlights) != 2 || h.Highlights[0].ID != "server-fans" || h.Highlights[1].ID != "solar-ats" {
		t.Fatalf("highlights = %+v", h.Highlights)
	}
}

// TestBuildHomeLeaksNoNames is the privacy rule from the design: only counts
// and integration names leave the generator. Every free-text value in the
// fixture is personal or security detail and none may reach data.json.
func TestBuildHomeLeaksNoNames(t *testing.T) {
	h, err := buildHome(homeFixture(), homeDocFixture, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(h)
	if err != nil {
		t.Fatal(err)
	}
	out := strings.ToLower(string(b))
	for _, s := range []string{"alice", "алиса", "боб", "bob", "carol", "example", "testville",
		"x00000000", "nvr-model", "hikvision", "car ", "кухня", "хол", "light.kitchen", "person", "iphone", "gadget"} {
		if strings.Contains(out, s) {
			t.Errorf("data.json home section contains %q:\n%s", s, b)
		}
	}
}

func TestParseHighlights(t *testing.T) {
	got, err := parseHighlights(homeDocFixture, "docs/architecture/home-automation.md")
	if err != nil {
		t.Fatal(err)
	}
	want := []homeHighlight{
		{
			ID:    "server-fans",
			Title: "Server fans on a PID loop",
			Body:  "Home Assistant reads the server's temperatures and sets the fan speed.\n\nA second paragraph with a link and code.",
			URL:   githubInfraBlob + "docs/architecture/home-automation.md#server-fans-on-a-pid-loop",
		},
		{
			ID:    "solar-ats",
			Title: "Solar ATS & tariffs",
			Body:  "The transfer switch moves the house between solar and grid.",
			URL:   githubInfraBlob + "docs/architecture/home-automation.md#solar-ats--tariffs",
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("parseHighlights:\n got %+v\nwant %+v", got, want)
	}
}

func TestParseHighlightsAllowsModelNames(t *testing.T) {
	doc := "# T\n## Fans\n<!-- showcase-highlight: fans -->\nThe R730's fans and PSU2 follow a PID loop.\n"
	if _, err := parseHighlights(doc, "d.md"); err != nil {
		t.Fatalf("a model name is not a count: %v", err)
	}
}

func TestParseHighlightsRejectsDigitsAndEmpty(t *testing.T) {
	for name, doc := range map[string]string{
		"digits": "# T\n## Fans\n<!-- showcase-highlight: fans -->\nKeeps the fans at 30 percent.\n",
		"ref":    "# T\n## Fans\n<!-- showcase-highlight: fans -->\nSee ADR-0034.\n",
		"none":   "# T\n## Fans\nNo marker here.\n",
		"empty":  "# T\n## Fans\n<!-- showcase-highlight: fans -->\n\n## Next\nx\n",
	} {
		if _, err := parseHighlights(doc, "d.md"); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

// fakeHA serves the REST and websocket endpoints the generator reads.
func fakeHA(t *testing.T, raw haRaw, token string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	authed := func(r *http.Request) bool { return r.Header.Get("Authorization") == "Bearer "+token }
	mux.HandleFunc("/api/config", func(w http.ResponseWriter, r *http.Request) {
		if !authed(r) {
			http.Error(w, "401", http.StatusUnauthorized)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"version": raw.Version})
	})
	mux.HandleFunc("/api/states", func(w http.ResponseWriter, r *http.Request) {
		if !authed(r) {
			http.Error(w, "401", http.StatusUnauthorized)
			return
		}
		_ = json.NewEncoder(w).Encode(raw.States)
	})
	mux.HandleFunc("/api/websocket", func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		ctx := r.Context()
		_ = wsjson.Write(ctx, c, map[string]any{"type": "auth_required"})
		var auth map[string]any
		if wsjson.Read(ctx, c, &auth) != nil || auth["access_token"] != token {
			_ = wsjson.Write(ctx, c, map[string]any{"type": "auth_invalid"})
			return
		}
		_ = wsjson.Write(ctx, c, map[string]any{"type": "auth_ok"})
		dashes := make([]map[string]any, raw.Dashboards)
		for {
			var msg map[string]any
			if wsjson.Read(ctx, c, &msg) != nil {
				return
			}
			var result any
			switch msg["type"] {
			case "config_entries/get":
				result = raw.Entries
			case "config/device_registry/list":
				result = raw.Devices
			case "lovelace/dashboards/list":
				result = dashes
			}
			_ = wsjson.Write(ctx, c, map[string]any{"id": msg["id"], "type": "result", "success": true, "result": result})
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func TestFetchHA(t *testing.T) {
	raw := homeFixture()
	srv := fakeHA(t, raw, "tok")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	got, err := fetchHA(ctx, srv.URL, "tok")
	if err != nil {
		t.Fatal(err)
	}
	if got.Version != raw.Version || got.Dashboards != raw.Dashboards || len(got.States) != len(raw.States) ||
		len(got.Entries) != len(raw.Entries) || len(got.Devices) != len(raw.Devices) {
		t.Errorf("fetchHA = version %q dashboards %d states %d entries %d devices %d",
			got.Version, got.Dashboards, len(got.States), len(got.Entries), len(got.Devices))
	}
	if got.Devices[len(got.Devices)-1].DisabledBy != "user" {
		t.Errorf("disabled_by not decoded: %+v", got.Devices[len(got.Devices)-1])
	}
	if _, err := fetchHA(ctx, srv.URL, "wrong"); err == nil {
		t.Error("expected an error with a bad token")
	}
}

func writeHomeDoc(t *testing.T) string {
	t.Helper()
	src := t.TempDir()
	p := filepath.Join(src, homeDocPath)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(homeDocFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	return src
}

func TestShowcaseHomeLive(t *testing.T) {
	srv := fakeHA(t, homeFixture(), "tok")
	t.Setenv("HA_SOFIA_URL", srv.URL)
	t.Setenv("HA_SOFIA_TOKEN", "tok")
	h, err := showcaseHome(writeHomeDoc(t))
	if err != nil {
		t.Fatal(err)
	}
	if h == nil || h.Stale || h.Counts.Entities != 17 {
		t.Fatalf("showcaseHome = %+v", h)
	}
}

func TestShowcaseHomeFallsBackToPublished(t *testing.T) {
	prev := &homeSection{Site: "Sofia", AsOf: "2026-10-20T06:30:00Z", Counts: homeCounts{Devices: 224}}
	pub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"stats": map[string]any{}, "home": prev})
	}))
	defer pub.Close()
	t.Setenv("HA_SOFIA_URL", "http://127.0.0.1:1") // nothing listens here
	t.Setenv("HA_SOFIA_TOKEN", "tok")
	t.Setenv("SHOWCASE_PUBLISHED_DATA", pub.URL)
	h, err := showcaseHome(writeHomeDoc(t))
	if err != nil {
		t.Fatal(err)
	}
	if h == nil || !h.Stale || h.AsOf != prev.AsOf || h.Counts.Devices != 224 {
		t.Fatalf("fallback = %+v, want the published section marked stale", h)
	}
}

func TestShowcaseHomeOmittedWhenNothingAvailable(t *testing.T) {
	pub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html") // e.g. a challenge page
		_, _ = w.Write([]byte("<html>"))
	}))
	defer pub.Close()
	t.Setenv("HA_SOFIA_URL", "http://127.0.0.1:1")
	t.Setenv("HA_SOFIA_TOKEN", "tok")
	t.Setenv("SHOWCASE_PUBLISHED_DATA", pub.URL)
	h, err := showcaseHome(writeHomeDoc(t))
	if err != nil {
		t.Fatal(err)
	}
	if h != nil {
		t.Fatalf("want no home section, got %+v", h)
	}
}

func TestShowcaseHomeBrokenDocFailsTheBuild(t *testing.T) {
	srv := fakeHA(t, homeFixture(), "tok")
	t.Setenv("HA_SOFIA_URL", srv.URL)
	t.Setenv("HA_SOFIA_TOKEN", "tok")
	if _, err := showcaseHome(t.TempDir()); err == nil {
		t.Fatal("a missing highlights doc is a repo problem and should fail the build")
	}
}
