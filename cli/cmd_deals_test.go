package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
)

func TestDealsShopProfile(t *testing.T) {
	cases := []struct {
		in, url, shop, cookie string
		keepa                 int
	}{
		{"https://www.amazon.co.uk/SanDisk-Extreme-SDXC/dp/B09X7FXHVJ/ref=sr_1_3?th=1", "https://www.amazon.co.uk/dp/B09X7FXHVJ", "amazon.co.uk", "i18n-prefs=GBP", 2},
		{"https://amazon.de/gp/product/B09X7FXHVJ?psc=1", "https://www.amazon.de/dp/B09X7FXHVJ", "amazon.de", "i18n-prefs=EUR", 3},
		{"https://shop.example.com/item/42?colour=red", "https://shop.example.com/item/42?colour=red", "generic", "", 0},
	}
	for _, c := range cases {
		p, url, err := dealsShopFor(c.in)
		if err != nil {
			t.Fatalf("%s: %v", c.in, err)
		}
		if url != c.url || p.Name != c.shop || p.KeepaDomain != c.keepa {
			t.Errorf("%s: got %s %s %d", c.in, url, p.Name, p.KeepaDomain)
		}
		if !strings.Contains(p.Headers["Cookie"], c.cookie) {
			t.Errorf("%s: cookie %q lacks %q", c.in, p.Headers["Cookie"], c.cookie)
		}
		if c.keepa != 0 && len(p.IncludeFilters) != 1 {
			t.Errorf("%s: want the new-only price filter, got %v", c.in, p.IncludeFilters)
		}
	}
	if _, _, err := dealsShopFor("not a url"); err == nil {
		t.Error("want an error for a URL without a host")
	}
}

func TestRosterAuthentikName(t *testing.T) {
	y := []byte("users:\n  wizard:    {authentik_user: vbarzin, tier: admin}\n  emo:       {authentik_user: emil.barzin, tier: power-user}\n")
	if got := rosterAuthentikName(y, "emo"); got != "emil.barzin" {
		t.Errorf("emo -> %q", got)
	}
	if got := rosterAuthentikName(y, "nobody"); got != "" {
		t.Errorf("unknown user -> %q, want empty", got)
	}
}

// keepaMinute turns a date into Keepa's time unit: minutes since 2011-01-01.
func keepaMinute(d time.Time) int64 {
	return int64(d.Sub(time.Date(2011, 1, 1, 0, 0, 0, 0, time.UTC)).Minutes())
}

func keepaFramesOutput(t *testing.T, product map[string]any) string {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"basicProducts": []any{product}})
	enc, _ := zstd.NewWriter(nil)
	compressed := enc.EncodeAll(body, nil)
	plain := base64.StdEncoding.EncodeToString([]byte(`{"status":200}`))
	frames, _ := json.Marshal([]map[string]string{
		{"t": "b", "d": plain},
		{"t": "b", "d": base64.StdEncoding.EncodeToString(compressed)},
	})
	return "homelab browser: connected\n[browser] ws wss://push.keepa.com\n" + keepaFramesMarker + string(frames) + "\n"
}

func TestKeepaLowsFromFrames(t *testing.T) {
	now := time.Date(2026, 11, 17, 0, 0, 0, 0, time.UTC)
	m := func(y int, mo time.Month, d int) int64 { return keepaMinute(time.Date(y, mo, d, 0, 0, 0, 0, time.UTC)) }
	product := map[string]any{
		"asin": "B09X7FXHVJ",
		"csv": []any{
			[]int64{m(2026, 1, 1), 999},
			[]int64{
				m(2024, 11, 21), 1430,
				m(2025, 11, 20), 1899,
				m(2026, 3, 1), -1, // no new offer: skipped
				m(2026, 10, 1), 3999,
				m(2026, 11, 16), 3567,
			},
		},
	}
	lows, err := keepaLowsFromOutput(keepaFramesOutput(t, product), "B09X7FXHVJ", now)
	if err != nil {
		t.Fatal(err)
	}
	want := []struct {
		label string
		cents int64
		date  string
	}{{"90 days", 3567, "2026-11-16"}, {"365 days", 1899, "2025-11-20"}, {"all time", 1430, "2024-11-21"}}
	if len(lows.Lows) != len(want) {
		t.Fatalf("got %d lows", len(lows.Lows))
	}
	for i, w := range want {
		g := lows.Lows[i]
		if g.Label != w.label || g.Cents != w.cents || g.At.Format("2006-01-02") != w.date {
			t.Errorf("low %d: got %s %d %s", i, g.Label, g.Cents, g.At.Format("2006-01-02"))
		}
	}
	if lows.CurrentCents != 3567 {
		t.Errorf("current %d", lows.CurrentCents)
	}
	if _, err := keepaLowsFromOutput("Sorry, you have been blocked", "B09X7FXHVJ", now); err == nil {
		t.Error("want an error when no frame holds the product")
	}
}

