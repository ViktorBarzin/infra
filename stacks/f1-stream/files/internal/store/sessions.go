package store

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"

	"f1-stream/internal/models"
)

func (s *Store) LoadSessions() ([]models.Session, error) {
	s.sessionsMu.RLock()
	defer s.sessionsMu.RUnlock()
	var sessions []models.Session
	if err := readJSON(s.filePath("sessions.json"), &sessions); err != nil {
		return nil, err
	}
	return sessions, nil
}

func (s *Store) CreateSession(userID string, ttl time.Duration) (string, error) {
	s.sessionsMu.Lock()
	defer s.sessionsMu.Unlock()
	var sessions []models.Session
	if err := readJSON(s.filePath("sessions.json"), &sessions); err != nil {
		return "", err
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	token := hex.EncodeToString(b)
	sess := models.Session{
		Token:     token,
		UserID:    userID,
		ExpiresAt: time.Now().Add(ttl),
	}
	sessions = append(sessions, sess)
	if err := writeJSON(s.filePath("sessions.json"), sessions); err != nil {
		return "", err
	}
	return token, nil
}

func (s *Store) GetSession(token string) (*models.Session, error) {
	s.sessionsMu.RLock()
	defer s.sessionsMu.RUnlock()
	var sessions []models.Session
	if err := readJSON(s.filePath("sessions.json"), &sessions); err != nil {
		return nil, err
	}
	for _, sess := range sessions {
		if sess.Token == token && time.Now().Before(sess.ExpiresAt) {
			return &sess, nil
		}
	}
	return nil, nil
}

func (s *Store) DeleteSession(token string) error {
	s.sessionsMu.Lock()
	defer s.sessionsMu.Unlock()
	var sessions []models.Session
	if err := readJSON(s.filePath("sessions.json"), &sessions); err != nil {
		return err
	}
	var updated []models.Session
	found := false
	for _, sess := range sessions {
		if sess.Token == token {
			found = true
			continue
		}
		updated = append(updated, sess)
	}
	if !found {
		return fmt.Errorf("session not found")
	}
	return writeJSON(s.filePath("sessions.json"), updated)
}

func (s *Store) CleanExpiredSessions() error {
	s.sessionsMu.Lock()
	defer s.sessionsMu.Unlock()
	var sessions []models.Session
	if err := readJSON(s.filePath("sessions.json"), &sessions); err != nil {
		return err
	}
	now := time.Now()
	var valid []models.Session
	for _, sess := range sessions {
		if now.Before(sess.ExpiresAt) {
			valid = append(valid, sess)
		}
	}
	return writeJSON(s.filePath("sessions.json"), valid)
}
