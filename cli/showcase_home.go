package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// The Home view (HL-05) shows the Sofia Home Assistant. It is a family
// system, so only counts and integration names leave the generator: no
// entity, room, area, person, automation or config-entry title reaches
// data.json. The design is in docs/plans/2026-10-20-homelab-showcase-design.md.

const (
	homeDocPath          = "docs/architecture/home-automation.md"
	defaultHASofiaURL    = "https://ha-sofia.viktorbarzin.me"
	defaultPublishedData = "https://pages.viktorbarzin.me/homelab/data.json"
)

type homeSection struct {
	Site         string            `json:"site"`
	AsOf         string            `json:"as_of"`
	Stale        bool              `json:"stale"`
	Version      string            `json:"version"`
	Counts       homeCounts        `json:"counts"`
	Kinds        []homeCount       `json:"kinds"`
	Security     homeSecurity      `json:"security"`
	Radios       []homeRadio       `json:"radios"`
	Automations  []homeCount       `json:"automations"`
	Integrations []homeIntegration `json:"integrations"`
	Highlights   []homeHighlight   `json:"highlights"`
}

type homeCounts struct {
	Devices          int `json:"devices"`
	Entities         int `json:"entities"`
	Integrations     int `json:"integrations"`
	IntegrationKinds int `json:"integration_kinds"`
	Automations      int `json:"automations"`
	Scripts          int `json:"scripts"`
	Dashboards       int `json:"dashboards"`
}

type homeCount struct {
	ID    string `json:"id"`
	Count int    `json:"count"`
}

type homeSecurity struct {
	Cameras     int `json:"cameras"`
	Locks       int `json:"locks"`
	AlarmPanels int `json:"alarm_panels"`
}

type homeRadio struct {
	ID      string `json:"id"`
	Devices int    `json:"devices"`
}

type homeIntegration struct {
	Domain  string `json:"domain"`
	Name    string `json:"name"`
	Devices int    `json:"devices"`
}

type homeHighlight struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Body  string `json:"body"`
	URL   string `json:"url"`
}

// haRaw is what the generator reads from Home Assistant before reducing it
// to counts.
type haRaw struct {
	Version    string
	States     []haState
	Entries    []haEntry
	Devices    []haDevice
	Dashboards int
}

type haState struct {
	EntityID   string         `json:"entity_id"`
	State      string         `json:"state"`
	Attributes map[string]any `json:"attributes"`
}

type haEntry struct {
	EntryID string `json:"entry_id"`
	Domain  string `json:"domain"`
	Title   string `json:"title"`
}

type haDevice struct {
	ConfigEntries      []string `json:"config_entries"`
	PrimaryConfigEntry string   `json:"primary_config_entry,omitempty"`
	DisabledBy         string   `json:"disabled_by,omitempty"`
}

// automationCategories classify automation aliases (English and Bulgarian)
// by what they do. First match wins, so the order matters: an "R730 PSU"
// rule is IT, not energy. The patterns key on device and function words,
// never on names.
var automationCategories = []struct {
	id string
	re *regexp.Regexp
}{
	{"climate", regexp.MustCompile(`(?i)→ cloud|: cloud |thermostat|термостат|ventilation|вентилац|PAX|климат`)},
	{"lighting", regexp.MustCompile(`(?i)^LED |light|освет|лампа`)},
	{"it", regexp.MustCompile(`(?i)R730|\bdisk\b|rpi-|server|сървър|шлюз|gateway|рака`)},
	{"energy", regexp.MustCompile(`(?i)\bATS\b|tariff|тариф|\bUPS\b|RCBO|price|\b230V\b|solar|inverter|електр|ток`)},
	{"security", regexp.MustCompile(`(?i)alarm|аларм|door|врата|lock|брава|camera|камер|license plate|person detection|\bPAI\b|house mode`)},
}

func automationCategory(alias string) string {
	for _, c := range automationCategories {
		if c.re.MatchString(alias) {
			return c.id
		}
	}
	return "other"
}

