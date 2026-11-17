package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/klauspost/compress/zstd"
	"gopkg.in/yaml.v3"
)

// `homelab deals`: deal watches for anyone in the Authentik group "Deal
// Watchers". A deal watch is a changedetection.io restock_diff watch in the
// shared group "deals"; a price below its target posts one line to Slack
// #changenotifications. Runbook: docs/runbooks/deal-watches.md.

// dealsKeyPath holds a copy of changedetection's API key. wizard reads it
// through vault-admin, emo through projects-emo, any OIDC login in the
// "Deal Watchers" group through the deal-watchers policy (stacks/vault).
const dealsKeyPath = "secret/workstation/shared/deal-watches"

const dealsTag = "deals"

var (
	// changedetection's /api path on an internal-only host: home LANs only,
	// the API key is the gate (stacks/changedetection, module ingress_api).
	dealsAPIBase  = "https://changedetection-api.viktorbarzin.me/api/v1"
	keepaGraphURL = "https://graph.keepa.com/pricehistory.png"
	dealsHTTP     = &http.Client{Timeout: 30 * time.Second}
)

// amazonNewPriceXPath reads the price of a new item only. An Amazon page can
// carry a second corePrice block for a used offer; this skips every block
// inside a "used" row and takes the first one left.
const amazonNewPriceXPath = "xpath:(//div[@id='corePrice_feature_div'][not(ancestor::*[contains(@id,'used')])]//span[contains(@class,'apex-pricetopay-value')]/span[contains(@class,'a-offscreen')])[1]"

const dealsUserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0 Safari/537.36"

// dealsShop is what a shop needs on its watch. KeepaDomain is Keepa's site
// number (0: Keepa does not cover the shop).
type dealsShop struct {
	Name           string
	Symbol         string
	Headers        map[string]string
	IncludeFilters []string
	KeepaDomain    int
	KeepaGraph     string // the domain= value of Keepa's chart image
}

// Our egress is in Bulgaria, so each Amazon site gets its currency cookie
// and English, which keeps the decimal point a point.
var amazonShops = map[string]dealsShop{
	"amazon.co.uk": {Name: "amazon.co.uk", Symbol: "£", KeepaDomain: 2, KeepaGraph: "co.uk",
		Headers: map[string]string{"User-Agent": dealsUserAgent, "Accept-Language": "en-GB", "Cookie": "i18n-prefs=GBP; lc-acbuk=en_GB"}},
	"amazon.de": {Name: "amazon.de", Symbol: "€", KeepaDomain: 3, KeepaGraph: "de",
		Headers: map[string]string{"User-Agent": dealsUserAgent, "Accept-Language": "en-GB", "Cookie": "i18n-prefs=EUR; lc-acbde=en_GB"}},
}

var asinRe = regexp.MustCompile(`/(?:dp|gp/product|gp/aw/d)/([A-Z0-9]{10})(?:[/?#]|$)`)

// dealsShopFor picks the shop profile and the URL to watch. Amazon URLs are
// cut to /dp/<ASIN>, so two links to one product are the same watch.
func dealsShopFor(raw string) (dealsShop, string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return dealsShop{}, "", fmt.Errorf("%q is not a shop URL (want https://...)", raw)
	}
	host := strings.TrimPrefix(strings.ToLower(u.Hostname()), "www.")
	if shop, ok := amazonShops[host]; ok {
		m := asinRe.FindStringSubmatch(u.Path + "/")
		if m == nil {
			return dealsShop{}, "", fmt.Errorf("no product number (ASIN) in %s; use the product page link", raw)
		}
		shop.IncludeFilters = []string{amazonNewPriceXPath}
		return shop, "https://www." + host + "/dp/" + m[1], nil
	}
	return dealsShop{Name: "generic"}, u.String(), nil
}

func asinOf(canonical string) string {
	if m := asinRe.FindStringSubmatch(canonical + "/"); m != nil {
		return m[1]
	}
	return ""
}

