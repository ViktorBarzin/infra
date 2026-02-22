package playerconfig

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

// PlayerConfig is returned by the /api/streams/{id}/player-config endpoint.
type PlayerConfig struct {
	Type        string `json:"type"`
	HLSURL      string `json:"hls_url,omitempty"`
	AuthToken   string `json:"auth_token,omitempty"`
	ChannelKey  string `json:"channel_key,omitempty"`
	ChannelSalt string `json:"channel_salt,omitempty"`
	Timestamp   string `json:"timestamp,omitempty"`
	AuthModURL  string `json:"auth_mod_url,omitempty"`
	ServerKey   string `json:"server_key,omitempty"`
	Error       string `json:"error,omitempty"`
}

type cacheEntry struct {
	config    *PlayerConfig
	expiresAt time.Time
}

// Service handles stream type detection and DaddyLive config extraction.
type Service struct {
	client *http.Client
	mu     sync.RWMutex
	cache  map[string]*cacheEntry
}

// New creates a new playerconfig Service.
func New() *Service {
	return &Service{
		client: &http.Client{
			Timeout: 15 * time.Second,
		},
		cache: make(map[string]*cacheEntry),
	}
}

// DetectStreamType returns "hls", "daddylive", "vipleague", or "proxy" based on the URL.
func DetectStreamType(rawURL string) string {
	lower := strings.ToLower(rawURL)

	if strings.HasSuffix(strings.SplitN(lower, "?", 2)[0], ".m3u8") {
		return "hls"
	}

	daddyPatterns := []string{"dlhd.link", "dlhd.sx", "dlhd.dad", "daddylive", "ksohls.ru"}
	for _, p := range daddyPatterns {
		if strings.Contains(lower, p) {
			return "daddylive"
		}
	}

	vipPatterns := []string{"vipleague.io", "vipleague.im", "vipleague.cc", "casthill.net"}
	for _, p := range vipPatterns {
		if strings.Contains(lower, p) {
			return "vipleague"
		}
	}

	return "proxy"
}

// GetConfig returns a PlayerConfig for the given stream URL.
func (s *Service) GetConfig(ctx context.Context, rawURL string) *PlayerConfig {
	streamType := DetectStreamType(rawURL)

	switch streamType {
	case "hls":
		encoded := base64.RawURLEncoding.EncodeToString([]byte(rawURL))
		return &PlayerConfig{
			Type:   "hls",
			HLSURL: "/hls/" + encoded,
		}

	case "daddylive":
		return s.getDaddyLiveConfig(ctx, rawURL)

	case "vipleague":
		return s.getVIPLeagueConfig(ctx, rawURL)

	default:
		return &PlayerConfig{Type: "proxy"}
	}
}

// Channel ID extraction patterns
var channelIDPatterns = []*regexp.Regexp{
	regexp.MustCompile(`stream-(\d+)\.php`),
	regexp.MustCompile(`[?&]id=(\d+)`),
	regexp.MustCompile(`/(\d+)\.php`),
}

// Page content extraction patterns
var (
	iframeRe     = regexp.MustCompile(`<iframe[^>]*src=["'](https?://[^"']*ksohls\.ru[^"']*)["']`)
	authTokenRe  = regexp.MustCompile(`authToken\s*[:=]\s*['"]([^'"]+)['"]`)
	channelKeyRe = regexp.MustCompile(`channelKey\s*[:=]\s*['"]([^'"]+)['"]`)
	channelSaltRe = regexp.MustCompile(`channelSalt\s*[:=]\s*['"]([^'"]+)['"]`)
	timestampRe  = regexp.MustCompile(`timestamp\s*[:=]\s*['"]?(\d+)['"]?`)
	authModRe    = regexp.MustCompile(`<script[^>]*src=["'](https?://[^"']*aiaged\.fun[^"']*obfuscated[^"']*)["']`)
)

func (s *Service) getDaddyLiveConfig(ctx context.Context, rawURL string) *PlayerConfig {
	// Check cache
	s.mu.RLock()
	if entry, ok := s.cache[rawURL]; ok && time.Now().Before(entry.expiresAt) {
		s.mu.RUnlock()
		return entry.config
	}
	s.mu.RUnlock()

	config := s.fetchDaddyLiveConfig(ctx, rawURL)

	// Cache the result (even errors, to avoid hammering)
	s.mu.Lock()
	s.cache[rawURL] = &cacheEntry{
		config:    config,
		expiresAt: time.Now().Add(1 * time.Hour),
	}
	s.mu.Unlock()

	return config
}

