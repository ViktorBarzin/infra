// Package crowdsec_bouncer_plugin enforces CrowdSec ban decisions inside
// Traefik, as an entrypoint middleware on websecure.
//
// WHY IN-PROCESS. Every HTTP host in the zone is Cloudflare-proxied, so proxied
// traffic reaches Traefik from the in-cluster cloudflared pod: at L3 the node
// sees 10.10.x.x, which is why the nftables bouncer (cs-firewall-bouncer)
// protects almost no public web traffic and why enforcement was pushed to the
// Cloudflare edge instead. The Cloudflare Lists API turned out to enforce a hard
// 72-hour floor between successful item writes, which made the edge list
// disagree with CrowdSec for 107 of 216 observed hours. This plugin replaces
// that channel: decisions land here within one poll interval.
//
// Two properties are only available in-process, and both were fatal to a
// ForwardAuth design:
//
//   - Fail-open is structural. Traefik's forward.go returns 500/502 when an auth
//     backend is unreachable and offers no way to make that allow, which is why
//     auth-proxy and bot-block-proxy exist as shims. Here there is no backend to
//     be unreachable.
//   - The client IP cannot be spoofed. Traefik's forwardedheaders does not
//     manage Cf-Connecting-Ip, and a ForwardAuth backend always sees a Traefik
//     pod as its peer, so peer trust is unimplementable there. Here RemoteAddr
//     is the real TCP peer, so real-ip-plugin's trust model applies verbatim.
//
// CONSTRAINTS THIS FILE HONOURS. It runs under Yaegi, and one broken plugin
// disables ALL Traefik plugins at startup — api-token-middleware included, which
// would take paperless-mcp and repowise with it. So: standard library only, no
// generics, and nothing beyond the language and package surface already proven
// on this Traefik version by real-ip-plugin (net, net/http, strings) and
// sablier-plugin (encoding/json, goroutines, time.NewTicker, select).
//
// One Yaegi limit is not obvious and was found by interpreting this file under
// yaegi v0.16.1 (the version traefik v3.7.10 embeds): a VARIADIC func held in a
// STRUCT FIELD panics the interpreter at import time — `index out of range [2]
// with length 2` in callBin — which is the "Plugins are disabled" failure. The
// same signature is fine as a parameter or a package-level func; only the field
// breaks. Hence the log hook here is a non-variadic sink taking a finished
// line, with fmt.Sprintf at the call site. Keep it that way.
package crowdsec_bouncer_plugin

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// userAgent identifies this bouncer to LAPI. CrowdSec derives a bouncer row's
// `type` from the User-Agent, so this is what `cscli bouncers list` shows.
const userAgent = "crowdsec-traefik-bouncer/v0.1.0"

// defaultLapiURL is the in-cluster LAPI service. No NetworkPolicy stands
// between the traefik and crowdsec namespaces.
const defaultLapiURL = "http://crowdsec-service.crowdsec.svc.cluster.local:8080"

// defaultAppsecURL is the crowdsec chart's AppSec Service (release "crowdsec").
const defaultAppsecURL = "http://crowdsec-appsec-service.crowdsec.svc.cluster.local:7422"