// rosterAuthentikName maps an OS user to their Authentik short name from
// scripts/workstation/roster.yaml; "" when the user has no row.
func rosterAuthentikName(rosterYAML []byte, osUser string) string {
	var r struct {
		Users map[string]struct {
			AuthentikUser string `yaml:"authentik_user"`
		} `yaml:"users"`
	}
	if yaml.Unmarshal(rosterYAML, &r) != nil {
		return ""
	}
	return r.Users[osUser].AuthentikUser
}

func dealsRequester() string {
	name := os.Getenv("USER")
	if u, err := user.Current(); err == nil {
		name = u.Username
	}
	home, _ := os.UserHomeDir()
	if p, err := findInfraTool(home, "workstation/roster.yaml"); err == nil {
		if b, err := os.ReadFile(p); err == nil {
			if a := rosterAuthentikName(b, name); a != "" {
				return a
			}
		}
	}
	return name
}

// --- changedetection API --------------------------------------------------

type cdClient struct {
	base, key string
	http      *http.Client
}

func (c *cdClient) do(method, path string, body, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.base+"/"+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("x-api-key", c.key)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", homelabUserAgent())
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("changedetection %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode >= 300 {
		return fmt.Errorf("changedetection %s %s: HTTP %d: %.200s", method, path, resp.StatusCode, data)
	}
	if out != nil {
		return json.Unmarshal(data, out)
	}
	return nil
}

type cdWatch struct {
	UUID       string `json:"uuid"`
	Title      string `json:"title"`
	URL        string `json:"url"`
	PageTitle  string `json:"page_title"`
	LastError  any    `json:"last_error"` // false, or the error text
	Checked    int64  `json:"last_checked"`
	CheckCount int    `json:"check_count"`
	Backend    string `json:"fetch_backend"`
	State      struct {
		Price    *float64 `json:"price"`
		Currency string   `json:"currency"`
	} `json:"processor_state_restock_diff"`
	Config struct {
		Min *float64 `json:"price_change_min"`
	} `json:"processor_config_restock_diff"`
}

func (w cdWatch) errText() string {
	if s, ok := w.LastError.(string); ok {
		return s
	}
	return ""
}

func (c *cdClient) watch(uuid string) (cdWatch, error) {
	var w cdWatch
	err := c.do("GET", "watch/"+uuid, nil, &w)
	w.UUID = uuid
	return w, err
}

func (c *cdClient) dealWatches() ([]cdWatch, error) {
	var m map[string]cdWatch
	if err := c.do("GET", "watch?tag="+dealsTag, nil, &m); err != nil {
		return nil, err
	}
	var out []cdWatch
	for id, w := range m {
		w.UUID = id
		out = append(out, w)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Title < out[j].Title })
	return out, nil
}

func (c *cdClient) tagUUID(title string) (string, error) {
	var m map[string]struct {
		Title string `json:"title"`
	}
	if err := c.do("GET", "tags", nil, &m); err != nil {
		return "", err
	}
	for id, t := range m {
		if t.Title == title {
			return id, nil
		}
	}
	return "", fmt.Errorf("changedetection has no group %q; see docs/runbooks/deal-watches.md", title)
}

// --- Keepa price history ---------------------------------------------------

const keepaFramesMarker = "KEEPA_FRAMES "

type keepaLow struct {
	Label string
	Cents int64
	At    time.Time
}

type keepaHistory struct {
	CurrentCents int64
	Lows         []keepaLow
}

// keepaScript loads one Keepa product page in the cluster's real Chrome
// (Keepa blocks headless browsers) and returns the websocket frames, which
// carry the price history. One page load per call.
func keepaScript(asin string, domain int) string {
	return fmt.Sprintf(`const frames = [];
page.on('websocket', ws => ws.on('framereceived', f => {
  const p = f.payload;
  frames.push(typeof p === 'string' ? {t: 's', d: p} : {t: 'b', d: Buffer.from(p).toString('base64')});
}));
await page.goto('https://keepa.com/#!product/%d-%s', {waitUntil: 'domcontentloaded', timeout: 45000});
await solveCloudflare();
await page.waitForTimeout(12000);
return %q + JSON.stringify(frames);
`, domain, asin, keepaFramesMarker)
}