// fakeCD is a changedetection API double. A check is "run" by the Nth GET of
// the watch after a recheck; results says what each check finds.
type fakeCD struct {
	mu       sync.Mutex
	watches  map[string]map[string]any
	results  []func(w map[string]any) // one per check, applied in order
	checks   int
	puts     []map[string]any
	created  map[string]any
	deleted  []string
	rechecks int
}

func newFakeCD() *fakeCD { return &fakeCD{watches: map[string]map[string]any{}} }

func (f *fakeCD) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if r.Header.Get("x-api-key") != "k" {
			w.WriteHeader(403)
			return
		}
		path := strings.TrimPrefix(r.URL.Path, "/api/v1/")
		switch {
		case path == "tags" && r.Method == "GET":
			fmt.Fprint(w, `{"tag-1":{"title":"deals","uuid":"tag-1"},"tag-2":{"title":"other"}}`)
		case path == "watch" && r.Method == "GET":
			out := map[string]any{}
			for id, wt := range f.watches {
				out[id] = map[string]any{"title": wt["title"], "url": wt["url"]}
			}
			json.NewEncoder(w).Encode(out)
		case path == "watch" && r.Method == "POST":
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			f.created = map[string]any{}
			for k, v := range body {
				f.created[k] = v
			}
			id := fmt.Sprintf("uuid-%d", len(f.watches)+1)
			body["uuid"] = id
			body["check_count"] = 0
			body["last_error"] = false
			f.watches[id] = body
			fmt.Fprintf(w, `{"uuid":%q}`, id)
		case strings.HasPrefix(path, "watch/"):
			id := strings.TrimPrefix(path, "watch/")
			wt, ok := f.watches[id]
			if !ok {
				w.WriteHeader(404)
				return
			}
			switch r.Method {
			case "GET":
				if r.URL.Query().Get("recheck") == "1" {
					f.rechecks++
					if f.checks < len(f.results) {
						f.results[f.checks](wt)
						f.checks++
						wt["check_count"] = f.checks
					}
					fmt.Fprint(w, `"OK"`)
					return
				}
				json.NewEncoder(w).Encode(wt)
			case "PUT":
				var body map[string]any
				json.NewDecoder(r.Body).Decode(&body)
				f.puts = append(f.puts, body)
				for k, v := range body {
					wt[k] = v
				}
				fmt.Fprint(w, `"OK"`)
			case "DELETE":
				f.deleted = append(f.deleted, id)
				delete(f.watches, id)
				fmt.Fprint(w, `"DELETED"`)
			}
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL)
			w.WriteHeader(500)
		}
	})
}

func priceFound(p float64) func(map[string]any) {
	return func(w map[string]any) {
		w["last_error"] = false
		w["page_title"] = "SanDisk 128GB Extreme PRO SDXC card, SD Card, V30"
		w["processor_state_restock_diff"] = map[string]any{"price": p, "currency": "£"}
	}
}

func checkFails(msg string) func(map[string]any) {
	return func(w map[string]any) { w["last_error"] = msg }
}

func testDealsEnv(t *testing.T, f *fakeCD) (*dealsEnv, *bytes.Buffer) {
	srv := httptest.NewServer(f.handler(t))
	t.Cleanup(srv.Close)
	var out bytes.Buffer
	return &dealsEnv{
		api:       &cdClient{base: srv.URL + "/api/v1", key: "k", http: srv.Client()},
		requester: "vbarzin",
		out:       &out,
		now:       func() time.Time { return time.Date(2026, 11, 17, 10, 0, 0, 0, time.UTC) },
		poll:      time.Millisecond,
		wait:      200 * time.Millisecond,
		keepa: func(asin string, domain int) (*keepaHistory, error) {
			return &keepaHistory{CurrentCents: 3567, Lows: []keepaLow{{Label: "365 days", Cents: 1899, At: time.Date(2025, 11, 20, 0, 0, 0, 0, time.UTC)}}}, nil
		},
		chart: func(asin string, p dealsShop) (string, error) { return "/tmp/chart.png", nil },
	}, &out
}

