package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// `showcase shots` captures the ha-sofia dashboards shown on the Showcase Home
// view, masks anything that says who lives there or how the house is secured,
// and writes the PNGs plus a manifest to a local folder for review. It never
// publishes: a person checks every image, and only approved ones are committed
// to showcase/web/home/ (design: docs/plans/2026-10-20-homelab-showcase-design.md).

// showcaseMaskJS runs in the dashboard page before each screenshot. It draws
// overlays rather than editing HA's DOM, so a re-render between masking and
// the capture cannot undo it. The words it redacts are built at runtime from
// hass.states and are never written anywhere.
//
//go:embed showcase_mask.js
var showcaseMaskJS string

// shotDashboard is one dashboard the Home view shows. URLPath is the ha-sofia
// url_path; TitleHint is a fallback match on the (Bulgarian) title in case the
// dashboard is ever recreated under a new path. Title and Caption are the
// English words the Home view shows under the (Bulgarian) screenshot.
type shotDashboard struct {
	ID        string
	URLPath   string
	TitleHint string
	Title     string
	Caption   string
}

var shotDashboards = []shotDashboard{
	{ID: "energy", URLPath: "el-energiia-i-zahranvane", TitleHint: "Енергия",
		Title: "Energy", Caption: "Mains, the UPS, the solar transfer switch and the inverter, with day and night tariffs."},
	{ID: "heating", URLPath: "otoplenie-i-klimat", TitleHint: "Отопление",
		Title: "Heating", Caption: "A thermostat per room, the air conditioner and the gas boiler."},
	{ID: "it", URLPath: "dashboard-it", TitleHint: "IT",
		Title: "IT", Caption: "The R730's temperatures and power, and the faceplate of the fan PID."},
}

// lovelaceDashboard is one row of the lovelace/dashboards/list reply.
type lovelaceDashboard struct {
	URLPath string `json:"url_path"`
	Title   string `json:"title"`
}

type shotOpts struct {
	Out        string
	Dashboards []string
}

func parseShotsArgs(args []string, now time.Time) (shotOpts, error) {
	o := shotOpts{Out: flagValue(args, "--out")}
	if o.Out == "" {
		o.Out = filepath.Join(os.TempDir(), "showcase-shots-"+now.UTC().Format("20060102-150405"))
	}
	ids := flagValue(args, "--dashboards")
	if ids == "" {
		for _, d := range shotDashboards {
			o.Dashboards = append(o.Dashboards, d.ID)
		}
		return o, nil
	}
	known := map[string]bool{}
	for _, d := range shotDashboards {
		known[d.ID] = true
	}
	for _, id := range strings.Split(ids, ",") {
		id = strings.TrimSpace(id)
		if !known[id] {
			return o, fmt.Errorf("unknown dashboard %q (want energy, heating or it)", id)
		}
		o.Dashboards = append(o.Dashboards, id)
	}
	return o, nil
}

// mapShotDashboards finds each wanted dashboard in the live list, by url_path
// first and by title second.
func mapShotDashboards(list []lovelaceDashboard, ids []string) (map[string]lovelaceDashboard, error) {
	out := map[string]lovelaceDashboard{}
	for _, id := range ids {
		var want shotDashboard
		for _, d := range shotDashboards {
			if d.ID == id {
				want = d
			}
		}
		found := false
		for _, l := range list {
			if l.URLPath == want.URLPath {
				out[id], found = l, true
				break
			}
		}
		for _, l := range list {
			if !found && want.TitleHint != "" && strings.Contains(l.Title, want.TitleHint) {
				out[id], found = l, true
			}
		}
		if !found {
			return nil, fmt.Errorf("dashboard %q not found on ha-sofia (looked for url_path %q or a title containing %q)", id, want.URLPath, want.TitleHint)
		}
	}
	return out, nil
}

// shotVariant is one capture of a dashboard: a width and a theme.
type shotVariant struct {
	Device string // desktop | phone
	Theme  string // light | dark
	Width  int64
	Scale  float64
}

var shotVariants = []shotVariant{
	{"desktop", "light", 1280, 1},
	{"desktop", "dark", 1280, 1},
	{"phone", "light", 390, 2},
	{"phone", "dark", 390, 2},
}

func shotFileName(id string, v shotVariant) string {
	return fmt.Sprintf("%s-%s-%s.png", id, v.Device, v.Theme)
}

// shotManifestEntry is written to manifest.json: what each image is and what
// was masked in it, as counts by reason (never the masked text itself).
// It is also the file the Home view reads once committed to showcase/web/home/,
// so Files holds paths relative to the page ("home/<name>").
type shotManifestEntry struct {
	ID      string                    `json:"id"`
	Title   string                    `json:"title"`
	Caption string                    `json:"caption"`
	HATitle string                    `json:"ha_title"`
	URLPath string                    `json:"url_path"`
	View    string                    `json:"view"`
	Files   map[string]string         `json:"files"`
	Masked  map[string]map[string]int `json:"masked"`
}