func keepaFetch(asin string, domain int) (*keepaHistory, error) {
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	f, err := os.CreateTemp("", "keepa-*.js")
	if err != nil {
		return nil, err
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(keepaScript(asin, domain)); err != nil {
		return nil, err
	}
	f.Close()
	out, err := exec.Command(self, "browser", "run", f.Name(), "--no-seed", "--timeout", "120").CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("browser run: %v: %.300s", err, out)
	}
	return keepaLowsFromOutput(string(out), asin, time.Now())
}

var zstdMagic = []byte{0x28, 0xb5, 0x2f, 0xfd}

// keepaLowsFromOutput finds the product frame in the browser output and
// returns the new-condition price lows. Keepa's csv[1] is the NEW series:
// pairs of (minutes since 2011-01-01, price in cents), -1 meaning no offer.
func keepaLowsFromOutput(out, asin string, now time.Time) (*keepaHistory, error) {
	i := strings.Index(out, keepaFramesMarker)
	if i < 0 {
		return nil, fmt.Errorf("Keepa returned no data (blocked or changed): %.200s", out)
	}
	line := out[i+len(keepaFramesMarker):]
	if j := strings.IndexByte(line, '\n'); j >= 0 {
		line = line[:j]
	}
	var frames []struct{ T, D string }
	if err := json.Unmarshal([]byte(line), &frames); err != nil {
		return nil, fmt.Errorf("Keepa frames: %w", err)
	}
	dec, _ := zstd.NewReader(nil)
	defer dec.Close()
	for _, fr := range frames {
		b := []byte(fr.D)
		if fr.T == "b" {
			raw, err := base64.StdEncoding.DecodeString(fr.D)
			if err != nil {
				continue
			}
			b = raw
		}
		if bytes.HasPrefix(b, zstdMagic) {
			plain, err := dec.DecodeAll(b, nil)
			if err != nil {
				continue
			}
			b = plain
		}
		var msg struct {
			BasicProducts []struct {
				Asin string    `json:"asin"`
				CSV  [][]int64 `json:"csv"`
			} `json:"basicProducts"`
		}
		if json.Unmarshal(b, &msg) != nil {
			continue
		}
		for _, p := range msg.BasicProducts {
			if p.Asin == asin && len(p.CSV) > 1 {
				return keepaLows(p.CSV[1], now)
			}
		}
	}
	return nil, fmt.Errorf("Keepa sent no price history for %s", asin)
}

func keepaLows(series []int64, now time.Time) (*keepaHistory, error) {
	epoch := time.Date(2011, 1, 1, 0, 0, 0, 0, time.UTC)
	type pt struct {
		at    time.Time
		cents int64
	}
	var pts []pt
	for i := 0; i+1 < len(series); i += 2 {
		if series[i+1] > 0 {
			pts = append(pts, pt{epoch.Add(time.Duration(series[i]) * time.Minute), series[i+1]})
		}
	}
	if len(pts) == 0 {
		return nil, fmt.Errorf("Keepa has no new-item prices")
	}
	h := &keepaHistory{}
	if last := series[len(series)-1]; last > 0 {
		h.CurrentCents = last
	}
	for _, w := range []struct {
		label string
		days  int
	}{{"90 days", 90}, {"365 days", 365}, {"all time", 0}} {
		var best *pt
		for k := range pts {
			if w.days > 0 && now.Sub(pts[k].at) > time.Duration(w.days)*24*time.Hour {
				continue
			}
			if best == nil || pts[k].cents < best.cents {
				best = &pts[k]
			}
		}
		if best != nil {
			h.Lows = append(h.Lows, keepaLow{w.label, best.cents, best.at})
		}
	}
	return h, nil
}