// Config is the plugin configuration, supplied by the Middleware CRD.
type Config struct {
	// LapiURL is the CrowdSec LAPI base URL.
	LapiURL string `json:"lapiUrl,omitempty" yaml:"lapiUrl,omitempty"`
	// LapiKey is the bouncer API key, registered at LAPI startup via
	// BOUNCER_KEY_traefik. Without it LAPI answers 403 and the plugin would
	// fail open forever, so New refuses to start without one.
	LapiKey string `json:"lapiKey,omitempty" yaml:"lapiKey,omitempty"`
	// PollSeconds is how often the decision snapshot is refreshed.
	PollSeconds int `json:"pollSeconds,omitempty" yaml:"pollSeconds,omitempty"`
	// Origins lists the CrowdSec decision origins to ENFORCE. It is applied
	// twice: as LAPI's server-side `origins` filter (which is what keeps the
	// response at a few KB) and again locally when parsing, so a LAPI that
	// ignored the parameter cannot widen enforcement.
	//
	// CAPI is deliberately absent from the default. It is ~22.7k community
	// bans that have never been enforced on proxied hosts; its false positives
	// (CGNAT, carrier ranges) would surface as user-visible 403s, and it is
	// already enforced in-kernel on direct hosts by cs-firewall-bouncer. Adding
	// "CAPI" here turns it on — measure in dryRun first, and note that the
	// snapshot then weighs ~3 MB per poll instead of a few KB.
	//
	// An EMPTY list means no filter at all, i.e. every origin including CAPI.
	Origins []string `json:"origins,omitempty" yaml:"origins,omitempty"`
	// TrustedProxyCIDRs lists the peer networks (matched against the real TCP
	// peer, req.RemoteAddr) whose Cf-Connecting-Ip / X-Forwarded-For headers are
	// trusted. Any other peer is treated as the real client itself and all of
	// its forwarding headers are ignored — see clientIP.
	TrustedProxyCIDRs []string `json:"trustedProxyCIDRs,omitempty" yaml:"trustedProxyCIDRs,omitempty"`
	// SkipHosts are never gated. The Authentik hosts are carved out so that a
	// false-positive ban can never wall someone out of the login / WebAuthn
	// flow they would need in order to fix anything — the same carve-out the
	// Cloudflare WAF rule carried.
	SkipHosts []string `json:"skipHosts,omitempty" yaml:"skipHosts,omitempty"`
	// DryRun decides and logs, but always serves the request.
	DryRun bool `json:"dryRun,omitempty" yaml:"dryRun,omitempty"`
	// BanStatusCode and BanMessage are the response to a banned client.
	BanStatusCode int    `json:"banStatusCode,omitempty" yaml:"banStatusCode,omitempty"`
	BanMessage    string `json:"banMessage,omitempty" yaml:"banMessage,omitempty"`

	// AppsecEnabled turns on the AppSec check: each request that passes the
	// ban check is sent to the CrowdSec AppSec component before it reaches the
	// backend, and a 403 from AppSec blocks it (ADR-0027). Off by default, and
	// it is the kill switch: flipping it on the Middleware is a dynamic reload,
	// not a Traefik restart.
	AppsecEnabled bool `json:"appsecEnabled,omitempty" yaml:"appsecEnabled,omitempty"`
	// AppsecURL is the AppSec component's listen address.
	AppsecURL string `json:"appsecUrl,omitempty" yaml:"appsecUrl,omitempty"`
	// AppsecSkipHosts skip the AppSec check but keep ban enforcement. SkipHosts
	// above skip both.
	AppsecSkipHosts []string `json:"appsecSkipHosts,omitempty" yaml:"appsecSkipHosts,omitempty"`
	// AppsecTimeoutMs bounds one AppSec check. On expiry the request is allowed.
	AppsecTimeoutMs int `json:"appsecTimeoutMs,omitempty" yaml:"appsecTimeoutMs,omitempty"`
	// AppsecBodyLimit is the largest body sent to AppSec. See inspectBody for
	// the rest of the body policy; it is what keeps uploads streaming.
	AppsecBodyLimit int `json:"appsecBodyLimit,omitempty" yaml:"appsecBodyLimit,omitempty"`

	// DryRunOrigins are enforced origins whose decisions are logged as
	// dry-run-block instead of blocking. Used to roll a new origin out (CAPI,
	// 2026-10-02) without the global DryRun flag, which would stop every ban.
	// An IP banned by both a dry-run and an enforcing origin is blocked.
	DryRunOrigins []string `json:"dryRunOrigins,omitempty" yaml:"dryRunOrigins,omitempty"`

	// AppsecCrsURL is a second AppSec listener that adds the OWASP core rule
	// set, used for AppsecCrsHosts only. Every other inspected host keeps the
	// default listener (virtual patching and generic rules).
	AppsecCrsURL   string   `json:"appsecCrsUrl,omitempty" yaml:"appsecCrsUrl,omitempty"`
	AppsecCrsHosts []string `json:"appsecCrsHosts,omitempty" yaml:"appsecCrsHosts,omitempty"`
}

// CreateConfig returns the defaults. They are deliberately the safe end of every
// choice: dry run on, CAPI excluded, auth hosts carved out.
func CreateConfig() *Config {
	return &Config{
		LapiURL:           defaultLapiURL,
		PollSeconds:       30,
		Origins:           []string{"crowdsec", "cscli", "cscli-import", "lists", "console"},
		TrustedProxyCIDRs: []string{"10.10.0.0/16"},
		SkipHosts:         []string{"authentik.viktorbarzin.me", "public-auth.viktorbarzin.me"},
		DryRun:            true,
		BanStatusCode:     http.StatusForbidden,
		BanMessage:        "Forbidden\n",
		AppsecEnabled:     false,
		AppsecURL:         defaultAppsecURL,
		AppsecTimeoutMs:   200,
		AppsecBodyLimit:   65536,
	}
}

// decision is one LAPI decision. LAPI returns scope capitalised ("Ip"), so
// every comparison on these fields is case-insensitive.
type decision struct {
	Origin   string `json:"origin"`
	Scenario string `json:"scenario"`
	Scope    string `json:"scope"`
	Type     string `json:"type"`
	Value    string `json:"value"`
}

// decisionSet is an immutable snapshot of what to block. It is replaced
// wholesale on each successful poll, never mutated in place, so readers need no
// lock beyond fetching the current pointer.
type decisionSet struct {
	ips    map[string]banEntry
	ranges []rangeEntry
	loaded bool
}

// banEntry records whether a banned address is enforced or only dry-run, and
// the origin to name in the log line.
type banEntry struct {
	enforce bool
	origin  string
}

type rangeEntry struct {
	n       *net.IPNet
	enforce bool
	origin  string
}

func (d *decisionSet) size() int {
	if d == nil {
		return 0
	}
	return len(d.ips) + len(d.ranges)
}

func (d *decisionSet) dryRunCount() int {
	if d == nil {
		return 0
	}
	n := 0
	for _, e := range d.ips {
		if !e.enforce {
			n++
		}
	}
	for _, r := range d.ranges {
		if !r.enforce {
			n++
		}
	}
	return n
}

func (d *decisionSet) contains(ip net.IP) bool {
	found, _, _ := d.match(ip)
	return found
}

