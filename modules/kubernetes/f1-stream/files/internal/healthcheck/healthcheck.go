package healthcheck

import (
	"context"
	"log"
	"net/http"
	"sync"
	"time"

	"f1-stream/internal/models"
	"f1-stream/internal/store"
)

const unhealthyThreshold = 5

const userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

// isReachable sends a GET request and returns true if the server responds with
// an HTTP 2xx or 3xx status code.
func isReachable(client *http.Client, rawURL string) bool {
	req, err := http.NewRequest("GET", rawURL, nil)
	if err != nil {
		return false
	}
	req.Header.Set("User-Agent", userAgent)

	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	return resp.StatusCode >= 200 && resp.StatusCode < 400
}

type HealthChecker struct {
	store    *store.Store
	interval time.Duration
	timeout  time.Duration
	client   *http.Client
	mu       sync.Mutex
}

func New(s *store.Store, interval, timeout time.Duration) *HealthChecker {
	return &HealthChecker{
		store:    s,
		interval: interval,
		timeout:  timeout,
		client: &http.Client{
			Timeout: timeout,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				if len(via) >= 3 {
					return http.ErrUseLastResponse
				}
				return nil
			},
		},
	}
}

func (hc *HealthChecker) Run(ctx context.Context) {
	log.Printf("healthcheck: starting with interval=%v timeout=%v", hc.interval, hc.timeout)
	hc.checkAll()

	ticker := time.NewTicker(hc.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Println("healthcheck: shutting down")
			return
		case <-ticker.C:
			hc.checkAll()
		}
	}
}

func (hc *HealthChecker) checkAll() {
	hc.mu.Lock()
	defer hc.mu.Unlock()

	start := time.Now()
	urls := hc.collectURLs()
	log.Printf("healthcheck: checking %d URLs", len(urls))

	existing, err := hc.store.LoadHealthStates()
	if err != nil {
		log.Printf("healthcheck: failed to load health states: %v", err)
		existing = nil
	}

	stateMap := make(map[string]*models.HealthState, len(existing))
	for i := range existing {
		stateMap[existing[i].URL] = &existing[i]
	}

	now := time.Now()
	var recovered, newlyUnhealthy int

	for _, url := range urls {
		st, exists := stateMap[url]
		if !exists {
			st = &models.HealthState{
				URL:     url,
				Healthy: true,
			}
			stateMap[url] = st
		}

		ok := isReachable(hc.client, url)

		if ok {
			if !st.Healthy {
				log.Printf("healthcheck: recovered %s", truncate(url, 80))
				recovered++
			}
			st.ConsecutiveFailures = 0
			st.Healthy = true
		} else {
			st.ConsecutiveFailures++
			if st.ConsecutiveFailures >= unhealthyThreshold && st.Healthy {
				st.Healthy = false
				log.Printf("healthcheck: marking unhealthy after %d failures: %s", st.ConsecutiveFailures, truncate(url, 80))
				newlyUnhealthy++
			}
		}
		st.LastCheckTime = now
	}

	// Prune orphaned entries: only keep states whose URL is in the current set
	urlSet := make(map[string]bool, len(urls))
	for _, u := range urls {
		urlSet[u] = true
	}
	var finalStates []models.HealthState
	healthyCount := 0
	for _, st := range stateMap {
		if urlSet[st.URL] {
			finalStates = append(finalStates, *st)
			if st.Healthy {
				healthyCount++
			}
		}
	}

	if err := hc.store.SaveHealthStates(finalStates); err != nil {
		log.Printf("healthcheck: failed to save health states: %v", err)
	}

	log.Printf("healthcheck: done in %v, checked=%d healthy=%d recovered=%d newly_unhealthy=%d",
		time.Since(start).Round(time.Millisecond), len(urls), healthyCount, recovered, newlyUnhealthy)
}

func (hc *HealthChecker) collectURLs() []string {
	seen := make(map[string]bool)

	streams, err := hc.store.LoadStreams()
	if err != nil {
		log.Printf("healthcheck: failed to load streams: %v", err)
	} else {
		for _, s := range streams {
			seen[s.URL] = true
		}
	}

	scraped, err := hc.store.LoadScrapedLinks()
	if err != nil {
		log.Printf("healthcheck: failed to load scraped links: %v", err)
	} else {
		for _, l := range scraped {
			seen[l.URL] = true
		}
	}

	urls := make([]string, 0, len(seen))
	for u := range seen {
		urls = append(urls, u)
	}
	return urls
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