// saveKeepaChart saves Keepa's public chart image, the fallback when the
// numbers cannot be read. It needs no browser and no sign-in.
func saveKeepaChart(c *http.Client, dir, asin string, shop dealsShop) (string, error) {
	q := url.Values{"asin": {asin}, "domain": {shop.KeepaGraph}, "amazon": {"1"}, "new": {"1"},
		"used": {"0"}, "range": {"365"}, "width": {"900"}, "height": {"400"}}
	resp, err := c.Get(keepaGraphURL + "?" + q.Encode())
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "image/") {
		return "", fmt.Errorf("Keepa chart: HTTP %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(dir, fmt.Sprintf("keepa-%s-%s.png", asin, shop.KeepaGraph))
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 5<<20))
	return path, os.WriteFile(path, b, 0o644)
}

// --- the verbs ------------------------------------------------------------

type dealsEnv struct {
	api        *cdClient
	requester  string
	out        io.Writer
	now        func() time.Time
	poll, wait time.Duration
	keepa      func(asin string, domain int) (*keepaHistory, error)
	chart      func(asin string, shop dealsShop) (string, error)
}

type dealsAddOpts struct {
	url, name  string
	below      float64
	everyHours int
}

func money(symbol string, v float64) string { return fmt.Sprintf("%s%.2f", symbol, v) }

// shortTitle makes a watch name from the page title: up to the first comma,
// at most 70 characters.
func shortTitle(page, fallback string) string {
	t := strings.TrimSpace(page)
	if i := strings.IndexAny(t, ",|"); i > 0 {
		t = strings.TrimSpace(t[:i])
	}
	if r := []rune(t); len(r) > 70 {
		t = strings.TrimSpace(string(r[:70]))
	}
	if t == "" {
		return fallback
	}
	return t
}

// checkOnce asks for a check and waits until it has finished. It returns the
// watch as the check left it.
func (e *dealsEnv) checkOnce(uuid string) (cdWatch, error) {
	before, err := e.api.watch(uuid)
	if err != nil {
		return before, err
	}
	if err := e.api.do("GET", "watch/"+uuid+"?recheck=1", nil, nil); err != nil {
		return before, err
	}
	deadline := time.Now().Add(e.wait)
	for {
		w, err := e.api.watch(uuid)
		if err != nil {
			return w, err
		}
		if w.CheckCount > before.CheckCount && (w.State.Price != nil || w.errText() != "") {
			return w, nil
		}
		if time.Now().After(deadline) {
			if w.errText() == "" {
				w.LastError = fmt.Sprintf("no price after %s", e.wait)
			}
			return w, nil
		}
		time.Sleep(e.poll)
	}
}