// match reports whether ip is banned, whether that ban is enforced (any
// enforcing decision wins over dry-run ones), and the origin to log.
func (d *decisionSet) match(ip net.IP) (bool, bool, string) {
	if d == nil || ip == nil {
		return false, false, ""
	}
	found, enforce, origin := false, false, ""
	if e, ok := d.ips[ip.String()]; ok {
		found, enforce, origin = true, e.enforce, e.origin
		if enforce {
			return true, true, origin
		}
	}
	for _, r := range d.ranges {
		if r.n.Contains(ip) {
			if r.enforce {
				return true, true, r.origin
			}
			if !found {
				found, origin = true, r.origin
			}
		}
	}
	return found, enforce, origin
}

// parseIP canonicalises an address so that textual variants of the same IPv6
// address compare equal.
func parseIP(s string) net.IP {
	return net.ParseIP(strings.TrimSpace(s))
}

// originSet lowercases an origin list into a lookup set. A nil/empty result
// means "no filtering".
func originSet(origins []string) map[string]struct{} {
	if len(origins) == 0 {
		return nil
	}
	out := map[string]struct{}{}
	for _, o := range origins {
		o = strings.ToLower(strings.TrimSpace(o))
		if o != "" {
			out[o] = struct{}{}
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// parseDecisions projects LAPI decisions into a lookup set.
//
// BAN ONLY. captcha must be ignored: the captcha_remediation profile diverts
// four false-positive-prone scenarios (http-429-abuse, http-403-abuse,
// http-crawl-non_statics, http-sensitive-files) to a captcha that is enforced
// nowhere. Honouring it here would turn all four into live fleet-wide blocks.
//
// Scope Ip and Range are both handled. Range is rare but real —
// default_range_remediation can emit it — and the Cloudflare sync it replaces
// only ever looked at scope=="ip", so a range decision silently did nothing.
// Any other scope (Country, AS, Username) is not something this middleware can
// evaluate, and is skipped.
func parseDecisions(decisions []decision, allowedOrigins map[string]struct{}) *decisionSet {
	return parseDecisionsDryRun(decisions, allowedOrigins, nil)
}

// parseDecisionsDryRun is parseDecisions with per-origin dry run: decisions
// from dryRunOrigins are kept but marked not enforced. When the same address
// is banned by an enforcing origin too, the enforcing ban wins regardless of
// order.
func parseDecisionsDryRun(decisions []decision, allowedOrigins, dryRunOrigins map[string]struct{}) *decisionSet {
	set := &decisionSet{ips: map[string]banEntry{}, loaded: true}
	for _, d := range decisions {
		if !strings.EqualFold(strings.TrimSpace(d.Type), "ban") {
			continue
		}
		origin := strings.ToLower(strings.TrimSpace(d.Origin))
		if allowedOrigins != nil {
			if _, ok := allowedOrigins[origin]; !ok {
				continue
			}
		}
		enforce := true
		if dryRunOrigins != nil {
			if _, dry := dryRunOrigins[origin]; dry {
				enforce = false
			}
		}
		value := strings.TrimSpace(d.Value)
		if value == "" {
			continue
		}
		logOrigin := strings.TrimSpace(d.Origin)
		switch strings.ToLower(strings.TrimSpace(d.Scope)) {
		case "ip":
			if ip := parseIP(value); ip != nil {
				key := ip.String()
				if prev, ok := set.ips[key]; ok && (prev.enforce || !enforce) {
					continue
				}
				set.ips[key] = banEntry{enforce: enforce, origin: logOrigin}
			}
		case "range":
			if _, n, err := net.ParseCIDR(value); err == nil {
				set.ranges = append(set.ranges, rangeEntry{n: n, enforce: enforce, origin: logOrigin})
			}
		}
	}
	return set
}

// store holds the current snapshot and is shared by every middleware instance
// built from the same poll configuration.
type store struct {
	mu   sync.RWMutex
	set  *decisionSet
	stop chan struct{}
	// dryRun holds the origins whose decisions are logged, not enforced. Set
	// once when the shared store is created; part of the registry key.
	dryRun map[string]struct{}
}

func (s *store) publish(set *decisionSet) {
	s.mu.Lock()
	s.set = set
	s.mu.Unlock()
}

func (s *store) snapshot() *decisionSet {
	s.mu.RLock()
	set := s.set
	s.mu.RUnlock()
	if set == nil {
		// Never loaded: an empty, not-loaded set, so the request path allows.
		return &decisionSet{}
	}
	return set
}

// refresh pulls the full decision snapshot and swaps it in.
//
// The full-snapshot endpoint is used rather than /v1/decisions/stream on
// purpose. The stream is a delta keyed on a per-bouncer last_pull that LAPI
// tracks per (key-name, source IP), so it would need startup/delta bookkeeping,
// would register a bouncer row per Traefik pod IP (the same leak that left 443
// stale kvsync@<podIP> rows behind), and would lose a cycle's deletions if a
// poll were missed. A snapshot is idempotent and self-healing, and with CAPI
// filtered out server-side it is a few KB.
//
// On ANY error the previous snapshot is left in place: fail open means "last
// known good", never "wipe the set" (which would un-ban everyone) and never
// "block everything".
func (s *store) refresh(client *http.Client, lapiURL, lapiKey string, origins []string,
	logf func(string)) error {
	endpoint := strings.TrimSuffix(lapiURL, "/") + "/v1/decisions"
	if len(origins) > 0 {
		endpoint += "?origins=" + url.QueryEscape(strings.Join(origins, ","))
	}

	req, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	req.Header.Set("X-Api-Key", lapiKey)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", userAgent)

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("lapi %s: unexpected status %d", endpoint, resp.StatusCode)
	}

	// LAPI answers a filter that matches nothing with literal `null`, not `[]`,
	// which unmarshals to a nil slice and correctly yields an empty set. An
	// empty set is a real state (every decision expired) and must clear the
	// previous one, otherwise bans would never lift.
	var decisions []decision
	if err := json.Unmarshal(body, &decisions); err != nil {
		return fmt.Errorf("lapi %s: %v", endpoint, err)
	}

	set := parseDecisionsDryRun(decisions, originSet(origins), s.dryRun)
	previous := s.snapshot()
	s.publish(set)
	if !previous.loaded || previous.size() != set.size() {
		logf(fmt.Sprintf("[crowdsec-bouncer] action=loaded entries=%d ips=%d ranges=%d dry-run=%d",
			set.size(), len(set.ips), len(set.ranges), set.dryRunCount()))
	}
	return nil
}

func (s *store) poll(client *http.Client, lapiURL, lapiKey string, origins []string,
	interval time.Duration, logf func(string)) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-ticker.C:
			if err := s.refresh(client, lapiURL, lapiKey, origins, logf); err != nil {
				// Fail open on the last known set. Logged every cycle on
				// purpose: silence is what made the Cloudflare sync's failure
				// invisible for weeks.
				logf(fmt.Sprintf("[crowdsec-bouncer] action=refresh-failed serving=last-known-set error=%v", err))
			}
		}
	}
}