// resolveSofiaToken prefers HA_SOFIA_TOKEN and falls back to the same secret
// `homelab ha token --instance sofia` reads.
func resolveSofiaToken() (string, error) {
	if t := strings.TrimSpace(os.Getenv("HA_SOFIA_TOKEN")); t != "" {
		return t, nil
	}
	inst, err := resolveHAInstance("sofia")
	if err != nil {
		return "", err
	}
	b64, err := kubectlCapture(haSecretNamespace, "get", "secret", haSecretName, "-o", "jsonpath={.data."+inst.secretKey+"}")
	if err != nil || b64 == "" {
		return "", fmt.Errorf("no HA_SOFIA_TOKEN and cannot read %s/%s: %v", haSecretNamespace, haSecretName, err)
	}
	return decodeSecretValue(b64)
}

func sofiaBaseURL() string {
	if u := strings.TrimRight(os.Getenv("HA_SOFIA_URL"), "/"); u != "" {
		return u
	}
	return "https://ha-sofia.viktorbarzin.me"
}

// haWS runs a list of websocket commands after the auth handshake and returns
// each result in order.
func haWS(ctx context.Context, base, token string, cmds []map[string]any) ([]json.RawMessage, error) {
	wsURL := "wss://" + strings.TrimPrefix(base, "https://")
	if strings.HasPrefix(base, "http://") {
		wsURL = "ws://" + strings.TrimPrefix(base, "http://")
	}
	c, _, err := websocket.Dial(ctx, wsURL+"/api/websocket", nil)
	if err != nil {
		return nil, fmt.Errorf("HA websocket: %w", err)
	}
	defer c.CloseNow()
	c.SetReadLimit(64 << 20)
	var hello map[string]any
	if err := wsjson.Read(ctx, c, &hello); err != nil {
		return nil, err
	}
	if err := wsjson.Write(ctx, c, map[string]any{"type": "auth", "access_token": token}); err != nil {
		return nil, err
	}
	var auth struct{ Type string }
	if err := wsjson.Read(ctx, c, &auth); err != nil {
		return nil, err
	}
	if auth.Type != "auth_ok" {
		return nil, fmt.Errorf("HA websocket auth: %s", auth.Type)
	}
	var out []json.RawMessage
	for i, cmd := range cmds {
		cmd["id"] = i + 1
		if err := wsjson.Write(ctx, c, cmd); err != nil {
			return nil, err
		}
		for {
			var r struct {
				ID      int             `json:"id"`
				Type    string          `json:"type"`
				Success bool            `json:"success"`
				Result  json.RawMessage `json:"result"`
				Error   *struct{ Message string }
			}
			if err := wsjson.Read(ctx, c, &r); err != nil {
				return nil, err
			}
			if r.ID != i+1 || r.Type != "result" {
				continue
			}
			if !r.Success {
				msg := "failed"
				if r.Error != nil {
					msg = r.Error.Message
				}
				return nil, fmt.Errorf("HA %v: %s", cmd["type"], msg)
			}
			out = append(out, r.Result)
			break
		}
	}
	return out, nil
}