func (e *dealsEnv) add(o dealsAddOpts) error {
	shop, target, err := dealsShopFor(o.url)
	if err != nil {
		return err
	}
	existing, err := e.api.dealWatches()
	if err != nil {
		return err
	}
	for _, w := range existing {
		if _, u, err := dealsShopFor(w.URL); err == nil && u == target {
			return fmt.Errorf("already watched: %s %s (homelab deals list)", w.UUID, w.Title)
		}
	}
	tag, err := e.api.tagUUID(dealsTag)
	if err != nil {
		return err
	}
	every := o.everyHours
	if every < 4 {
		every = 4 // every check is a request to someone else's shop
	}
	// Muted, with a target no price is below, until the first check has
	// read today's price: the setup itself must never post to Slack.
	create := map[string]any{
		"url":                target,
		"title":              fmt.Sprintf("[%s] %s", e.requester, shortTitle(o.name, target)),
		"processor":          "restock_diff",
		"tags":               []string{tag},
		"time_between_check": map[string]int{"hours": every},
		"notification_muted": true,
		"processor_config_restock_diff": map[string]any{
			"in_stock_processing": "off", "follow_price_changes": true, "price_change_min": 0.01,
		},
	}
	if shop.Headers != nil {
		create["headers"] = shop.Headers
	}
	if shop.IncludeFilters != nil {
		create["include_filters"] = shop.IncludeFilters
	}
	var made struct {
		UUID string `json:"uuid"`
	}
	if err := e.api.do("POST", "watch", create, &made); err != nil {
		return err
	}
	uuid := made.UUID
	fmt.Fprintf(e.out, "watch %s created, waiting for its first check...\n", uuid)

	w, err := e.checkOnce(uuid)
	if err == nil && w.State.Price == nil {
		fmt.Fprintf(e.out, "no price with a plain fetch (%s); trying the browser once\n", w.errText())
		if err = e.api.do("PUT", "watch/"+uuid, map[string]any{"fetch_backend": "html_webdriver"}, nil); err == nil {
			w, err = e.checkOnce(uuid)
		}
	}
	if err != nil || w.State.Price == nil {
		reason := w.errText()
		if err != nil {
			reason = err.Error()
		}
		if derr := e.api.do("DELETE", "watch/"+uuid, nil, nil); derr != nil {
			return fmt.Errorf("could not read a price (%s), and deleting watch %s failed: %v", reason, uuid, derr)
		}
		return fmt.Errorf("could not read a price from %s (%s); the watch was deleted. "+
			"This shop needs settings the command does not know: see docs/runbooks/deal-watches.md", target, reason)
	}

	symbol := w.State.Currency
	if shop.Symbol != "" {
		symbol = shop.Symbol
	}
	price := *w.State.Price
	goal := price
	if o.below > 0 {
		goal = o.below
	}
	title := fmt.Sprintf("[%s] %s", e.requester, shortTitle(o.name, shortTitle(w.PageTitle, target)))
	update := map[string]any{
		"title":              title,
		"notification_muted": false,
		"notification_title": "{{watch_title}}",
		"notification_body":  fmt.Sprintf("Now {{restock.currency}}{{restock.price}}, target %s. {{watch_url}}", money(symbol, goal)),
		"processor_config_restock_diff": map[string]any{
			"in_stock_processing": "off", "follow_price_changes": true, "price_change_min": goal,
		},
	}
	if err := e.api.do("PUT", "watch/"+uuid, update, nil); err != nil {
		return fmt.Errorf("watch %s read %s but setting its target failed: %w", uuid, money(symbol, price), err)
	}
	fmt.Fprintf(e.out, "watching %s\n  today %s, alert below %s, checked every %dh\n  Slack #changenotifications; id %s\n",
		title, money(symbol, price), money(symbol, goal), every, uuid)

	if shop.KeepaDomain != 0 && e.keepa != nil {
		asin := asinOf(target)
		h, kerr := e.keepa(asin, shop.KeepaDomain)
		if kerr == nil {
			fmt.Fprintf(e.out, "Keepa price history, new item:\n")
			for _, l := range h.Lows {
				fmt.Fprintf(e.out, "  %-9s low %s on %s\n", l.Label, money(symbol, float64(l.Cents)/100), l.At.Format("2006-01-02"))
			}
			fmt.Fprintf(e.out, "  pick a deeper target: homelab deals target %s <price>\n", uuid)
		} else if e.chart != nil {
			if path, cerr := e.chart(asin, shop); cerr == nil {
				fmt.Fprintf(e.out, "Keepa numbers unavailable (%v); its chart is at %s\n", kerr, path)
			} else {
				fmt.Fprintf(e.out, "no Keepa history: %v; chart: %v\n", kerr, cerr)
			}
		}
	}
	return nil
}

func agoString(now time.Time, unix int64) string {
	if unix == 0 {
		return "never"
	}
	d := now.Sub(time.Unix(unix, 0))
	switch {
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	}
	return fmt.Sprintf("%dd ago", int(d.Hours()/24))
}

func (e *dealsEnv) list() error {
	ws, err := e.api.dealWatches()
	if err != nil {
		return err
	}
	if len(ws) == 0 {
		fmt.Fprintln(e.out, "no deal watches")
		return nil
	}
	for _, s := range ws {
		w, err := e.api.watch(s.UUID)
		if err != nil {
			return err
		}
		price, goal := "-", "-"
		if w.State.Price != nil {
			price = money(w.State.Currency, *w.State.Price)
		}
		if w.Config.Min != nil {
			goal = money(w.State.Currency, *w.Config.Min)
		}
		status := "ok"
		if t := w.errText(); t != "" {
			status = "error: " + shortTitle(t, t)
		}
		fmt.Fprintf(e.out, "%s  %-8s below %-8s checked %-8s %s  %s\n  %s\n",
			w.UUID, price, goal, agoString(e.now(), w.Checked), status, w.Title, w.URL)
	}
	return nil
}

