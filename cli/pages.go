package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// defaultPagesURL is the pages-publish service (renders a markdown doc to a
// styled HTML page served at pages.viktorbarzin.me). Overridable via
// PAGES_API_URL for tests / alternate deployments.
const defaultPagesURL = "https://pages-publish.viktorbarzin.me"

type pagesClient struct {
	base string
	key  string
	http *http.Client
}

func resolvePagesBase() string {
	if b := firstEnv("PAGES_API_URL"); b != "" {
		return strings.TrimRight(b, "/")
	}
	return defaultPagesURL
}

// newPagesClient talks straight to the pages-publish HTTP API. The API key is
// mandatory (the service is owner-only); base is env-overridable for tests.
func newPagesClient() (*pagesClient, error) {
	key := firstEnv("PAGES_API_KEY")
	if key == "" {
		return nil, fmt.Errorf("no pages API key — set PAGES_API_KEY")
	}
	return &pagesClient{base: resolvePagesBase(), key: key, http: &http.Client{Timeout: 30 * time.Second}}, nil
}

func (c *pagesClient) do(method, path string, body interface{}) ([]byte, error) {
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
		return nil, fmt.Errorf("pages API %s %s -> %d: %s", method, path, resp.StatusCode, strings.TrimSpace(string(out)))
	}
	return out, nil
}

// pagesPublishReq is the POST /publish body. All four fields are always sent
// (status defaults to "draft", shared to false) so the server never has to
// guess an omitted value.
type pagesPublishReq struct {
	Content  string `json:"content"`
	Filename string `json:"filename"`
	Status   string `json:"status"`
	Shared   bool   `json:"shared"`
}

// pagesPublishResp is the POST /publish response: the served page URL and its
// path within the pages site.
type pagesPublishResp struct {
	URL  string `json:"url"`
	Path string `json:"path"`
}
