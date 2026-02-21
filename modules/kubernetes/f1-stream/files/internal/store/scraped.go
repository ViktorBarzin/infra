package store

import (
	"fmt"
	"time"

	"f1-stream/internal/models"
)

func (s *Store) LoadScrapedLinks() ([]models.ScrapedLink, error) {
	s.scrapedMu.RLock()
	defer s.scrapedMu.RUnlock()
	var links []models.ScrapedLink
	if err := readJSON(s.filePath("scraped_links.json"), &links); err != nil {
		return nil, err
	}
	return links, nil
}

func (s *Store) SaveScrapedLinks(links []models.ScrapedLink) error {
	s.scrapedMu.Lock()
	defer s.scrapedMu.Unlock()
	return writeJSON(s.filePath("scraped_links.json"), links)
}

func (s *Store) GetScrapedLinkByID(id string) (models.ScrapedLink, error) {
	s.scrapedMu.RLock()
	defer s.scrapedMu.RUnlock()
	var links []models.ScrapedLink
	if err := readJSON(s.filePath("scraped_links.json"), &links); err != nil {
		return models.ScrapedLink{}, err
	}
	for _, l := range links {
		if l.ID == id {
			return l, nil
		}
	}
	return models.ScrapedLink{}, fmt.Errorf("not found")
}

func (s *Store) GetActiveScrapedLinks() ([]models.ScrapedLink, error) {
	s.scrapedMu.RLock()
	defer s.scrapedMu.RUnlock()
	var links []models.ScrapedLink
	if err := readJSON(s.filePath("scraped_links.json"), &links); err != nil {
		return nil, err
	}
	healthMap := s.HealthMap()
	now := time.Now()
	var active []models.ScrapedLink
	for _, l := range links {
		l.Stale = now.Sub(l.ScrapedAt) > 7*24*time.Hour
		if l.Stale {
			continue
		}
		// Filter unhealthy scraped links. URLs not in healthMap are assumed healthy.
		if healthy, exists := healthMap[l.URL]; exists && !healthy {
			continue
		}
		active = append(active, l)
	}
	return active, nil
}