func (e *dealsEnv) find(arg string) (cdWatch, error) {
	ws, err := e.api.dealWatches()
	if err != nil {
		return cdWatch{}, err
	}
	var hits []cdWatch
	for _, w := range ws {
		if strings.HasPrefix(w.UUID, arg) || w.URL == arg {
			hits = append(hits, w)
		}
	}
	switch len(hits) {
	case 0:
		return cdWatch{}, fmt.Errorf("no deal watch matches %q (homelab deals list)", arg)
	case 1:
		return hits[0], nil
	}
	var names []string
	for _, h := range hits {
		names = append(names, h.UUID+" "+h.Title)
	}
	return cdWatch{}, fmt.Errorf("%q matches %d watches; give more of the id:\n  %s", arg, len(hits), strings.Join(names, "\n  "))
}

func (e *dealsEnv) remove(arg string) error {
	w, err := e.find(arg)
	if err != nil {
		return err
	}
	if err := e.api.do("DELETE", "watch/"+w.UUID, nil, nil); err != nil {
		return err
	}
	fmt.Fprintf(e.out, "removed %s\n", w.Title)
	return nil
}

func (e *dealsEnv) retarget(arg string, goal float64) error {
	w, err := e.find(arg)
	if err != nil {
		return err
	}
	full, err := e.api.watch(w.UUID)
	if err != nil {
		return err
	}
	symbol := full.State.Currency
	if shop, _, err := dealsShopFor(full.URL); err == nil && shop.Symbol != "" {
		symbol = shop.Symbol
	}
	update := map[string]any{
		"notification_body": fmt.Sprintf("Now {{restock.currency}}{{restock.price}}, target %s. {{watch_url}}", money(symbol, goal)),
		"processor_config_restock_diff": map[string]any{
			"in_stock_processing": "off", "follow_price_changes": true, "price_change_min": goal,
		},
	}
	if err := e.api.do("PUT", "watch/"+w.UUID, update, nil); err != nil {
		return err
	}
	fmt.Fprintf(e.out, "%s now alerts below %s\n", w.Title, money(symbol, goal))
	return nil
}

// --- wiring ---------------------------------------------------------------

func dealsCommands() []Command {
	return []Command{
		{Path: []string{"deals"}, Tier: TierRead,
			Summary: "price-drop deal watches on changedetection, posted to Slack (run `deals --help`)", Run: dealsTopHelp},
		{Path: []string{"deals", "add"}, Tier: TierWrite,
			Summary: "watch a product page: deals add <url> [--below PRICE] [--name NAME] [--every HOURS]", Run: dealsAdd},
		{Path: []string{"deals", "list"}, Tier: TierRead,
			Summary: "list every deal watch with its price, target and last check", Run: dealsList},
		{Path: []string{"deals", "target"}, Tier: TierWrite,
			Summary: "change a watch's target: deals target <id-prefix> <price>", Run: dealsTarget},
		{Path: []string{"deals", "remove"}, Tier: TierWrite,
			Summary: "delete a deal watch: deals remove <id-prefix|url>", Run: dealsRemove},
	}
}

func dealsTopHelp(args []string) error { fmt.Print(dealsHelp()); return nil }

func dealsHelp() string {
	return `homelab deals — tell me when a product gets cheaper

  deals add <url> [--below PRICE] [--name NAME] [--every HOURS]
        Watches the product page on changedetection. With no --below it alerts
        on any drop below today's price. The first check must read a price;
        if a plain fetch cannot, it tries the browser once, and if that fails
        too it deletes the watch and says why. Amazon (amazon.co.uk,
        amazon.de) reads the price of a NEW item only, and prints Keepa's
        price history lows to help pick a target. Checks every 4h at most.
  deals list                          every watch: price, target, last check, errors
  deals target <id-prefix> <price>    change a watch's target
  deals remove <id-prefix|url>        delete a watch (bought it, or no longer wanted)

One shared list for everyone in the Authentik group "Deal Watchers". Each
title starts with the requester's Authentik name. A drop posts one line to
Slack #changenotifications; a broken watch alerts in #alerts.
The API key is read from ` + dealsKeyPath + `.
Runbook: docs/runbooks/deal-watches.md
`
}