// homeHiddenDomains never appear by name: security kit (its brand would say
// how the house is protected), presence trackers, and Home Assistant's own
// helpers, which are not kit or services.
var homeHiddenDomains = map[string]bool{
	// security
	"hikvision_next": true, "hikvision": true, "frigate": true, "yale": true, "yalexs_ble": true, "august": true,
	"onvif": true, "generic": true, "go2rtc": true, "paradox": true, "reolink": true, "unifiprotect": true,
	"ring": true, "blink": true, "arlo": true, "alarmdecoder": true, "manual": true, "nest": true,
	// the only Matter device is the front door lock, so naming Matter names the lock
	"matter": true,
	// presence
	"mobile_app": true, "person": true, "zone": true, "ibeacon": true, "nmap_tracker": true, "ping": true,
	"device_tracker": true, "bluetooth_le_tracker": true, "private_ble_device": true, "glinet": true,
	// helpers and internals
	"template": true, "switch_as_x": true, "min_max": true, "utility_meter": true, "statistics": true,
	"sun": true, "backup": true, "hassio": true, "analytics": true, "spook": true, "hacs": true,
	"browser_mod": true, "radio_browser": true, "local_calendar": true, "derivative": true,
	"integration": true, "threshold": true, "trend": true, "group": true, "history_stats": true,
	"filter": true, "simple_pid_controller": true, "bluetooth": true, "met": true, "shopping_list": true,
	"upnp": true, "dlna_dms": true, "mass_queue": true, "androidtv_remote": true,
}

var homeSecurityWordRE = regexp.MustCompile(`(?i)alarm|camera|nvr|lock|paradox|frigate|hikvision|cctv|doorbell|intercom`)

func homeIntegrationHidden(domain string) bool {
	return homeHiddenDomains[domain] || homeSecurityWordRE.MatchString(domain)
}

// homeIntegrationNames gives display names for the integrations shown. An
// unknown domain falls back to title case; the config entry title is never
// used because users name entries after people and places.
var homeIntegrationNames = map[string]string{
	"tuya": "Tuya", "solarman": "Solarman", "forecast_solar": "Forecast.Solar", "hydrawise": "Hydrawise",
	"melcloud": "MELCloud", "home_connect": "Home Connect", "roomba": "iRobot Roomba", "braviatv": "Sony Bravia TV",
	"synology_dsm": "Synology DSM", "mqtt": "MQTT", "matter": "Matter", "esphome": "ESPHome",
	"ac_infinity": "AC Infinity", "music_assistant": "Music Assistant", "heos": "Denon HEOS", "cast": "Google Cast",
	"dlna_dmr": "DLNA renderer", "nut": "Network UPS Tools", "ookla_speedtest": "Speedtest",
	"open_meteo": "Open-Meteo", "edge_tts": "Edge TTS", "wyoming": "Wyoming voice", "open_router": "OpenRouter",
	"mcp_server": "MCP server", "denonavr": "Denon AVR", "pax_ble": "PAX fans", "ipp": "Printer (IPP)",
	"tplink": "TP-Link Kasa", "ecovacs": "Ecovacs", "prometheus": "Prometheus",
}

func homeIntegrationName(domain string) string {
	if n, ok := homeIntegrationNames[domain]; ok {
		return n
	}
	words := strings.Fields(strings.ReplaceAll(domain, "_", " "))
	for i, w := range words {
		r := []rune(w)
		r[0] = unicode.ToUpper(r[0])
		words[i] = string(r)
	}
	return strings.Join(words, " ")
}