// One poller per distinct poll configuration, shared by every middleware
// instance built from it. Traefik calls New again on every dynamic-config
// reload, and this package's interpreter outlives those reloads, so without
// this a busy day of ingress changes would leak a goroutine and a LAPI caller
// each time.
var (
	registryMu sync.Mutex
	registry   = map[string]*store{}
)

func registrySize() int {
	registryMu.Lock()
	defer registryMu.Unlock()
	return len(registry)
}

func resetRegistry() {
	registryMu.Lock()
	defer registryMu.Unlock()
	for k, s := range registry {
		close(s.stop)
		delete(registry, k)
	}
}

// sharedStore returns the store for this poll configuration, starting its
// poller on first use. A changed configuration supersedes the previous poller
// rather than adding to it.
func sharedStore(key string, start func(s *store)) *store {
	registryMu.Lock()
	defer registryMu.Unlock()

	if s, ok := registry[key]; ok {
		return s
	}
	for k, old := range registry {
		close(old.stop)
		delete(registry, k)
	}
	s := &store{stop: make(chan struct{})}
	registry[key] = s
	start(s)
	return s
}

// Bouncer is the middleware.
type Bouncer struct {
	next        http.Handler
	name        string
	trustedNets []*net.IPNet
	skipHosts   map[string]struct{}
	dryRun      bool
	statusCode  int
	banMessage  string
	store       *store
	// Deliberately NOT func(string, ...interface{}) — see the package doc: a
	// variadic func in a struct field panics Yaegi at import.
	logf func(string)

	appsecOn        bool
	appsecURL       string
	appsecKey       string
	appsecSkipHosts map[string]struct{}
	appsecClient    *http.Client
	appsecBodyLimit int64
	appsecCrsURL    string
	appsecCrsHosts  map[string]struct{}
	dryRunOrigins   map[string]struct{}
}