func dealsHelpWanted(args []string) bool {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			return true
		}
	}
	return false
}

func newDealsEnv() (*dealsEnv, error) {
	ensureVaultAddr()
	k, err := kvGetField(realRunner, dealsKeyPath, "api_key")
	if err != nil || strings.TrimSpace(k) == "" {
		return nil, fmt.Errorf("cannot read api_key from %s: %v\n"+
			"Access comes with the Authentik group \"Deal Watchers\" (OIDC logins) or the policy your devvm token\n"+
			"carries (vault-admin for wizard, projects-emo for emo) in stacks/vault/main.tf", dealsKeyPath, err)
	}
	cache, _ := os.UserCacheDir()
	chartDir := filepath.Join(cache, "homelab", "deals")
	return &dealsEnv{
		api:       &cdClient{base: dealsAPIBase, key: strings.TrimSpace(k), http: dealsHTTP},
		requester: dealsRequester(),
		out:       os.Stdout,
		now:       time.Now,
		poll:      3 * time.Second,
		wait:      150 * time.Second,
		keepa:     keepaFetch,
		chart: func(asin string, shop dealsShop) (string, error) {
			return saveKeepaChart(dealsHTTP, chartDir, asin, shop)
		},
	}, nil
}

func dealsAdd(args []string) error {
	if dealsHelpWanted(args) || len(args) == 0 {
		fmt.Print(dealsHelp())
		return nil
	}
	var o dealsAddOpts
	for i := 0; i < len(args); i++ {
		a := args[i]
		next := func() (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s needs a value", a)
			}
			i++
			return args[i], nil
		}
		switch a {
		case "--below":
			v, err := next()
			if err != nil {
				return err
			}
			f, err := strconv.ParseFloat(strings.TrimLeft(v, "£€$"), 64)
			if err != nil || f <= 0 {
				return fmt.Errorf("--below %q is not a price", v)
			}
			o.below = f
		case "--name":
			v, err := next()
			if err != nil {
				return err
			}
			o.name = v
		case "--every":
			v, err := next()
			if err != nil {
				return err
			}
			n, err := strconv.Atoi(strings.TrimSuffix(v, "h"))
			if err != nil {
				return fmt.Errorf("--every %q is not a number of hours", v)
			}
			o.everyHours = n
		default:
			if strings.HasPrefix(a, "-") || o.url != "" {
				return fmt.Errorf("unexpected argument %q (deals --help)", a)
			}
			o.url = a
		}
	}
	if o.url == "" {
		return fmt.Errorf("deals add needs a product URL")
	}
	env, err := newDealsEnv()
	if err != nil {
		return err
	}
	return env.add(o)
}

func dealsList(args []string) error {
	if dealsHelpWanted(args) {
		fmt.Print(dealsHelp())
		return nil
	}
	env, err := newDealsEnv()
	if err != nil {
		return err
	}
	return env.list()
}

func dealsTarget(args []string) error {
	if dealsHelpWanted(args) || len(args) != 2 {
		return fmt.Errorf("usage: homelab deals target <id-prefix> <price>")
	}
	f, err := strconv.ParseFloat(strings.TrimLeft(args[1], "£€$"), 64)
	if err != nil || f <= 0 {
		return fmt.Errorf("%q is not a price", args[1])
	}
	env, err := newDealsEnv()
	if err != nil {
		return err
	}
	return env.retarget(args[0], f)
}

func dealsRemove(args []string) error {
	if dealsHelpWanted(args) || len(args) != 1 {
		return fmt.Errorf("usage: homelab deals remove <id-prefix|url>")
	}
	env, err := newDealsEnv()
	if err != nil {
		return err
	}
	return env.remove(args[0])
}
