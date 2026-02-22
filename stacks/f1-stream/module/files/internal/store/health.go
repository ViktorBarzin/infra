package store

import (
	"f1-stream/internal/models"
)

func (s *Store) LoadHealthStates() ([]models.HealthState, error) {
	s.healthMu.RLock()
	defer s.healthMu.RUnlock()
	var states []models.HealthState
	if err := readJSON(s.filePath("health_state.json"), &states); err != nil {
		return nil, err
	}
	return states, nil
}

func (s *Store) SaveHealthStates(states []models.HealthState) error {
	s.healthMu.Lock()
	defer s.healthMu.Unlock()
	return writeJSON(s.filePath("health_state.json"), states)
}

// HealthMap returns a map of URL -> Healthy status. It reads the health state
// file directly without acquiring healthMu to avoid deadlock when called from
// methods that already hold other locks (e.g., PublicStreams, GetActiveScrapedLinks).
// URLs not present in the map are implicitly healthy.
func (s *Store) HealthMap() map[string]bool {
	var states []models.HealthState
	if err := readJSON(s.filePath("health_state.json"), &states); err != nil {
		return make(map[string]bool)
	}
	m := make(map[string]bool, len(states))
	for _, st := range states {
		m[st.URL] = st.Healthy
	}
	return m
}
