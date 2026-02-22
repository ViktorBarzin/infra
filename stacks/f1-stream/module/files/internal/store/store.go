package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

type Store struct {
	dir         string
	streamsMu   sync.RWMutex
	usersMu     sync.RWMutex
	scrapedMu   sync.RWMutex
	sessionsMu  sync.RWMutex
	healthMu    sync.RWMutex
}

func New(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0755); err != nil {
		return nil, err
	}
	return &Store{dir: dir}, nil
}

func (s *Store) filePath(name string) string {
	return filepath.Join(s.dir, name)
}

// readJSON reads a JSON file into the target. Returns nil if file doesn't exist.
func readJSON(path string, target interface{}) error {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	return json.Unmarshal(data, target)
}

// writeJSON atomically writes target as JSON to path using temp-file-then-rename.
func writeJSON(path string, data interface{}) error {
	b, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
