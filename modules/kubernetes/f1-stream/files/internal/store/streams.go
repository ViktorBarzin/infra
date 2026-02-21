package store

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"

	"f1-stream/internal/models"
)

func (s *Store) LoadStreams() ([]models.Stream, error) {
	s.streamsMu.RLock()
	defer s.streamsMu.RUnlock()
	var streams []models.Stream
	if err := readJSON(s.filePath("streams.json"), &streams); err != nil {
		return nil, err
	}
	return streams, nil
}

func (s *Store) PublicStreams() ([]models.Stream, error) {
	s.streamsMu.RLock()
	defer s.streamsMu.RUnlock()
	var streams []models.Stream
	if err := readJSON(s.filePath("streams.json"), &streams); err != nil {
		return nil, err
	}
	healthMap := s.HealthMap()
	var pub []models.Stream
	for _, st := range streams {
		if !st.Published {
			continue
		}
		// Filter unhealthy streams. URLs not in healthMap are assumed healthy (new/unchecked).
		if healthy, exists := healthMap[st.URL]; exists && !healthy {
			continue
		}
		pub = append(pub, st)
	}
	return pub, nil
}

func (s *Store) UserStreams(userID string) ([]models.Stream, error) {
	s.streamsMu.RLock()
	defer s.streamsMu.RUnlock()
	var streams []models.Stream
	if err := readJSON(s.filePath("streams.json"), &streams); err != nil {
		return nil, err
	}
	var result []models.Stream
	for _, st := range streams {
		if st.SubmittedBy == userID {
			result = append(result, st)
		}
	}
	return result, nil
}

func (s *Store) AddStream(url, title, submittedBy string, published bool, source string) (models.Stream, error) {
	s.streamsMu.Lock()
	defer s.streamsMu.Unlock()
	var streams []models.Stream
	if err := readJSON(s.filePath("streams.json"), &streams); err != nil {
		return models.Stream{}, err
	}
	id, err := randomID()
	if err != nil {
		return models.Stream{}, err
	}
	st := models.Stream{
		ID:          id,
		URL:         url,
		Title:       title,
		SubmittedBy: submittedBy,
		Published:   published,
		Source:      source,
		CreatedAt:   time.Now(),
	}
	streams = append(streams, st)
	if err := writeJSON(s.filePath("streams.json"), streams); err != nil {
		return models.Stream{}, err
	}
	return st, nil
}

func (s *Store) PublishScrapedStream(url, title string) error {
	s.streamsMu.Lock()
	defer s.streamsMu.Unlock()
	var streams []models.Stream
	if err := readJSON(s.filePath("streams.json"), &streams); err != nil {
		return err
	}
	// Deduplicate: skip if URL already exists in streams
	for _, st := range streams {
		if st.URL == url {
			return nil
		}
	}
	id, err := randomID()
	if err != nil {
		return err
	}
	streams = append(streams, models.Stream{
		ID:          id,
		URL:         url,
		Title:       title,
		SubmittedBy: "scraper",
		Published:   true,
		Source:      "scraped",
		CreatedAt:   time.Now(),
	})
	return writeJSON(s.filePath("streams.json"), streams)
}

func (s *Store) DeleteStream(id, userID string, isAdmin bool) error {
	s.streamsMu.Lock()
	defer s.streamsMu.Unlock()
	var streams []models.Stream
	if err := readJSON(s.filePath("streams.json"), &streams); err != nil {
		return err
	}
	var updated []models.Stream
	found := false
	for _, st := range streams {
		if st.ID == id {
			if userID != "" && !isAdmin && st.SubmittedBy != userID {
				return fmt.Errorf("not authorized")
			}
			found = true
			continue
		}
		updated = append(updated, st)
	}
	if !found {
		return fmt.Errorf("stream not found")
	}
	return writeJSON(s.filePath("streams.json"), updated)
}

func (s *Store) TogglePublish(id string) error {
	s.streamsMu.Lock()
	defer s.streamsMu.Unlock()
	var streams []models.Stream
	if err := readJSON(s.filePath("streams.json"), &streams); err != nil {
		return err
	}
	for i, st := range streams {
		if st.ID == id {
			streams[i].Published = !st.Published
			return writeJSON(s.filePath("streams.json"), streams)
		}
	}
	return fmt.Errorf("stream not found")
}

func (s *Store) SeedStreams(defaults []models.Stream) error {
	s.streamsMu.Lock()
	defer s.streamsMu.Unlock()
	var existing []models.Stream
	if err := readJSON(s.filePath("streams.json"), &existing); err != nil {
		return err
	}
	if len(existing) > 0 {
		return nil
	}
	return writeJSON(s.filePath("streams.json"), defaults)
}

func randomID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