// newBouncer validates the configuration and builds the request-path state. It
// starts nothing, which is what makes the request path testable on its own.
func newBouncer(cfg *Config, next http.Handler, name string) (*Bouncer, error) {
	if cfg == nil {
		return nil, fmt.Errorf("crowdsec-bouncer: nil config")
	}

	var trustedNets []*net.IPNet
	for _, c := range cfg.TrustedProxyCIDRs {
		c = strings.TrimSpace(c)
		if c == "" {
			continue
		}
		// Fail loud on a malformed CIDR rather than silently narrowing or
		// widening who is allowed to name the client IP.
		_, ipNet, err := net.ParseCIDR(c)
		if err != nil {
			return nil, fmt.Errorf("crowdsec-bouncer: bad trustedProxyCIDRs entry %q: %v", c, err)
		}
		trustedNets = append(trustedNets, ipNet)
	}
	if len(trustedNets) == 0 {
		// Never become trust-everything or trust-nothing by accident: fall back
		// to the pod CIDR where cloudflared runs.
		_, ipNet, _ := net.ParseCIDR("10.10.0.0/16")
		trustedNets = append(trustedNets, ipNet)
	}

	skipHosts := map[string]struct{}{}
	for _, h := range cfg.SkipHosts {
		if h = normaliseHost(h); h != "" {
			skipHosts[h] = struct{}{}
		}
	}

	statusCode := cfg.BanStatusCode
	if statusCode == 0 {
		statusCode = http.StatusForbidden
	}

	// AppSec settings never make New fail. This middleware sits on the
	// websecure entrypoint, so an error here would make every router on the
	// entrypoint unresolvable; a bad AppSec setting turns AppSec off instead.
	appsecOn := cfg.AppsecEnabled
	appsecURL := strings.TrimSpace(cfg.AppsecURL)
	if appsecURL == "" {
		appsecURL = defaultAppsecURL
	}
	appsecKey := strings.TrimSpace(cfg.LapiKey)
	if appsecOn {
		u, err := url.Parse(appsecURL)
		if err != nil || u.Scheme == "" || u.Host == "" {
			stdoutLogf(fmt.Sprintf("[crowdsec-bouncer] action=appsec-disabled reason=bad-url url=%q", appsecURL))
			appsecOn = false
		} else if appsecKey == "" {
			stdoutLogf("[crowdsec-bouncer] action=appsec-disabled reason=no-api-key")
			appsecOn = false
		}
	}
	appsecSkipHosts := map[string]struct{}{}
	for _, h := range cfg.AppsecSkipHosts {
		if h = normaliseHost(h); h != "" {
			appsecSkipHosts[h] = struct{}{}
		}
	}
	timeout := time.Duration(cfg.AppsecTimeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 200 * time.Millisecond
	}
	bodyLimit := int64(cfg.AppsecBodyLimit)
	if bodyLimit <= 0 {
		bodyLimit = 65536
	}
	appsecCrsURL := strings.TrimSpace(cfg.AppsecCrsURL)
	if appsecCrsURL != "" {
		if u, err := url.Parse(appsecCrsURL); err != nil || u.Scheme == "" || u.Host == "" {
			stdoutLogf(fmt.Sprintf("[crowdsec-bouncer] action=appsec-crs-disabled reason=bad-url url=%q", appsecCrsURL))
			appsecCrsURL = ""
		}
	}
	appsecCrsHosts := map[string]struct{}{}
	for _, h := range cfg.AppsecCrsHosts {
		if h = normaliseHost(h); h != "" {
			appsecCrsHosts[h] = struct{}{}
		}
	}

	return &Bouncer{
		next:            next,
		name:            name,
		trustedNets:     trustedNets,
		skipHosts:       skipHosts,
		dryRun:          cfg.DryRun,
		statusCode:      statusCode,
		banMessage:      cfg.BanMessage,
		logf:            stdoutLogf,
		store:           &store{},
		appsecOn:        appsecOn,
		appsecURL:       appsecURL,
		appsecKey:       appsecKey,
		appsecSkipHosts: appsecSkipHosts,
		appsecClient:    sharedAppsecClient(timeout),
		appsecBodyLimit: bodyLimit,
		appsecCrsURL:    appsecCrsURL,
		appsecCrsHosts:  appsecCrsHosts,
		dryRunOrigins:   originSet(cfg.DryRunOrigins),
	}, nil
}

// New builds the middleware and attaches it to a shared LAPI poller.
func New(ctx context.Context, next http.Handler, cfg *Config, name string) (http.Handler, error) {
	b, err := newBouncer(cfg, next, name)
	if err != nil {
		return nil, err
	}

	lapiURL := strings.TrimSpace(cfg.LapiURL)
	if lapiURL == "" {
		lapiURL = defaultLapiURL
	}
	lapiKey := strings.TrimSpace(cfg.LapiKey)
	if lapiKey == "" {
		// Without a key LAPI answers 403 and the plugin would fail open
		// forever while looking healthy. Refuse instead.
		return nil, fmt.Errorf("crowdsec-bouncer: lapiKey is required")
	}
	interval := time.Duration(cfg.PollSeconds) * time.Second
	if interval <= 0 {
		interval = 30 * time.Second
	}
	origins := cfg.Origins

	// Timeout well inside the poll interval so a stalled LAPI cannot pile
	// requests up; the deadline covers the whole exchange, body included.
	client := &http.Client{Timeout: 10 * time.Second}

	key := lapiURL + "\x00" + lapiKey + "\x00" + strings.Join(origins, ",") + "\x00" + strconv.Itoa(int(interval/time.Second)) +
		"\x00" + strings.Join(cfg.DryRunOrigins, ",")
	b.store = sharedStore(key, func(s *store) {
		s.dryRun = b.dryRunOrigins
		// Logged HERE, not once per New(): Traefik rebuilds the middleware chain
		// on every dynamic-config reload, which on this cluster is ~285 times an
		// hour — a per-New() line was pure noise, and it is also the reason the
		// poller is shared rather than started per instance.
		b.logf(fmt.Sprintf("[crowdsec-bouncer] action=started name=%s lapi=%s interval=%s dryRun=%t origins=%s dryRunOrigins=%s skipHosts=%d appsec=%t appsecSkipHosts=%d appsecCrsHosts=%d",
			name, lapiURL, interval, b.dryRun, strings.Join(origins, ","), strings.Join(cfg.DryRunOrigins, ","), len(b.skipHosts), b.appsecOn, len(b.appsecSkipHosts), len(b.appsecCrsHosts)))
		// Load once synchronously so the first request through a fresh Traefik
		// pod is already enforced instead of failing open for a whole interval.
		if err := s.refresh(client, lapiURL, lapiKey, origins, b.logf); err != nil {
			b.logf(fmt.Sprintf("[crowdsec-bouncer] action=initial-load-failed allowing-all-until-first-success error=%v", err))
		}
		go s.poll(client, lapiURL, lapiKey, origins, interval, b.logf)
	})
	return b, nil
}