func (s *Service) fetchDaddyLiveConfig(ctx context.Context, rawURL string) *PlayerConfig {
	// Step 1: Extract channel ID from URL
	channelID := ""
	for _, re := range channelIDPatterns {
		if m := re.FindStringSubmatch(rawURL); len(m) > 1 {
			channelID = m[1]
			break
		}
	}
	if channelID == "" {
		return &PlayerConfig{Type: "proxy", Error: "could not extract channel ID"}
	}

	log.Printf("playerconfig: DaddyLive channel=%s from %s", channelID, rawURL)
	return s.fetchDaddyLiveConfigByID(ctx, channelID)
}

func (s *Service) fetchDaddyLiveConfigByID(ctx context.Context, channelID string) *PlayerConfig {
	// Step 2: Fetch the cast page to find the ksohls iframe
	castURL := fmt.Sprintf("https://dlhd.link/cast/stream-%s.php", channelID)
	castBody, err := s.fetchPage(ctx, castURL, "https://dlhd.link/")
	if err != nil {
		log.Printf("playerconfig: failed to fetch cast page: %v", err)
		return &PlayerConfig{Type: "proxy", Error: "failed to fetch cast page"}
	}

	// Step 3: Extract ksohls iframe URL
	iframeMatch := iframeRe.FindStringSubmatch(castBody)
	if iframeMatch == nil {
		log.Printf("playerconfig: no ksohls iframe found in cast page")
		return &PlayerConfig{Type: "proxy", Error: "no ksohls iframe found"}
	}
	ksohURL := iframeMatch[1]

	// Step 4: Fetch the ksohls page
	referer := fmt.Sprintf("https://dlhd.link/stream/stream-%s.php", channelID)
	ksohBody, err := s.fetchPage(ctx, ksohURL, referer)
	if err != nil {
		log.Printf("playerconfig: failed to fetch ksohls page: %v", err)
		return &PlayerConfig{Type: "proxy", Error: "failed to fetch ksohls page"}
	}

	// Step 5: Extract auth params from ksohls page
	config := &PlayerConfig{Type: "daddylive"}

	if m := authTokenRe.FindStringSubmatch(ksohBody); len(m) > 1 {
		config.AuthToken = m[1]
	}
	if m := channelKeyRe.FindStringSubmatch(ksohBody); len(m) > 1 {
		config.ChannelKey = m[1]
	}
	if m := channelSaltRe.FindStringSubmatch(ksohBody); len(m) > 1 {
		config.ChannelSalt = m[1]
	}
	if m := timestampRe.FindStringSubmatch(ksohBody); len(m) > 1 {
		config.Timestamp = m[1]
	}
	if m := authModRe.FindStringSubmatch(ksohBody); len(m) > 1 {
		config.AuthModURL = m[1]
	}

	if config.ChannelKey == "" {
		log.Printf("playerconfig: no channelKey found in ksohls page")
		return &PlayerConfig{Type: "proxy", Error: "no channelKey found"}
	}

	// Step 6: Server lookup
	lookupURL := fmt.Sprintf("https://chevy.soyspace.cyou/server_lookup?channel_id=%s", config.ChannelKey)
	lookupBody, err := s.fetchPage(ctx, lookupURL, "")
	if err != nil {
		log.Printf("playerconfig: server lookup failed: %v", err)
		return &PlayerConfig{Type: "proxy", Error: "server lookup failed"}
	}

	var lookupResp struct {
		ServerKey string `json:"server_key"`
	}
	if err := json.Unmarshal([]byte(lookupBody), &lookupResp); err != nil || lookupResp.ServerKey == "" {
		log.Printf("playerconfig: failed to parse server lookup: %v body=%s", err, lookupBody)
		return &PlayerConfig{Type: "proxy", Error: "server lookup parse failed"}
	}
	config.ServerKey = lookupResp.ServerKey

	// Step 7: Build m3u8 URL
	m3u8URL := fmt.Sprintf("https://chevy.soyspace.cyou/proxy/%s/%s/mono.m3u8",
		config.ServerKey, config.ChannelKey)
	encoded := base64.RawURLEncoding.EncodeToString([]byte(m3u8URL))
	config.HLSURL = "/hls/" + encoded

	log.Printf("playerconfig: DaddyLive config ready channel=%s server=%s", config.ChannelKey, config.ServerKey)
	return config
}

// VIPLeague/casthill resolution

var zmidRe = regexp.MustCompile(`(?:const|var|let)\s+zmid\s*=\s*["']([^"']+)["']`)
var casthillVRe = regexp.MustCompile(`[?&]v=([^&]+)`)

