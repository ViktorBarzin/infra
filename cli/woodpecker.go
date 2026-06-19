package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Woodpecker is reached at ci.viktorbarzin.me but routed via the internal Traefik
// LB (mirrors the proven `curl --resolve ci.viktorbarzin.me:443:10.0.20.203`):
// we dial the LB IP while keeping SNI/Host = the hostname so the cert verifies.
const (
	wpHost = "ci.viktorbarzin.me"
	wpLBIP = "10.0.20.203"
)

type wpClient struct {
	base  string
	token string
	http  *http.Client
}

// wpToken reads WOODPECKER_TOKEN, else the canonical Vault path.
func wpToken() string {
	if t := firstEnv("WOODPECKER_TOKEN", "WP_TOKEN"); t != "" {
		return t
	}
	out, err := exec.Command("vault", "kv", "get", "-field=woodpecker_api_token", "secret/ci/global").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func newWPClient() (*wpClient, error) {
	tok := wpToken()
	if tok == "" {
		return nil, fmt.Errorf("no woodpecker token — set WOODPECKER_TOKEN or `vault login` (reads secret/ci/global)")
	}
	ip := firstEnv("HOMELAB_WP_IP")
	if ip == "" {
		ip = wpLBIP
	}
	dialer := &net.Dialer{Timeout: 8 * time.Second}
	tr := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			if strings.HasPrefix(addr, wpHost+":") {
				addr = ip + addr[strings.LastIndex(addr, ":"):]
			}
			return dialer.DialContext(ctx, network, addr)
		},
	}
	return &wpClient{base: "https://" + wpHost, token: tok, http: &http.Client{Timeout: 20 * time.Second, Transport: tr}}, nil
}

// getJSON GETs path into v, retrying the transient empty/5xx responses the
// Woodpecker API intermittently returns under load.
func (c *wpClient) getJSON(path string, v interface{}) error {
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		if attempt > 0 {
			time.Sleep(2 * time.Second)
		}
		req, _ := http.NewRequest("GET", c.base+path, nil)
		req.Header.Set("Authorization", "Bearer "+c.token)
		resp, err := c.http.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode >= 500 || len(strings.TrimSpace(string(body))) == 0 {
			lastErr = fmt.Errorf("woodpecker GET %s -> %d (empty/5xx, retrying)", path, resp.StatusCode)
			continue
		}
		if resp.StatusCode >= 300 {
			return fmt.Errorf("woodpecker GET %s -> %d: %s", path, resp.StatusCode, strings.TrimSpace(string(body)))
		}
		return json.Unmarshal(body, v)
	}
	return lastErr
}

type wpPipeline struct {
	Number  int    `json:"number"`
	Status  string `json:"status"`
	Event   string `json:"event"`
	Commit  string `json:"commit"`
	Message string `json:"message"`
}

func (c *wpClient) recentPipelines(repoID, n int) ([]wpPipeline, error) {
	var ps []wpPipeline
	err := c.getJSON(fmt.Sprintf("/api/repos/%d/pipelines?per_page=%d", repoID, n), &ps)
	return ps, err
}

// findPipeline returns the pipeline for commit (prefix match), or the latest when
// commit is empty.
func (c *wpClient) findPipeline(repoID int, commit string) (wpPipeline, error) {
	ps, err := c.recentPipelines(repoID, 25)
	if err != nil {
		return wpPipeline{}, err
	}
	if len(ps) == 0 {
		return wpPipeline{}, fmt.Errorf("no pipelines for repo %d", repoID)
	}
	if commit == "" {
		return ps[0], nil
	}
	for _, p := range ps {
		if strings.HasPrefix(p.Commit, commit) {
			return p, nil
		}
	}
	return wpPipeline{}, fmt.Errorf("no pipeline for commit %s in the last %d", commit[:min(8, len(commit))], len(ps))
}

func (c *wpClient) repoID() (int, error) {
	owner, repo, err := repoOwnerName()
	if err != nil {
		return 0, err
	}
	var r struct {
		ID int `json:"id"`
	}
	if err := c.getJSON("/api/repos/lookup/"+owner+"/"+repo, &r); err != nil {
		return 0, err
	}
	if r.ID == 0 {
		return 0, fmt.Errorf("repo %s/%s not registered in woodpecker", owner, repo)
	}
	return r.ID, nil
}

// repoOwnerName derives <owner>/<repo> from the cwd git remote.
func repoOwnerName() (string, string, error) {
	cwd, _ := os.Getwd()
	root, err := gitRepoRoot(cwd)
	if err != nil {
		return "", "", fmt.Errorf("not in a git repository: %w", err)
	}
	remote := preferRemote(remotesOrEmpty(root))
	url, err := gitOutput(root, "remote", "get-url", remote)
	if err != nil {
		return "", "", err
	}
	return parseOwnerRepo(url)
}

// parseOwnerRepo extracts owner/repo from an https or ssh git remote URL.
func parseOwnerRepo(url string) (string, string, error) {
	u := strings.TrimSuffix(strings.TrimSpace(url), ".git")
	u = strings.TrimSuffix(u, "/")
	if i := strings.Index(u, "://"); i >= 0 {
		u = u[i+3:]
	}
	u = strings.ReplaceAll(u, ":", "/") // git@host:owner/repo -> git@host/owner/repo
	parts := strings.Split(u, "/")
	if len(parts) < 2 || parts[len(parts)-1] == "" || parts[len(parts)-2] == "" {
		return "", "", fmt.Errorf("cannot parse owner/repo from remote %q", url)
	}
	return parts[len(parts)-2], parts[len(parts)-1], nil
}

func isTerminalStatus(s string) bool {
	switch s {
	case "success", "failure", "error", "killed", "declined", "blocked":
		return true
	}
	return false
}

func isFailureStatus(s string) bool {
	return s == "failure" || s == "error" || s == "killed" || s == "declined"
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