// stdoutLogf is the production sink. Traefik's own log and the JSON access log
// already share this stream, so an extra non-JSON line is business as usual:
// the CrowdSec traefik-logs parser tries a CLF grok, then a JSON node, and
// leaves anything matching neither unparsed. The Loki alerts that read these
// lines (CrowdSecL7BouncerRefreshFailing, CrowdSecL7BlockBurst) match on the
// "[crowdsec-bouncer] action=" prefix, not on the access-log format, so they
// were unaffected by the 2026-09-01 CLF-to-JSON switch.
func stdoutLogf(line string) {
	fmt.Fprintln(os.Stdout, line)
}

// normaliseHost strips the port, a trailing root dot and case, so the carve-out
// matches however the client wrote the Host header.
func normaliseHost(host string) string {
	host = strings.TrimSpace(host)
	if host == "" {
		return ""
	}
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.TrimSuffix(host, ".")
	return strings.ToLower(strings.Trim(host, "[]"))
}

// clientIP derives the address to judge from the unspoofable TCP peer.
//
// This is real-ip-plugin's model, and it is the reason this check belongs
// in-process. The origin is reachable without passing through Cloudflare (WAN
// :443 NATs straight to Traefik), so a banned client can connect directly and
// send whatever Cf-Connecting-Ip it likes. Only when the peer is itself a
// trusted in-cluster proxy (cloudflared) are those headers worth reading.
func (b *Bouncer) clientIP(req *http.Request) net.IP {
	host, _, err := net.SplitHostPort(req.RemoteAddr)
	if err != nil {
		host = req.RemoteAddr
	}
	peerIP := parseIP(host)
	if peerIP == nil {
		return nil
	}

	trusted := false
	for _, n := range b.trustedNets {
		if n.Contains(peerIP) {
			trusted = true
			break
		}
	}
	if !trusted {
		// The peer IS the client (direct WAN, or pfSense PROXY-v2 having
		// rewritten RemoteAddr). Ignore every client-supplied header.
		return peerIP
	}

	if cf := parseIP(req.Header.Get("Cf-Connecting-Ip")); isPublic(cf) {
		return cf
	}
	for _, part := range strings.Split(strings.Join(req.Header.Values("X-Forwarded-For"), ","), ",") {
		if ip := parseIP(part); isPublic(ip) {
			return ip
		}
	}
	// A trusted proxy that named nobody: judge it on itself.
	return peerIP
}

// isPublic keeps private, loopback and CGNAT addresses from being read out of a
// forwarding header as if they were the client.
func isPublic(ip net.IP) bool {
	if ip == nil || !ip.IsGlobalUnicast() || ip.IsPrivate() {
		return false
	}
	if p4 := ip.To4(); p4 != nil && p4[0] == 100 && p4[1]&0xC0 == 64 {
		return false
	}
	return true
}

func (b *Bouncer) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	host := normaliseHost(req.Host)
	if _, skip := b.skipHosts[host]; skip {
		b.next.ServeHTTP(rw, req)
		return
	}

	// A never-loaded set contains nothing, so the ban check below allows until
	// the first successful poll. Fail open.
	set := b.store.snapshot()
	ip := b.clientIP(req)
	found, enforce, origin := false, false, ""
	if set.loaded && ip != nil {
		found, enforce, origin = set.match(ip)
	}
	if found {
		// Only decisions are logged, never allowed requests — at ~10 req/s
		// steady state and 64 req/s peak, logging every request would dwarf the
		// signal. These lines are the alerting surface: Prometheus counters are
		// not cheaply available inside Yaegi, so the Loki recording/alert rules
		// read this.
		// Global dryRun, or a ban that only a dry-run origin holds: log and serve.
		if b.dryRun || !enforce {
			b.logf(fmt.Sprintf("[crowdsec-bouncer] action=dry-run-block ip=%s host=%s method=%s path=%s origin=%s",
				ip, host, req.Method, req.URL.Path, origin))
			b.next.ServeHTTP(rw, req)
			return
		}
		b.logf(fmt.Sprintf("[crowdsec-bouncer] action=block ip=%s host=%s method=%s path=%s status=%d origin=%s",
			ip, host, req.Method, req.URL.Path, b.statusCode, origin))
		b.deny(rw)
		return
	}

	if b.appsecOn {
		if _, skip := b.appsecSkipHosts[host]; !skip {
			if b.appsecCheck(rw, req, ip, host) {
				return
			}
		}
	}
	b.next.ServeHTTP(rw, req)
}

func (b *Bouncer) deny(rw http.ResponseWriter) {
	rw.Header().Set("Content-Type", "text/plain; charset=utf-8")
	rw.WriteHeader(b.statusCode)
	if b.banMessage != "" {
		fmt.Fprint(rw, b.banMessage)
	}
}

// ---------------------------------------------------------------------------
// AppSec check (ADR-0027)
// ---------------------------------------------------------------------------