// homeRadios classify a device by the integration that owns it. "cloud"
// covers Wi-Fi and LAN kit reached through its own network protocol or a
// vendor cloud.
var homeRadios = []struct {
	id      string
	domains []string
}{
	{"cloud", []string{"tuya", "tplink", "hydrawise", "melcloud", "home_connect", "roomba", "solarman", "braviatv",
		"denonavr", "heos", "cast", "dlna_dmr", "synology_dsm", "ipp", "ecovacs", "nut", "music_assistant"}},
	{"ble", []string{"pax_ble", "yalexs_ble", "ac_infinity", "switchbot", "govee_ble", "xiaomi_ble"}},
	{"matter", []string{"matter"}},
	{"esphome", []string{"esphome"}},
	{"mqtt", []string{"mqtt"}},
}

// buildHome reduces what HA returned to the counts the page shows.
func buildHome(raw haRaw, doc string, now time.Time) (*homeSection, error) {
	highlights, err := parseHighlights(doc, homeDocPath)
	if err != nil {
		return nil, err
	}
	h := &homeSection{
		Site:       "Sofia",
		AsOf:       now.UTC().Format(time.RFC3339),
		Version:    raw.Version,
		Highlights: highlights,
	}

	// Every state counts as an entity, unavailable ones included: they are
	// still configured, just not answering right now.
	h.Counts.Entities = len(raw.States)
	h.Counts.Dashboards = raw.Dashboards
	byDomain := map[string]int{}
	energy := 0
	autoCats := map[string]int{}
	for _, s := range raw.States {
		d, _, _ := strings.Cut(s.EntityID, ".")
		byDomain[d]++
		if d == "sensor" {
			switch s.Attributes["device_class"] {
			case "energy", "power", "gas":
				energy++
			}
		}
		if d == "automation" {
			name, _ := s.Attributes["friendly_name"].(string)
			autoCats[automationCategory(name)]++
		}
	}
	h.Counts.Automations = byDomain["automation"]
	h.Counts.Scripts = byDomain["script"]
	h.Kinds = []homeCount{
		{"lights", byDomain["light"]},
		{"climate", byDomain["climate"]},
		{"water", byDomain["valve"]},
		{"media", byDomain["media_player"]},
		{"switches", byDomain["switch"]},
		{"sensors", byDomain["sensor"] + byDomain["binary_sensor"]},
		{"energy", energy},
	}
	h.Security = homeSecurity{Cameras: byDomain["camera"], Locks: byDomain["lock"], AlarmPanels: byDomain["alarm_control_panel"]}
	for _, c := range []string{"climate", "energy", "lighting", "security", "it", "other"} {
		h.Automations = append(h.Automations, homeCount{c, autoCats[c]})
	}

	entryDomain := map[string]string{}
	kinds := map[string]bool{}
	for _, e := range raw.Entries {
		entryDomain[e.EntryID] = e.Domain
		kinds[e.Domain] = true
	}
	h.Counts.Integrations = len(raw.Entries)
	h.Counts.IntegrationKinds = len(kinds)

	// A device belongs to its primary config entry, or the first one listed.
	// Disabled devices are left out of every device count.
	devByDomain := map[string]int{}
	for _, d := range raw.Devices {
		if d.DisabledBy != "" {
			continue
		}
		h.Counts.Devices++
		id := d.PrimaryConfigEntry
		if id == "" && len(d.ConfigEntries) > 0 {
			id = d.ConfigEntries[0]
		}
		if dom := entryDomain[id]; dom != "" {
			devByDomain[dom]++
		}
	}
	for _, r := range homeRadios {
		n := 0
		for _, d := range r.domains {
			n += devByDomain[d]
		}
		h.Radios = append(h.Radios, homeRadio{r.id, n})
	}

	h.Integrations = []homeIntegration{}
	for d := range kinds {
		if homeIntegrationHidden(d) {
			continue
		}
		h.Integrations = append(h.Integrations, homeIntegration{Domain: d, Name: homeIntegrationName(d), Devices: devByDomain[d]})
	}
	sort.Slice(h.Integrations, func(i, j int) bool {
		a, b := h.Integrations[i], h.Integrations[j]
		if a.Devices != b.Devices {
			return a.Devices > b.Devices
		}
		return a.Name < b.Name
	})
	return h, nil
}