func lastPut(f *fakeCD) map[string]any { return f.puts[len(f.puts)-1] }

func TestDealsAddUsesTodaysPriceAsTarget(t *testing.T) {
	f := newFakeCD()
	f.results = []func(map[string]any){priceFound(35.67)}
	env, out := testDealsEnv(t, f)
	if err := env.add(dealsAddOpts{url: "https://www.amazon.co.uk/x/dp/B09X7FXHVJ?ref=1"}); err != nil {
		t.Fatalf("add: %v\n%s", err, out)
	}
	if f.created["notification_muted"] != true {
		t.Error("a new watch must be muted until its target is set")
	}
	if got := f.created["tags"].([]any)[0]; got != "tag-1" {
		t.Errorf("tag %v", got)
	}
	if f.created["url"] != "https://www.amazon.co.uk/dp/B09X7FXHVJ" {
		t.Errorf("url %v", f.created["url"])
	}
	p := lastPut(f)
	cfg := p["processor_config_restock_diff"].(map[string]any)
	if cfg["price_change_min"] != 35.67 {
		t.Errorf("target %v, want today's price", cfg["price_change_min"])
	}
	if p["notification_muted"] != false {
		t.Error("watch left muted")
	}
	if p["title"] != "[vbarzin] SanDisk 128GB Extreme PRO SDXC card" {
		t.Errorf("title %q", p["title"])
	}
	if !strings.Contains(p["notification_body"].(string), "target £35.67") {
		t.Errorf("body %q", p["notification_body"])
	}
	for _, s := range []string{"£35.67", "365 days", "£18.99", "2025-11-20"} {
		if !strings.Contains(out.String(), s) {
			t.Errorf("output lacks %q:\n%s", s, out)
		}
	}
}

func TestDealsAddExplicitTargetAndName(t *testing.T) {
	f := newFakeCD()
	f.results = []func(map[string]any){priceFound(35.67)}
	env, out := testDealsEnv(t, f)
	err := env.add(dealsAddOpts{url: "https://shop.example.com/card", below: 30, name: "SD card"})
	if err != nil {
		t.Fatalf("add: %v\n%s", err, out)
	}
	p := lastPut(f)
	if p["processor_config_restock_diff"].(map[string]any)["price_change_min"] != 30.0 {
		t.Errorf("target %v", p["processor_config_restock_diff"])
	}
	if p["title"] != "[vbarzin] SD card" {
		t.Errorf("title %q", p["title"])
	}
	if strings.Contains(out.String(), "Keepa") {
		t.Errorf("a non-Amazon shop has no Keepa history:\n%s", out)
	}
}

func TestDealsAddRetriesWithBrowserThenDeletes(t *testing.T) {
	f := newFakeCD()
	f.results = []func(map[string]any){checkFails("no filters were found"), checkFails("Cloudflare challenge")}
	env, _ := testDealsEnv(t, f)
	err := env.add(dealsAddOpts{url: "https://shop.example.com/card"})
	if err == nil || !strings.Contains(err.Error(), "Cloudflare challenge") {
		t.Fatalf("want the last check error, got %v", err)
	}
	if len(f.puts) == 0 || f.puts[0]["fetch_backend"] != "html_webdriver" {
		t.Errorf("want one retry with the browser fetcher, puts %v", f.puts)
	}
	if len(f.deleted) != 1 {
		t.Errorf("a watch that never read a price must be deleted, deleted %v", f.deleted)
	}
}

func TestDealsAddBrowserRetrySucceeds(t *testing.T) {
	f := newFakeCD()
	f.results = []func(map[string]any){checkFails("no price"), priceFound(12.5)}
	env, out := testDealsEnv(t, f)
	if err := env.add(dealsAddOpts{url: "https://shop.example.com/card"}); err != nil {
		t.Fatalf("add: %v\n%s", err, out)
	}
	if len(f.deleted) != 0 {
		t.Error("watch deleted after the browser read the price")
	}
}