// showcaseShots is a read: it only reads ha-sofia (states, dashboards) and
// writes images to a local folder, like `showcase build` and `ha token`.
func showcaseShots(args []string) error {
	o, err := parseShotsArgs(args, time.Now())
	if err != nil {
		return err
	}
	token, err := resolveSofiaToken()
	if err != nil {
		return err
	}
	base := sofiaBaseURL()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	res, err := haWS(ctx, base, token, []map[string]any{{"type": "lovelace/dashboards/list"}})
	if err != nil {
		return err
	}
	var list []lovelaceDashboard
	if err := json.Unmarshal(res[0], &list); err != nil {
		return err
	}
	dash, err := mapShotDashboards(list, o.Dashboards)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(o.Out, 0o755); err != nil {
		return err
	}

	allocOpts := chromedp.DefaultExecAllocatorOptions[:]
	for _, p := range []string{"google-chrome", "chromium", "chromium-browser"} {
		if path, err := exec.LookPath(p); err == nil {
			allocOpts = append(allocOpts, chromedp.ExecPath(path))
			break
		}
	}
	allocCtx, cancelAlloc := chromedp.NewExecAllocator(ctx, allocOpts...)
	defer cancelAlloc()

	var manifest []shotManifestEntry
	for _, id := range o.Dashboards {
		d := dash[id]
		want := shotDashboardByID(id)
		cfgRes, err := haWS(ctx, base, token, []map[string]any{{"type": "lovelace/config", "url_path": d.URLPath}})
		if err != nil {
			return err
		}
		var cfg struct {
			Views []struct {
				Path string `json:"path"`
			} `json:"views"`
		}
		_ = json.Unmarshal(cfgRes[0], &cfg)
		view := "0"
		if len(cfg.Views) > 0 && cfg.Views[0].Path != "" {
			view = cfg.Views[0].Path
		}
		fmt.Printf("showcase shots: %s -> /%s/%s (%s)\n", id, d.URLPath, view, d.Title)

		e := shotManifestEntry{ID: id, Title: want.Title, Caption: want.Caption, HATitle: d.Title, URLPath: d.URLPath, View: view,
			Files: map[string]string{}, Masked: map[string]map[string]int{}}
		for _, v := range shotVariants {
			name := shotFileName(id, v)
			masked, err := captureDashboard(allocCtx, base, token, "/"+d.URLPath+"/"+view, v, filepath.Join(o.Out, name))
			if err != nil {
				// one retry: Chrome occasionally fails a load on a transient
				// network or certificate-verifier hiccup
				fmt.Printf("  %s: %v; retrying once\n", name, err)
				masked, err = captureDashboard(allocCtx, base, token, "/"+d.URLPath+"/"+view, v, filepath.Join(o.Out, name))
			}
			if err != nil {
				return fmt.Errorf("%s: %w", name, err)
			}
			e.Files[v.Device+"-"+v.Theme] = "home/" + name
			e.Masked[name] = masked
			fmt.Printf("  %s masked %s\n", name, formatMaskCounts(masked))
		}
		manifest = append(manifest, e)
	}
	b, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(o.Out, "manifest.json"), b, 0o644); err != nil {
		return err
	}
	fmt.Printf("showcase shots: %d images in %s; review every one before committing to showcase/web/home/\n", len(manifest)*len(shotVariants), o.Out)
	return nil
}

func formatMaskCounts(m map[string]int) string {
	if len(m) == 0 {
		return "nothing"
	}
	var parts []string
	for k, n := range m {
		parts = append(parts, fmt.Sprintf("%s=%d", k, n))
	}
	sort.Strings(parts)
	return strings.Join(parts, " ")
}

// readyJS reports whether the dashboard view has rendered its cards and no
// spinner is left, searching through shadow roots.
const readyJS = `(() => {
  const ha = document.querySelector('home-assistant');
  if (!ha || !ha.hass || !ha.hass.states) return false;
  let view = null, spinning = false, cards = 0;
  (function walk(root) {
    for (const el of root.querySelectorAll('*')) {
      const t = el.localName;
      if (t === 'hui-view' || t === 'hui-sections-view') view = el;
      if (t.endsWith('-card') && t !== 'ha-card') cards++;
      if ((t === 'ha-spinner' || t === 'ha-circular-progress' || t === 'hass-loading-screen') && el.getClientRects().length) spinning = true;
      if (el.shadowRoot) walk(el.shadowRoot);
    }
  })(document);
  return !!view && cards > 0 && !spinning;
})()`

// heightJS is the full height of the rendered view, so the viewport can be
// resized to show it whole in one screenshot.
const heightJS = `(() => {
  let h = document.scrollingElement ? document.scrollingElement.scrollHeight : 0;
  (function walk(root) {
    for (const el of root.querySelectorAll('*')) {
      if (el.scrollHeight > el.clientHeight + 20 && getComputedStyle(el).overflowY.match(/auto|scroll/)) {
        h = Math.max(h, el.scrollHeight + el.getBoundingClientRect().top);
      }
      if (el.shadowRoot) walk(el.shadowRoot);
    }
  })(document);
  return Math.ceil(h);
})()`

// hideIframesJS hides every iframe card together with the grid cell that
// holds it, and returns how many it hid.
const hideIframesJS = `(() => {
  let n = 0;
  (function walk(root) {
    for (const el of root.querySelectorAll('*')) {
      if (el.localName === 'hui-iframe-card') {
        // hui-iframe-card < hui-card < div.card, the grid cell that holds
        // the row span; hiding only the card would leave the space behind
        let cell = el;
        for (let p = el; p; p = p.parentNode || p.host) if (p.localName === 'hui-card') { cell = p; break; }
        if (cell.parentElement && cell.parentElement.classList.contains('card')) cell = cell.parentElement;
        cell.style.display = 'none';
        n++;
      }
      if (el.shadowRoot) walk(el.shadowRoot);
    }
  })(document);
  return n;
})()`

// unpinThemeJS removes the CSS custom properties a view-level theme sets
// inline (HA applies a theme as dozens of --vars on one element).
const unpinThemeJS = `(() => {
  let n = 0;
  (function walk(root) {
    for (const el of root.querySelectorAll('*')) {
      const st = el.style;
      if (st && st.length > 15) {
        const vars = [...st].filter((p) => p.startsWith('--'));
        if (vars.length > 15) { for (const p of vars) st.removeProperty(p); n++; }
      }
      if (el.shadowRoot) walk(el.shadowRoot);
    }
  })(document);
  return n;
})()`