func (s *Service) getVIPLeagueConfig(ctx context.Context, rawURL string) *PlayerConfig {
	// Check cache using normalized URL
	s.mu.RLock()
	if entry, ok := s.cache[rawURL]; ok && time.Now().Before(entry.expiresAt) {
		s.mu.RUnlock()
		return entry.config
	}
	s.mu.RUnlock()

	config := s.fetchVIPLeagueConfig(ctx, rawURL)

	s.mu.Lock()
	s.cache[rawURL] = &cacheEntry{
		config:    config,
		expiresAt: time.Now().Add(1 * time.Hour),
	}
	s.mu.Unlock()

	return config
}

func (s *Service) fetchVIPLeagueConfig(ctx context.Context, rawURL string) *PlayerConfig {
	lower := strings.ToLower(rawURL)

	var zmid string

	if strings.Contains(lower, "casthill.net") {
		// Extract zmid from casthill URL query param ?v=...
		if m := casthillVRe.FindStringSubmatch(rawURL); len(m) > 1 {
			zmid = m[1]
		}
	}

	if zmid == "" {
		// Try to fetch VIPLeague page and extract zmid from JavaScript
		body, err := s.fetchPage(ctx, rawURL, "")
		if err != nil {
			log.Printf("playerconfig: failed to fetch VIPLeague page: %v, trying URL-based extraction", err)
		} else {
			if m := zmidRe.FindStringSubmatch(body); len(m) > 1 {
				zmid = m[1]
			}
		}
	}

	if zmid == "" {
		// Fallback: extract slug from URL path and use it directly for channel matching
		// e.g. /f-1/sky-sports-f1-streaming → "sky sports f1"
		zmid = extractSlugFromURL(rawURL)
		if zmid != "" {
			log.Printf("playerconfig: extracted slug %q from URL path", zmid)
		}
	}

	if zmid == "" {
		log.Printf("playerconfig: no zmid found for VIPLeague URL %s", rawURL)
		return &PlayerConfig{Type: "proxy", Error: "no zmid found in VIPLeague page"}
	}

	log.Printf("playerconfig: VIPLeague zmid=%q from %s", zmid, rawURL)

	channelID, err := s.resolveChannelID(ctx, zmid)
	if err != nil {
		log.Printf("playerconfig: failed to resolve zmid %q: %v", zmid, err)
		return &PlayerConfig{Type: "proxy", Error: fmt.Sprintf("failed to resolve zmid: %v", err)}
	}

	log.Printf("playerconfig: resolved zmid=%q to DaddyLive channel=%s", zmid, channelID)
	return s.fetchDaddyLiveConfigByID(ctx, channelID)
}

// extractSlugFromURL extracts a channel-matching slug from a VIPLeague URL path.
// e.g. "https://vipleague.io/f-1/sky-sports-f1-streaming" → "sky sports f1"
// Strips common suffixes like "-streaming", "-live-stream", "-live", etc.
func extractSlugFromURL(rawURL string) string {
	// Get the last path segment
	path := rawURL
	if idx := strings.Index(path, "?"); idx != -1 {
		path = path[:idx]
	}
	path = strings.TrimRight(path, "/")
	lastSlash := strings.LastIndex(path, "/")
	if lastSlash == -1 {
		return ""
	}
	slug := path[lastSlash+1:]

	// Strip common suffixes
	for _, suffix := range []string{"-streaming", "-live-stream", "-stream", "-live", "-online", "-free"} {
		slug = strings.TrimSuffix(slug, suffix)
	}

	// Replace hyphens with spaces for matching against channel names
	slug = strings.ReplaceAll(slug, "-", " ")
	slug = strings.TrimSpace(slug)

	if slug == "" || len(slug) < 3 {
		return ""
	}
	return slug
}

var channelLinkRe = regexp.MustCompile(`<a[^>]*href=["'][^"']*watch\.php\?id=(\d+)["'][^>]*data-title=["']([^"']+)["']`)
var channelLinkRe2 = regexp.MustCompile(`<a[^>]*data-title=["']([^"']+)["'][^>]*href=["'][^"']*watch\.php\?id=(\d+)["']`)

