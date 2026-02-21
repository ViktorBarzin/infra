package scraper

import (
	"context"
	"log"
	"sync"
	"time"

	"f1-stream/internal/models"
	"f1-stream/internal/store"
)

type Scraper struct {
	store           *store.Store
	interval        time.Duration
	validateTimeout time.Duration
	mu              sync.Mutex
}

func New(s *store.Store, interval time.Duration, validateTimeout time.Duration) *Scraper {
	return &Scraper{store: s, interval: interval, validateTimeout: validateTimeout}
}

func (s *Scraper) Run(ctx context.Context) {
	log.Printf("scraper: starting with interval %v", s.interval)
	// Run immediately on start
	s.scrape()

	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Println("scraper: shutting down")
			return
		case <-ticker.C:
			s.scrape()
		}
	}
}

func (s *Scraper) TriggerScrape() {
	go s.scrape()
}

func (s *Scraper) scrape() {
	s.mu.Lock()
	defer s.mu.Unlock()

	start := time.Now()
	log.Println("scraper: starting scrape")
	links, err := scrapeReddit()
	if err != nil {
		log.Printf("scraper: error after %v: %v", time.Since(start).Round(time.Millisecond), err)
		return
	}
	log.Printf("scraper: reddit scrape completed in %v, got %d links", time.Since(start).Round(time.Millisecond), len(links))

	// Merge with existing links, filtering out non-F1 entries
	existing, err := s.store.LoadScrapedLinks()
	if err != nil {
		log.Printf("scraper: failed to load existing links: %v", err)
		existing = nil
	}
	seen := make(map[string]bool)
	var filtered []models.ScrapedLink
	for _, l := range existing {
		if !isF1Post(l.Title) {
			continue
		}
		norm := normalizeURL(l.URL)
		seen[norm] = true
		filtered = append(filtered, l)
	}
	existing = filtered

	added := 0
	for _, l := range links {
		norm := normalizeURL(l.URL)
		if !seen[norm] {
			existing = append(existing, l)
			seen[norm] = true
			added++
		}
	}

	if err := s.store.SaveScrapedLinks(existing); err != nil {
		log.Printf("scraper: failed to save: %v", err)
		return
	}

	// Auto-publish newly validated links as streams
	for _, l := range links {
		if err := s.store.PublishScrapedStream(l.URL, l.Title); err != nil {
			u := l.URL
			if len(u) > 80 {
				u = u[:80] + "..."
			}
			log.Printf("scraper: failed to auto-publish %s: %v", u, err)
		}
	}

	log.Printf("scraper: done in %v, added %d new links (total: %d)", time.Since(start).Round(time.Millisecond), added, len(existing))
}
