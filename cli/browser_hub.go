package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// A "hub" is the user's own cluster Chrome holding that user's logins: Viktor's
// is the chrome-service master, emo's lives in chrome-emo. Provisioning writes
// ~/.config/chrome-hub/hub.json; when it is present the CLI talks to the pool
// broker over its authenticated HTTPS route, and the bearer token decides which
// hub seeds the worker and which namespace the worker pod lands in. When it is
// absent the CLI keeps the port-forward-to-chrome-service behaviour.

// hubConfigEnv overrides the hub.json path (tests, alternate provisioning).
const hubConfigEnv = "HOMELAB_CHROME_HUB_CONFIG"

// hubServiceName is the CDP Service of every hub other than the master.
const hubServiceName = "chrome-hub"

// hubConfig is the subset of hub.json the CLI uses. The snapshot/cookies URLs
// and the write token belong to the cookie-sync clients, not to this verb.
type hubConfig struct {
	User      string `json:"user"`
	Namespace string `json:"namespace"`
	BrokerURL string `json:"broker_url"`
	ReadToken string `json:"read_token"`
}

func hubConfigPath() string {
	if p := os.Getenv(hubConfigEnv); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = os.Getenv("HOME")
	}
	return filepath.Join(home, ".config", "chrome-hub", "hub.json")
}

// loadHubConfig reads hub.json. An absent file returns (nil, nil): the user has
// no hub and the caller keeps the pre-hub behaviour. A present but unusable file
// is an error, because silently falling back would hide a broken provisioning.
func loadHubConfig(path string) (*hubConfig, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var h hubConfig
	if err := json.Unmarshal(b, &h); err != nil {
		return nil, fmt.Errorf("parse %s: %w (re-run the chrome-hub provisioning for this user)", path, err)
	}
	for field, v := range map[string]string{"broker_url": h.BrokerURL, "read_token": h.ReadToken, "namespace": h.Namespace} {
		if strings.TrimSpace(v) == "" {
			return nil, fmt.Errorf("%s has no %s (re-run the chrome-hub provisioning for this user)", path, field)
		}
	}
	h.BrokerURL = strings.TrimRight(h.BrokerURL, "/")
	u, err := url.Parse(h.BrokerURL)
	if err != nil || u.Host == "" {
		return nil, fmt.Errorf("%s: broker_url %q is not a URL", path, h.BrokerURL)
	}
	if u.Scheme != "https" && !isLoopbackHost(u.Hostname()) {
		return nil, fmt.Errorf("%s: broker_url %q must be https, the bearer token would otherwise travel in clear", path, h.BrokerURL)
	}
	return &h, nil
}

func isLoopbackHost(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// cdpTarget is a Service exposing a Chrome's CDP port.
type cdpTarget struct {
	namespace string
	service   string
	// requireHeadful: the chrome-service master is a headed Chrome under Xvfb
	// and the CLI asserts that. Other hubs may run headless.
	requireHeadful bool
}

// hubTarget is the Chrome --shared-context drives, and the fallback when the
// pool is unavailable: the caller's own hub, never another user's.
func hubTarget(hub *hubConfig) cdpTarget {
	if hub == nil || hub.Namespace == chromeServiceNamespace {
		return cdpTarget{namespace: chromeServiceNamespace, service: chromeServiceName, requireHeadful: true}
	}
	return cdpTarget{namespace: hub.Namespace, service: hubServiceName}
}

// workerNamespace is where the acquired worker pod lives: the /acquire response
// says so; older brokers omit it, and then hub.json (or chrome-service) decides.
func workerNamespace(fromAcquire string, hub *hubConfig) string {
	if fromAcquire != "" {
		return fromAcquire
	}
	if hub != nil {
		return hub.Namespace
	}
	return chromeServiceNamespace
}

// --- broker client -------------------------------------------------------

var (
	errBrokerUnauthorized = errors.New("broker rejected the hub token (401)")
	errBrokerForbidden    = errors.New("broker refused this address (403)")
	errBrokerUnreachable  = errors.New("broker unreachable")
)

// brokerClient talks to the pool broker, either over a local port-forward
// (no token, remote=false) or over the hub's HTTPS route (bearer, remote=true).
type brokerClient struct {
	base   string
	token  string
	remote bool
}

// acquireResult is the broker's /acquire answer.
type acquireResult struct {
	Pod       string `json:"pod"`
	CDPPort   int    `json:"cdpPort"`
	Session   string `json:"session"`
	Namespace string `json:"namespace"`
}

// parseAcquire reads the broker's /acquire response. An {"error":...} body
// (e.g. pool at capacity) is surfaced as an error.
func parseAcquire(body []byte) (acquireResult, error) {
	var v struct {
		acquireResult
		Error string `json:"error"`
	}
	if e := json.Unmarshal(body, &v); e != nil {
		return acquireResult{}, fmt.Errorf("parse /acquire response: %w", e)
	}
	if v.Error != "" {
		return acquireResult{}, fmt.Errorf("broker: %s", v.Error)
	}
	if v.Pod == "" || v.Session == "" {
		return acquireResult{}, fmt.Errorf("broker /acquire returned no pod/session: %s", string(body))
	}
	return v.acquireResult, nil
}

// do sends one request. It returns the status and body for any HTTP answer
// except 401/403, which it turns into errors that say what to do; a transport
// failure is an error too.
func (b brokerClient) do(method, path string, payload any, timeout time.Duration) (int, []byte, error) {
	var body io.Reader
	if payload != nil {
		j, err := json.Marshal(payload)
		if err != nil {
			return 0, nil, err
		}
		body = strings.NewReader(string(j))
	}
	req, err := http.NewRequest(method, b.base+path, body)
	if err != nil {
		return 0, nil, err
	}
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if b.token != "" {
		req.Header.Set("Authorization", "Bearer "+b.token)
	}
	resp, err := (&http.Client{Timeout: timeout}).Do(req)
	if err != nil {
		if b.remote {
			return 0, nil, fmt.Errorf("%w: cannot reach %s (%v). It is LAN-only: it answers only from the devvm or the home network, through internal DNS", errBrokerUnreachable, b.base, err)
		}
		return 0, nil, fmt.Errorf("%s %s: %w", method, path, err)
	}
	defer resp.Body.Close()
	rb, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, fmt.Errorf("%s %s: read body: %w", method, path, err)
	}
	switch resp.StatusCode {
	case http.StatusUnauthorized:
		return resp.StatusCode, rb, fmt.Errorf("%w: the read_token in %s is wrong or was rotated; re-run the chrome-hub provisioning for this user to rewrite it", errBrokerUnauthorized, hubConfigPath())
	case http.StatusForbidden:
		return resp.StatusCode, rb, fmt.Errorf("%w: %s is LAN-only (IP allowlist); call it from the devvm or the home network", errBrokerForbidden, b.base)
	}
	return resp.StatusCode, rb, nil
}