func captureDashboard(allocCtx context.Context, base, token, path string, v shotVariant, file string) (map[string]int, error) {
	tab, cancel := chromedp.NewContext(allocCtx)
	defer cancel()
	tab, cancelT := context.WithTimeout(tab, 3*time.Minute)
	defer cancelT()

	storage := map[string]string{
		"hassTokens": mustJSON(map[string]any{
			"access_token": token, "token_type": "Bearer", "expires_in": 1800,
			"hassUrl": base, "clientId": base + "/", "expires": int64(4102444800000), "refresh_token": "",
		}),
		"dockedSidebar": mustJSON("always_hidden"),
		"selectedTheme": mustJSON(map[string]any{"theme": "default", "dark": v.Theme == "dark"}),
	}
	setStorage := "(() => {"
	for k, val := range storage {
		setStorage += fmt.Sprintf("localStorage.setItem(%s, %s);", mustJSON(k), mustJSON(val))
	}
	setStorage += "return true})()"

	viewport := func(h int64) chromedp.Action[chromedp.Void] {
		opts := []chromedp.EmulateViewportOption{chromedp.EmulateScale(v.Scale)}
		if v.Device == "phone" {
			opts = append(opts, chromedp.EmulateMobile, chromedp.EmulateTouch)
		}
		return chromedp.EmulateViewport(v.Width, h, opts...)
	}
	if err := chromedp.Do(tab, viewport(900), chromedp.Navigate(base+"/manifest.json")); err != nil {
		return nil, err
	}
	if _, err := chromedp.Run(tab, chromedp.Evaluate[bool](setStorage)); err != nil {
		return nil, fmt.Errorf("set localStorage: %w", err)
	}
	if err := chromedp.Do(tab, chromedp.Navigate(base+path)); err != nil {
		return nil, err
	}
	if _, err := chromedp.Run(tab, chromedp.Poll[bool](readyJS,
		chromedp.WithPollingInterval(500*time.Millisecond), chromedp.WithPollingTimeout(90*time.Second))); err != nil {
		return nil, fmt.Errorf("dashboard never finished rendering: %w", err)
	}
	// Charts (apexcharts, history graphs) load their data after the cards
	// render, and there is no event for "every chart has drawn".
	if err := chromedp.Do(tab, chromedp.Sleep(6*time.Second)); err != nil {
		return nil, err
	}
	// Embedded pages (Grafana iframes) need their own login and render
	// blank; drop their cards before measuring so the shot has no empty band.
	if _, err := chromedp.Run(tab, chromedp.Evaluate[int](hideIframesJS)); err != nil {
		return nil, err
	}
	height, err := chromedp.Run(tab, chromedp.Evaluate[int64](heightJS))
	if err != nil {
		return nil, err
	}
	if height < 900 {
		height = 900
	}
	if height > 12000 {
		height = 12000
	}
	if err := chromedp.Do(tab, viewport(height), chromedp.Sleep(2500*time.Millisecond)); err != nil {
		return nil, err
	}
	if v.Theme == "light" {
		// Some views pin a dark theme (Graphite). Dropping the theme's inline
		// variables lets the view inherit the light default, so the light
		// shot matches the page's light mode.
		if _, err := chromedp.Run(tab, chromedp.Evaluate[int](unpinThemeJS)); err != nil {
			return nil, err
		}
		if err := chromedp.Do(tab, chromedp.Sleep(1500*time.Millisecond)); err != nil {
			return nil, err
		}
	}
	maskOut, err := chromedp.Run(tab, chromedp.Evaluate[string](fmt.Sprintf("(%s)(%t)", strings.TrimSpace(showcaseMaskJS), v.Theme == "dark")))
	if err != nil {
		return nil, fmt.Errorf("mask script: %w", err)
	}
	png, err := chromedp.Run(tab, chromedp.CaptureScreenshot())
	if err != nil {
		return nil, err
	}
	var counts map[string]int
	if err := json.Unmarshal([]byte(maskOut), &counts); err != nil {
		return nil, fmt.Errorf("mask script: %v (%q)", err, maskOut)
	}
	if counts["_words"] == 0 {
		return nil, fmt.Errorf("mask script built no redaction words; refusing to write an unmasked image")
	}
	delete(counts, "_words")
	return counts, os.WriteFile(file, png, 0o644)
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// shotDashboardByID returns the known dashboard with that id; parseShotsArgs
// has already rejected unknown ids.
func shotDashboardByID(id string) shotDashboard {
	for _, d := range shotDashboards {
		if d.ID == id {
			return d
		}
	}
	return shotDashboard{ID: id}
}