func (s *Service) resolveChannelID(ctx context.Context, zmid string) (string, error) {
	channels, err := s.getChannelIndex(ctx)
	if err != nil {
		return "", err
	}

	zmidLower := strings.ToLower(zmid)

	// Build tokens: if zmid contains spaces, split on spaces; otherwise use tokenizer
	var tokens []string
	if strings.Contains(zmidLower, " ") {
		for _, word := range strings.Fields(zmidLower) {
			if len(word) >= 2 {
				tokens = append(tokens, word)
			}
		}
	} else {
		tokens = tokenize(zmidLower)
	}

	bestID := ""
	bestScore := 0
	bestNameLen := 0

	for id, name := range channels {
		score := 0
		for _, tok := range tokens {
			if strings.Contains(name, tok) {
				score++
			}
		}
		// Tiebreaker: prefer shorter names (more specific match) and
		// English/UK channels which tend to have shorter names
		if score > bestScore || (score == bestScore && score > 0 && len(name) < bestNameLen) {
			bestScore = score
			bestID = id
			bestNameLen = len(name)
		}
	}

	if bestID == "" || bestScore == 0 {
		return "", fmt.Errorf("no channel matched zmid %q (tried %d channels)", zmid, len(channels))
	}

	log.Printf("playerconfig: zmid=%q matched channel %s (%s) with score %d/%d",
		zmid, bestID, channels[bestID], bestScore, len(tokens))
	return bestID, nil
}

func (s *Service) getChannelIndex(ctx context.Context) (map[string]string, error) {
	const cacheKey = "__channel_index__"

	s.mu.RLock()
	if entry, ok := s.cache[cacheKey]; ok && time.Now().Before(entry.expiresAt) {
		s.mu.RUnlock()
		// Decode from the Error field (ab)used as storage
		var idx map[string]string
		if err := json.Unmarshal([]byte(entry.config.Error), &idx); err == nil {
			return idx, nil
		}
	}
	s.mu.RUnlock()

	body, err := s.fetchPage(ctx, "https://dlhd.link/24-7-channels.php", "https://dlhd.link/")
	if err != nil {
		return nil, fmt.Errorf("failed to fetch channel index: %w", err)
	}

	channels := make(map[string]string)

	// Try both attribute orderings
	for _, m := range channelLinkRe.FindAllStringSubmatch(body, -1) {
		channels[m[1]] = strings.ToLower(strings.TrimSpace(m[2]))
	}
	for _, m := range channelLinkRe2.FindAllStringSubmatch(body, -1) {
		channels[m[2]] = strings.ToLower(strings.TrimSpace(m[1]))
	}

	if len(channels) == 0 {
		return nil, fmt.Errorf("no channels found in 24/7 page (%d bytes)", len(body))
	}

	log.Printf("playerconfig: loaded %d channels from DaddyLive 24/7 page", len(channels))

	// Cache as JSON in a fake PlayerConfig entry
	encoded, _ := json.Marshal(channels)
	s.mu.Lock()
	s.cache[cacheKey] = &cacheEntry{
		config:    &PlayerConfig{Error: string(encoded)},
		expiresAt: time.Now().Add(6 * time.Hour),
	}
	s.mu.Unlock()

	return channels, nil
}

// tokenize splits a zmid slug into meaningful tokens.
// e.g. "skyf1" -> ["sky", "f1"], "daznf1" -> ["dazn", "f1"]
func tokenize(zmid string) []string {
	// Common known prefixes/suffixes in sports streaming slugs
	knownTokens := []string{
		"sky", "sports", "f1", "dazn", "espn", "fox", "bein", "bt",
		"star", "nbc", "cbs", "tnt", "abc", "tsn", "supersport",
		"canal", "rtl", "viaplay", "premier", "main", "event",
		"arena", "action", "cricket", "football", "tennis", "golf",
		"racing", "news", "extra", "max", "hd", "uhd",
	}

	var tokens []string
	remaining := zmid

	for len(remaining) > 0 {
		matched := false
		for _, tok := range knownTokens {
			if strings.HasPrefix(remaining, tok) {
				tokens = append(tokens, tok)
				remaining = remaining[len(tok):]
				matched = true
				break
			}
		}
		if !matched {
			// Try numeric suffix (like channel numbers)
			i := 0
			for i < len(remaining) && remaining[i] >= '0' && remaining[i] <= '9' {
				i++
			}
			if i > 0 {
				tokens = append(tokens, remaining[:i])
				remaining = remaining[i:]
			} else {
				// Skip single character and try again
				remaining = remaining[1:]
			}
		}
	}

	// If tokenization produced nothing useful, use the whole zmid as a single token
	if len(tokens) == 0 {
		tokens = []string{zmid}
	}

	return tokens
}

func (s *Service) fetchPage(ctx context.Context, pageURL, referer string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, pageURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
	if referer != "" {
		req.Header.Set("Referer", referer)
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("status %d from %s", resp.StatusCode, pageURL)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 2*1024*1024)) // 2MB max
	if err != nil {
		return "", err
	}
	return string(body), nil
}