// acquire asks the broker for a worker.
func (b brokerClient) acquire(owner, purpose string) (acquireResult, error) {
	// create+ready can take a few seconds
	_, body, err := b.do(http.MethodPost, "/acquire", map[string]string{"owner": owner, "purpose": purpose}, 90*time.Second)
	if err != nil {
		return acquireResult{}, err
	}
	return parseAcquire(body)
}

// release tells the broker to reap/return the worker. Best-effort.
func (b brokerClient) release(session string) {
	_, _, _ = b.do(http.MethodPost, "/release", map[string]string{"session": session}, 15*time.Second)
}

// sessionHeartbeatInterval is how often a running session tells the broker it
// is still alive. The broker reclaims a heartbeating session after
// HEARTBEAT_TIMEOUT_SECONDS (120s) of silence, so this leaves room for four
// missed beats before a live run is at risk.
const sessionHeartbeatInterval = 30 * time.Second

// startHeartbeat keeps the pool claim alive for as long as this process is,
// and returns a function that stops it.
//
// A run killed before its teardown (SIGKILL, OOM, a dropped connection) leaves
// chrome-pool/session set on the warm pod. pick_free_worker skips any pod
// carrying one, so the pool falls back to cold burst pods until the reaper
// deletes the pod 60 minutes later. With a heartbeat the broker reclaims it in
// about two minutes instead, and reclaims it in place, so the pod stays warm.
//
// The first beat is sent immediately rather than after the first tick: a run
// killed in its first 30 seconds would otherwise have no heartbeat on record
// and fall back to the 60-minute path, which is the case being fixed.
func (b brokerClient) startHeartbeat(session string) func() {
	done := make(chan struct{})
	beat := func() {
		_, _, _ = b.do(http.MethodPost, "/heartbeat", map[string]string{"session": session}, 10*time.Second)
	}
	beat()
	go func() {
		t := time.NewTicker(sessionHeartbeatInterval)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				beat()
			}
		}
	}()
	var once sync.Once
	return func() { once.Do(func() { close(done) }) }
}

// fetchSeed downloads the broker's on-demand storage_state export to dest.
func (b brokerClient) fetchSeed(dest string) error {
	status, body, err := b.do(http.MethodGet, "/seed", nil, 40*time.Second)
	if err != nil {
		return err
	}
	if status/100 != 2 {
		return fmt.Errorf("seed status %d", status)
	}
	return os.WriteFile(dest, body, 0o600)
}

// poolSession is one row of the broker's /sessions answer.
type poolSession struct {
	Owner   string `json:"owner"`
	Purpose string `json:"purpose"`
	Session string `json:"session"`
	URL     string `json:"url"`
	Name    string `json:"name"`
	Ready   bool   `json:"ready"`
}

func (b brokerClient) sessions() ([]poolSession, error) {
	status, body, err := b.do(http.MethodGet, "/sessions", nil, 10*time.Second)
	if err != nil {
		return nil, err
	}
	if status/100 != 2 {
		return nil, fmt.Errorf("GET /sessions: status %d", status)
	}
	var out struct {
		Sessions []poolSession `json:"sessions"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode /sessions: %w", err)
	}
	return out.Sessions, nil
}

// printSessions writes the claimed sessions as a table; idle warm workers are
// skipped.
func printSessions(w io.Writer, list []poolSession) {
	active := 0
	fmt.Fprintf(w, "%-14s  %-6s  %-24s  %s\n", "OWNER", "READY", "POD", "PURPOSE / URL")
	for _, s := range list {
		if s.Session == "" {
			continue // idle/warm worker, not a claimed session
		}
		active++
		detail := s.Purpose
		if s.URL != "" {
			detail = s.URL
		}
		fmt.Fprintf(w, "%-14s  %-6t  %-24s  %s\n", s.Owner, s.Ready, s.Name, detail)
	}
	if active == 0 {
		fmt.Fprintln(w, "(no active pool sessions)")
	}
}