func TestDealsAddRefusesDuplicate(t *testing.T) {
	f := newFakeCD()
	f.watches["old"] = map[string]any{"title": "[emil.barzin] Card", "url": "https://www.amazon.co.uk/dp/B09X7FXHVJ"}
	env, _ := testDealsEnv(t, f)
	err := env.add(dealsAddOpts{url: "https://www.amazon.co.uk/Card/dp/B09X7FXHVJ/ref=x"})
	if err == nil || !strings.Contains(err.Error(), "[emil.barzin] Card") {
		t.Fatalf("want a duplicate error naming the watch, got %v", err)
	}
	if f.created != nil {
		t.Error("created a duplicate watch")
	}
}

func TestDealsListAndRemove(t *testing.T) {
	f := newFakeCD()
	f.watches["9deeea86-aaaa"] = map[string]any{
		"title": "[vbarzin] SD card", "url": "https://www.amazon.co.uk/dp/B09X7FXHVJ", "last_error": false,
		"last_checked":                  float64(time.Date(2026, 11, 17, 8, 0, 0, 0, time.UTC).Unix()),
		"processor_state_restock_diff":  map[string]any{"price": 35.67, "currency": "£"},
		"processor_config_restock_diff": map[string]any{"price_change_min": 35.67},
	}
	f.watches["9deeea86-bbbb"] = map[string]any{"title": "[emil.barzin] Filament", "url": "https://x.example/f", "last_error": "timeout"}
	env, out := testDealsEnv(t, f)
	if err := env.list(); err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{"[vbarzin] SD card", "£35.67", "2h ago", "timeout"} {
		if !strings.Contains(out.String(), s) {
			t.Errorf("list lacks %q:\n%s", s, out)
		}
	}
	if err := env.remove("9deeea86"); err == nil || !strings.Contains(err.Error(), "matches 2") {
		t.Errorf("ambiguous prefix: %v", err)
	}
	if err := env.remove("9deeea86-bb"); err != nil {
		t.Fatal(err)
	}
	if len(f.deleted) != 1 || f.deleted[0] != "9deeea86-bbbb" {
		t.Errorf("deleted %v", f.deleted)
	}
}

func TestKeepaChartSaved(t *testing.T) {
	var gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "image/png")
		io.WriteString(w, "\x89PNG fake")
	}))
	defer srv.Close()
	old := keepaGraphURL
	keepaGraphURL = srv.URL + "/pricehistory.png"
	defer func() { keepaGraphURL = old }()
	dir := t.TempDir()
	p, _, _ := dealsShopFor("https://www.amazon.de/dp/B09X7FXHVJ")
	path, err := saveKeepaChart(srv.Client(), dir, "B09X7FXHVJ", p)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(path) != dir || !strings.Contains(gotQuery, "domain=de") || !strings.Contains(gotQuery, "used=0") {
		t.Errorf("path %s query %s", path, gotQuery)
	}
	if b, _ := os.ReadFile(path); !bytes.HasPrefix(b, []byte("\x89PNG")) {
		t.Error("chart not written")
	}
}

func TestDealsRetarget(t *testing.T) {
	f := newFakeCD()
	f.watches["abc-1"] = map[string]any{"title": "[vbarzin] SD card", "url": "https://www.amazon.co.uk/dp/B09X7FXHVJ",
		"processor_state_restock_diff": map[string]any{"price": 35.67, "currency": "£"}}
	env, out := testDealsEnv(t, f)
	if err := env.retarget("abc", 25); err != nil {
		t.Fatal(err)
	}
	p := lastPut(f)
	if p["processor_config_restock_diff"].(map[string]any)["price_change_min"] != 25.0 ||
		!strings.Contains(p["notification_body"].(string), "target £25.00") {
		t.Errorf("put %v", p)
	}
	if !strings.Contains(out.String(), "below £25.00") {
		t.Errorf("out %s", out)
	}
}

func TestShortTitle(t *testing.T) {
	cases := map[string]string{
		"SanDisk Extreme PRO SDXC UHS-I 128 GB Memory Card: Amazon.de: Computer & Accessories": "SanDisk Extreme PRO SDXC UHS-I 128 GB Memory Card",
		"SanDisk 128GB Extreme PRO SDXC card, SD Card, V30":                                    "SanDisk 128GB Extreme PRO SDXC card",
		"": "fallback",
	}
	for in, want := range cases {
		if got := shortTitle(in, "fallback"); got != want {
			t.Errorf("%q -> %q, want %q", in, got, want)
		}
	}
}
