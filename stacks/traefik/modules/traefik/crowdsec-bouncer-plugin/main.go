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
	"context"
	"encoding/json"
	"fmt"
	"io"
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
	ips    map[string]struct{}
	ranges []*net.IPNet
	loaded bool
}

func (d *decisionSet) size() int {
	if d == nil {
		return 0
	}
	return len(d.ips) + len(d.ranges)
}

func (d *decisionSet) contains(ip net.IP) bool {
	if d == nil || ip == nil {
		return false
	}
	if _, ok := d.ips[ip.String()]; ok {
		return true
	}
	for _, n := range d.ranges {
		if n.Contains(ip) {
			return true
		}
	}
	return false
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
	set := &decisionSet{ips: map[string]struct{}{}, loaded: true}
	for _, d := range decisions {
		if !strings.EqualFold(strings.TrimSpace(d.Type), "ban") {
			continue
		}
		if allowedOrigins != nil {
			if _, ok := allowedOrigins[strings.ToLower(strings.TrimSpace(d.Origin))]; !ok {
				continue
			}
		}
		value := strings.TrimSpace(d.Value)
		if value == "" {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(d.Scope)) {
		case "ip":
			if ip := parseIP(value); ip != nil {
				set.ips[ip.String()] = struct{}{}
			}
		case "range":
			if _, n, err := net.ParseCIDR(value); err == nil {
				set.ranges = append(set.ranges, n)
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

	set := parseDecisions(decisions, originSet(origins))
	previous := s.snapshot()
	s.publish(set)
	if !previous.loaded || previous.size() != set.size() {
		logf(fmt.Sprintf("[crowdsec-bouncer] action=loaded entries=%d ips=%d ranges=%d",
			set.size(), len(set.ips), len(set.ranges)))
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

	return &Bouncer{
		next:        next,
		name:        name,
		trustedNets: trustedNets,
		skipHosts:   skipHosts,
		dryRun:      cfg.DryRun,
		statusCode:  statusCode,
		banMessage:  cfg.BanMessage,
		logf:        stdoutLogf,
		store:       &store{},
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

	key := lapiURL + "\x00" + lapiKey + "\x00" + strings.Join(origins, ",") + "\x00" + strconv.Itoa(int(interval/time.Second))
	b.store = sharedStore(key, func(s *store) {
		// Logged HERE, not once per New(): Traefik rebuilds the middleware chain
		// on every dynamic-config reload, which on this cluster is ~285 times an
		// hour — a per-New() line was pure noise, and it is also the reason the
		// poller is shared rather than started per instance.
		b.logf(fmt.Sprintf("[crowdsec-bouncer] action=started name=%s lapi=%s interval=%s dryRun=%t origins=%s skipHosts=%d",
			name, lapiURL, interval, b.dryRun, strings.Join(origins, ","), len(b.skipHosts)))
		// Load once synchronously so the first request through a fresh Traefik
		// pod is already enforced instead of failing open for a whole interval.
		if err := s.refresh(client, lapiURL, lapiKey, origins, b.logf); err != nil {
			b.logf(fmt.Sprintf("[crowdsec-bouncer] action=initial-load-failed allowing-all-until-first-success error=%v", err))
		}
		go s.poll(client, lapiURL, lapiKey, origins, interval, b.logf)
	})
	return b, nil
}

// stdoutLogf is the production sink. Traefik's own log and the CLF access log
// already share this stream, so an extra unparsed line is business as usual for
// the CrowdSec traefik-logs grok.
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

	set := b.store.snapshot()
	if !set.loaded {
		// Nothing has ever been loaded: allow. Fail open.
		b.next.ServeHTTP(rw, req)
		return
	}

	ip := b.clientIP(req)
	if ip == nil || !set.contains(ip) {
		b.next.ServeHTTP(rw, req)
		return
	}

	// Only decisions are logged, never allowed requests — at ~10 req/s steady
	// state and 64 req/s peak, logging every request would dwarf the signal.
	// These lines are the alerting surface: Prometheus counters are not cheaply
	// available inside Yaegi, so the Loki recording/alert rules read this.
	if b.dryRun {
		b.logf(fmt.Sprintf("[crowdsec-bouncer] action=dry-run-block ip=%s host=%s method=%s path=%s",
			ip, host, req.Method, req.URL.Path))
		b.next.ServeHTTP(rw, req)
		return
	}

	b.logf(fmt.Sprintf("[crowdsec-bouncer] action=block ip=%s host=%s method=%s path=%s status=%d",
		ip, host, req.Method, req.URL.Path, b.statusCode))
	rw.Header().Set("Content-Type", "text/plain; charset=utf-8")
	rw.WriteHeader(b.statusCode)
	if b.banMessage != "" {
		fmt.Fprint(rw, b.banMessage)
	}
}