// appsecCheck asks the AppSec component about one request. It returns true
// when it has written the response (a block, or a 400 for a body the client
// failed to deliver) and false when the request should continue to the backend.
//
// Everything except an explicit 403 from AppSec allows: 401 (a fresh AppSec pod
// whose LAPI is unreachable answers that to everything), 5xx, timeouts and
// connection errors all fail open and count against the breaker.
//
// The ResponseWriter is never wrapped, so websockets (Hijacker), SSE and
// streamed responses (Flusher) behave exactly as without this check.
func (b *Bouncer) appsecCheck(rw http.ResponseWriter, req *http.Request, ip net.IP, host string) bool {
	// Hosts without Authentik go to the listener that adds the OWASP core rule
	// set; every other inspected host gets virtual patching and generic rules.
	target, ruleset := b.appsecURL, "default"
	if b.appsecCrsURL != "" {
		if _, crs := b.appsecCrsHosts[host]; crs {
			target, ruleset = b.appsecCrsURL, "crs"
		}
	}
	breaker := currentBreaker(target)
	if !breaker.allow(time.Now(), b.logf) {
		return false
	}

	var body []byte
	if inspectBody(req, b.appsecBodyLimit) {
		// Bounded by Go's own enforcement of Content-Length (at most limit
		// bytes), and grown as bytes arrive rather than pre-allocated from the
		// declared length, so a client that declares 64 KiB and sends nothing
		// pins no memory.
		data, err := io.ReadAll(io.LimitReader(req.Body, b.appsecBodyLimit+1))
		if err != nil {
			// The client did not deliver the body it declared. Passing a
			// truncated body on would be worse than refusing it.
			rw.Header().Set("Content-Type", "text/plain; charset=utf-8")
			rw.WriteHeader(http.StatusBadRequest)
			fmt.Fprint(rw, "Bad Request\n")
			return true
		}
		req.Body = &replayBody{r: bytes.NewReader(data), closer: req.Body}
		body = data
	}

	status, err := b.callAppsec(req, ip, body, target)
	if err != nil || (status != http.StatusOK && status != http.StatusForbidden) {
		breaker.record(true, time.Now(), b.logf)
		return false
	}
	breaker.record(false, time.Now(), b.logf)
	if status != http.StatusForbidden {
		return false
	}
	b.logf(fmt.Sprintf("[crowdsec-bouncer] action=appsec-block ip=%s host=%s method=%s path=%s status=%d ruleset=%s",
		ip, host, req.Method, req.URL.Path, b.statusCode, ruleset))
	b.deny(rw)
	return true
}

// inspectBody is the body policy, and the reason an upload is never held at
// the ingress: only a short text body whose length Go has already parsed is
// read. Chunked or unknown-length bodies (ContentLength -1), multipart,
// octet-stream and media uploads, compressed bodies, and anything over the
// limit are inspected on method, URI and headers only, and their bodies reach
// the backend untouched. ContentLength is Go's parsed value, never the header.
func inspectBody(req *http.Request, limit int64) bool {
	if req.Body == nil || req.ContentLength <= 0 || req.ContentLength > limit {
		return false
	}
	if ce := strings.TrimSpace(req.Header.Get("Content-Encoding")); ce != "" && !strings.EqualFold(ce, "identity") {
		return false
	}
	return inspectableMediaType(req.Header.Get("Content-Type"))
}

// inspectableMediaType reports whether a Content-Type is form, JSON or XML.
func inspectableMediaType(contentType string) bool {
	if strings.TrimSpace(contentType) == "" {
		return false
	}
	mediaType, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		return false
	}
	switch mediaType {
	case "application/x-www-form-urlencoded", "application/json", "application/xml", "text/xml":
		return true
	}
	return strings.HasSuffix(mediaType, "+json") || strings.HasSuffix(mediaType, "+xml")
}

// replayBody hands the backend the bytes already read for inspection and still
// closes the original body.
type replayBody struct {
	r      *bytes.Reader
	closer io.Closer
}

func (rb *replayBody) Read(p []byte) (int, error) { return rb.r.Read(p) }

func (rb *replayBody) Close() error { return rb.closer.Close() }

// appsecDropHeaders are not forwarded to AppSec: hop-by-hop headers, and the
// framing headers that belong to the original connection.
var appsecDropHeaders = map[string]struct{}{
	"Connection":        {},
	"Keep-Alive":        {},
	"Proxy-Connection":  {},
	"Te":                {},
	"Trailer":           {},
	"Transfer-Encoding": {},
	"Upgrade":           {},
	"Expect":            {},
	"Content-Length":    {},
}