var (
	highlightRE   = regexp.MustCompile(`^<!--\s*showcase-highlight:\s*([a-z0-9-]+)\s*-->$`)
	mdLinkRE      = regexp.MustCompile(`\[([^\]]*)\]\([^)]*\)`)
	anchorStripRE = regexp.MustCompile(`[^\p{L}\p{N} _-]`)
	// a number standing on its own; digits inside a model name (R730, PSU2) are fine
	standaloneNumRE = regexp.MustCompile(`(?:^|[^\p{L}\p{N}])\p{N}`)
)

// parseHighlights takes every `## ` section of the home automation doc whose
// next line is a `<!-- showcase-highlight: id -->` marker. Like layer
// summaries, highlight text carries no numbers, so it cannot go stale beside
// the live counts; a model name such as R730 is not a number.
func parseHighlights(md, path string) ([]homeHighlight, error) {
	lines := strings.Split(md, "\n")
	var out []homeHighlight
	for i := 0; i < len(lines); i++ {
		if !strings.HasPrefix(lines[i], "## ") || i+1 >= len(lines) {
			continue
		}
		m := highlightRE.FindStringSubmatch(strings.TrimSpace(lines[i+1]))
		if m == nil {
			continue
		}
		title := strings.TrimSpace(strings.TrimPrefix(lines[i], "## "))
		var paras []string
		var cur []string
		flush := func() {
			if len(cur) > 0 {
				paras = append(paras, strings.Join(cur, " "))
				cur = nil
			}
		}
		j := i + 2
		for ; j < len(lines) && !strings.HasPrefix(lines[j], "#"); j++ {
			l := strings.TrimSpace(lines[j])
			if l == "" {
				flush()
				continue
			}
			cur = append(cur, plainMarkdown(l))
		}
		flush()
		i = j - 1
		body := strings.Join(paras, "\n\n")
		if body == "" {
			return nil, fmt.Errorf("%s: highlight %q has no text", path, m[1])
		}
		if standaloneNumRE.MatchString(title + "\n" + body) {
			return nil, fmt.Errorf("%s: highlight %q contains a number", path, m[1])
		}
		out = append(out, homeHighlight{ID: m[1], Title: title, Body: body, URL: githubInfraBlob + path + "#" + githubAnchor(title)})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%s: no <!-- showcase-highlight: ... --> sections", path)
	}
	return out, nil
}

func plainMarkdown(s string) string {
	s = mdLinkRE.ReplaceAllString(s, "$1")
	return strings.NewReplacer("**", "", "`", "", "__", "").Replace(s)
}

// githubAnchor is the id GitHub gives a heading: lower case, punctuation
// dropped, spaces to hyphens.
func githubAnchor(h string) string {
	return strings.ReplaceAll(anchorStripRE.ReplaceAllString(strings.ToLower(h), ""), " ", "-")
}

