package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// defaultMemoryURL is used when no env override is present (agents normally have
// CLAUDE_MEMORY_API_URL set by the memory hooks).
const defaultMemoryURL = "https://claude-memory.viktorbarzin.me"

type memoryClient struct {
	base string
	key  string
	http *http.Client
}

func firstEnv(keys ...string) string {
	for _, k := range keys {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	return ""
}

func resolveMemoryBase() string {
	if b := firstEnv("CLAUDE_MEMORY_API_URL", "MEMORY_API_URL"); b != "" {
		return strings.TrimRight(b, "/")
	}
	return defaultMemoryURL
}

// newMemoryClient talks straight to the claude-memory HTTP API (the same backend
// the MCP wraps), so it works even when the MCP frontend is down.
func newMemoryClient() (*memoryClient, error) {
	key := firstEnv("CLAUDE_MEMORY_API_KEY", "MEMORY_API_KEY")
	if key == "" {
		return nil, fmt.Errorf("no memory API key — set CLAUDE_MEMORY_API_KEY (or MEMORY_API_KEY)")
	}
	return &memoryClient{base: resolveMemoryBase(), key: key, http: &http.Client{Timeout: 30 * time.Second}}, nil
}

func (c *memoryClient) do(method, path string, body interface{}) ([]byte, error) {
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.base+path, r)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.key)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("memory API %s %s -> %d: %s", method, path, resp.StatusCode, strings.TrimSpace(string(out)))
	}
	return out, nil
}

// Request bodies mirror src/claude_memory/api/models.py.

type memRecallReq struct {
	Context       string `json:"context"`
	ExpandedQuery string `json:"expanded_query,omitempty"`
	Category      string `json:"category,omitempty"`
	SortBy        string `json:"sort_by,omitempty"`
	Limit         int    `json:"limit,omitempty"`
}

type memStoreReq struct {
	Content          string  `json:"content"`
	Category         string  `json:"category,omitempty"`
	Tags             string  `json:"tags,omitempty"`
	ExpandedKeywords string  `json:"expanded_keywords,omitempty"`
	Importance       float64 `json:"importance"`
	ForceSensitive   bool    `json:"force_sensitive,omitempty"`
}

type memUpdateReq struct {
	Content          *string  `json:"content,omitempty"`
	Tags             *string  `json:"tags,omitempty"`
	Importance       *float64 `json:"importance,omitempty"`
	ExpandedKeywords *string  `json:"expanded_keywords,omitempty"`
}