// callAppsec sends one check using the AppSec remediation protocol: GET when no
// body is forwarded, POST with the body otherwise, the original headers, and
// the X-Crowdsec-Appsec-* headers describing the original request.
func (b *Bouncer) callAppsec(req *http.Request, ip net.IP, body []byte, target string) (int, error) {
	method := http.MethodGet
	var payload io.Reader
	if body != nil {
		method = http.MethodPost
		payload = bytes.NewReader(body)
	}
	out, err := http.NewRequest(method, target, payload)
	if err != nil {
		return 0, err
	}

	connectionListed := map[string]struct{}{}
	for _, v := range req.Header.Values("Connection") {
		for _, name := range strings.Split(v, ",") {
			if name = strings.TrimSpace(name); name != "" {
				connectionListed[http.CanonicalHeaderKey(name)] = struct{}{}
			}
		}
	}
	for k, vs := range req.Header {
		ck := http.CanonicalHeaderKey(k)
		if _, drop := appsecDropHeaders[ck]; drop {
			continue
		}
		if _, drop := connectionListed[ck]; drop {
			continue
		}
		// A client must not be able to name its own IP, key or verb to AppSec.
		if strings.HasPrefix(ck, "X-Crowdsec-Appsec-") {
			continue
		}
		for _, v := range vs {
			out.Header.Add(ck, v)
		}
	}

	uri := req.RequestURI
	if !strings.HasPrefix(uri, "/") {
		uri = req.URL.RequestURI()
	}
	ipText := ""
	if ip != nil {
		ipText = ip.String()
	}
	out.Header.Set("X-Crowdsec-Appsec-Ip", ipText)
	out.Header.Set("X-Crowdsec-Appsec-Uri", uri)
	out.Header.Set("X-Crowdsec-Appsec-Host", req.Host)
	out.Header.Set("X-Crowdsec-Appsec-Verb", req.Method)
	out.Header.Set("X-Crowdsec-Appsec-Api-Key", b.appsecKey)
	out.Header.Set("X-Crowdsec-Appsec-User-Agent", req.UserAgent())
	out.Header.Set("X-Crowdsec-Appsec-Http-Version", strconv.Itoa(req.ProtoMajor*10+req.ProtoMinor))

	resp, err := b.appsecClient.Do(out)
	if err != nil {
		return 0, err
	}
	// Drain a little so the keep-alive connection can be reused.
	io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	resp.Body.Close()
	return resp.StatusCode, nil
}

// One HTTP client per timeout, shared by every middleware instance. Traefik
// rebuilds middlewares on every config reload (~285 times an hour), and a
// Transport per instance would leak its idle connections each time.
var (
	appsecClientMu sync.Mutex
	appsecClients  = map[time.Duration]*http.Client{}
)

func sharedAppsecClient(timeout time.Duration) *http.Client {
	appsecClientMu.Lock()
	defer appsecClientMu.Unlock()
	if c, ok := appsecClients[timeout]; ok {
		return c
	}
	c := &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			MaxIdleConns:        128,
			MaxIdleConnsPerHost: 64,
			IdleConnTimeout:     90 * time.Second,
			DisableCompression:  true,
		},
	}
	appsecClients[timeout] = c
	return c
}

// The circuit breaker stops AppSec checks for breakerOpenFor once at least
// half of the last breakerWindow checks failed, so an AppSec outage costs each
// request nothing instead of a full timeout. It is package-level for the same
// reason as the client: per-instance state would reset on every reload. Only
// state changes are logged.
const breakerWindow = 20

var breakerOpenFor = 30 * time.Second

type circuitBreaker struct {
	mu        sync.Mutex
	outcomes  []bool
	filled    int
	next      int
	failures  int
	open      bool
	openUntil time.Time
	// listener is the AppSec URL this breaker guards, named in its log lines.
	listener string
}

func newCircuitBreaker() *circuitBreaker {
	return &circuitBreaker{outcomes: make([]bool, breakerWindow)}
}

// One breaker per AppSec listener URL, so a failing core-rule-set listener
// cannot switch inspection off for the hosts on the default listener.
var (
	appsecBreakerMu sync.Mutex
	appsecBreakers  = map[string]*circuitBreaker{}
)

func currentBreaker(target string) *circuitBreaker {
	appsecBreakerMu.Lock()
	defer appsecBreakerMu.Unlock()
	cb, ok := appsecBreakers[target]
	if !ok {
		cb = newCircuitBreaker()
		cb.listener = target
		appsecBreakers[target] = cb
	}
	return cb
}

func resetBreaker() {
	appsecBreakerMu.Lock()
	defer appsecBreakerMu.Unlock()
	appsecBreakers = map[string]*circuitBreaker{}
}

func (cb *circuitBreaker) clearLocked() {
	for i := range cb.outcomes {
		cb.outcomes[i] = false
	}
	cb.filled = 0
	cb.next = 0
	cb.failures = 0
}

// allow reports whether a check may be made now.
func (cb *circuitBreaker) allow(now time.Time, logf func(string)) bool {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	if !cb.open {
		return true
	}
	if now.Before(cb.openUntil) {
		return false
	}
	cb.open = false
	cb.clearLocked()
	logf("[crowdsec-bouncer] action=appsec-breaker state=closed listener=" + cb.listener)
	return true
}

// record adds one check's outcome, and opens the breaker when the window is
// full and at least half of it failed.
func (cb *circuitBreaker) record(failed bool, now time.Time, logf func(string)) {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	if cb.open {
		return
	}
	if cb.filled == breakerWindow && cb.outcomes[cb.next] {
		cb.failures--
	}
	cb.outcomes[cb.next] = failed
	if failed {
		cb.failures++
	}
	cb.next = (cb.next + 1) % breakerWindow
	if cb.filled < breakerWindow {
		cb.filled++
	}
	if cb.filled == breakerWindow && cb.failures*2 >= breakerWindow {
		failures := cb.failures
		cb.open = true
		cb.openUntil = now.Add(breakerOpenFor)
		cb.clearLocked()
		logf(fmt.Sprintf("[crowdsec-bouncer] action=appsec-breaker state=open failures=%d/%d open-for=%s listener=%s",
			failures, breakerWindow, breakerOpenFor, cb.listener))
	}
}