// fetchHA reads states over REST and the registries over the websocket API.
func fetchHA(ctx context.Context, base, token string) (haRaw, error) {
	var raw haRaw
	client := &http.Client{Timeout: 30 * time.Second}
	get := func(path string, v any) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+path, nil)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("GET %s: %s", path, resp.Status)
		}
		return json.NewDecoder(resp.Body).Decode(v)
	}
	var cfg struct {
		Version string `json:"version"`
	}
	if err := get("/api/config", &cfg); err != nil {
		return raw, err
	}
	raw.Version = cfg.Version
	if err := get("/api/states", &raw.States); err != nil {
		return raw, err
	}

	wsURL := "ws" + strings.TrimPrefix(base, "http") + "/api/websocket"
	c, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		return raw, fmt.Errorf("websocket: %w", err)
	}
	defer c.CloseNow()
	c.SetReadLimit(64 << 20)
	var msg struct {
		Type    string          `json:"type"`
		ID      int             `json:"id"`
		Success bool            `json:"success"`
		Result  json.RawMessage `json:"result"`
	}
	if err := wsjson.Read(ctx, c, &msg); err != nil {
		return raw, err
	}
	if err := wsjson.Write(ctx, c, map[string]string{"type": "auth", "access_token": token}); err != nil {
		return raw, err
	}
	if err := wsjson.Read(ctx, c, &msg); err != nil {
		return raw, err
	}
	if msg.Type != "auth_ok" {
		return raw, fmt.Errorf("websocket auth: %s", msg.Type)
	}
	call := func(id int, typ string, v any) error {
		if err := wsjson.Write(ctx, c, map[string]any{"id": id, "type": typ}); err != nil {
			return err
		}
		for {
			msg.Result = nil
			if err := wsjson.Read(ctx, c, &msg); err != nil {
				return err
			}
			if msg.ID != id {
				continue
			}
			if !msg.Success {
				return fmt.Errorf("%s failed", typ)
			}
			return json.Unmarshal(msg.Result, v)
		}
	}
	if err := call(1, "config_entries/get", &raw.Entries); err != nil {
		return raw, err
	}
	if err := call(2, "config/device_registry/list", &raw.Devices); err != nil {
		return raw, err
	}
	// The dashboards built in HA (the sidebar's own Overview is not counted).
	var dashes []json.RawMessage
	if err := call(3, "lovelace/dashboards/list", &dashes); err != nil {
		return raw, err
	}
	raw.Dashboards = len(dashes)
	return raw, nil
}

// haSofiaToken is HA_SOFIA_TOKEN (the pipeline's "showcase" token), else the
// admin token `homelab ha token --instance sofia` resolves, for local runs.
func haSofiaToken() (string, error) {
	if t := os.Getenv("HA_SOFIA_TOKEN"); t != "" {
		return t, nil
	}
	b64, err := kubectlCapture(haSecretNamespace, "get", "secret", haSecretName, "-o", "jsonpath={.data.sofia}")
	if err != nil {
		return "", fmt.Errorf("no HA_SOFIA_TOKEN and cannot read %s/%s: %w", haSecretNamespace, haSecretName, err)
	}
	return decodeSecretValue(b64)
}

// showcaseHome builds the Home section. Home Assistant being down does not
// fail the build: the last published section is reused and marked stale, or
// the section is left out when that is unavailable too. A broken highlights
// doc does fail it, because that is a repo problem.
func showcaseHome(src string) (*homeSection, error) {
	doc, err := os.ReadFile(filepath.Join(src, homeDocPath))
	if err != nil {
		return nil, err
	}
	if _, err := parseHighlights(string(doc), homeDocPath); err != nil {
		return nil, err
	}
	base := strings.TrimRight(firstEnv("HA_SOFIA_URL"), "/")
	if base == "" {
		base = defaultHASofiaURL
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	tok, err := haSofiaToken()
	if err == nil {
		var raw haRaw
		if raw, err = fetchHA(ctx, base, tok); err == nil {
			return buildHome(raw, string(doc), time.Now())
		}
	}
	fmt.Fprintf(os.Stderr, "showcase: home assistant unavailable (%v); reusing the published home section\n", err)
	prev, perr := publishedHome()
	if perr != nil {
		fmt.Fprintf(os.Stderr, "showcase: WARNING no home section this build: %v\n", perr)
		return nil, nil
	}
	prev.Stale = true
	return prev, nil
}

func publishedHome() (*homeSection, error) {
	u := firstEnv("SHOWCASE_PUBLISHED_DATA")
	if u == "" {
		u = defaultPublishedData
	}
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(u)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !strings.Contains(resp.Header.Get("Content-Type"), "json") {
		return nil, fmt.Errorf("%s: %s %s", u, resp.Status, resp.Header.Get("Content-Type"))
	}
	var snap struct {
		Home *homeSection `json:"home"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&snap); err != nil {
		return nil, err
	}
	if snap.Home == nil {
		return nil, fmt.Errorf("%s has no home section", u)
	}
	return snap.Home, nil
}
