package store

import (
	"fmt"

	"f1-stream/internal/models"

	"github.com/go-webauthn/webauthn/webauthn"
)

func (s *Store) LoadUsers() ([]models.User, error) {
	s.usersMu.RLock()
	defer s.usersMu.RUnlock()
	var users []models.User
	if err := readJSON(s.filePath("users.json"), &users); err != nil {
		return nil, err
	}
	return users, nil
}

func (s *Store) GetUserByName(username string) (*models.User, error) {
	s.usersMu.RLock()
	defer s.usersMu.RUnlock()
	var users []models.User
	if err := readJSON(s.filePath("users.json"), &users); err != nil {
		return nil, err
	}
	for _, u := range users {
		if u.Username == username {
			return &u, nil
		}
	}
	return nil, nil
}

func (s *Store) GetUserByID(id string) (*models.User, error) {
	s.usersMu.RLock()
	defer s.usersMu.RUnlock()
	var users []models.User
	if err := readJSON(s.filePath("users.json"), &users); err != nil {
		return nil, err
	}
	for _, u := range users {
		if u.ID == id {
			return &u, nil
		}
	}
	return nil, nil
}

func (s *Store) CreateUser(user models.User) error {
	s.usersMu.Lock()
	defer s.usersMu.Unlock()
	var users []models.User
	if err := readJSON(s.filePath("users.json"), &users); err != nil {
		return err
	}
	for _, u := range users {
		if u.Username == user.Username {
			return fmt.Errorf("username already exists")
		}
	}
	users = append(users, user)
	return writeJSON(s.filePath("users.json"), users)
}

func (s *Store) UpdateUserCredentials(userID string, creds []webauthn.Credential) error {
	s.usersMu.Lock()
	defer s.usersMu.Unlock()
	var users []models.User
	if err := readJSON(s.filePath("users.json"), &users); err != nil {
		return err
	}
	for i, u := range users {
		if u.ID == userID {
			users[i].Credentials = creds
			return writeJSON(s.filePath("users.json"), users)
		}
	}
	return fmt.Errorf("user not found")
}

func (s *Store) UserCount() (int, error) {
	s.usersMu.RLock()
	defer s.usersMu.RUnlock()
	var users []models.User
	if err := readJSON(s.filePath("users.json"), &users); err != nil {
		return 0, err
	}
	return len(users), nil
}
