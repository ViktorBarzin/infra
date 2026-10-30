package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"syscall"
	"time"
)

// acquireReleaseLock takes an exclusive flock on path, waiting up to wait for
// a release already holding it, and writes note into the file so the next
// caller can say who it is waiting for. The returned func releases the lock.
//
// The file is opened WITHOUT O_CREAT first: /run/lock is sticky and
// world-writable, and fs.protected_regular refuses an O_CREAT open of a file
// there that another user owns, even with mode 0666. The devvm playbook
// creates it root-owned (f1-stream-release.conf in tmpfiles.d); creating it
// here is only the fallback for a box without that entry.
func acquireReleaseLock(path string, wait time.Duration, note string, out io.Writer) (func(), error) {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if errors.Is(err, os.ErrPermission) {
		f, err = os.OpenFile(path, os.O_RDONLY, 0)
	}
	if errors.Is(err, os.ErrNotExist) {
		f, err = os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o666)
		if err == nil {
			_ = f.Chmod(0o666)
		}
	}
	if err != nil {
		return nil, fmt.Errorf("open release lock %s: %w", path, err)
	}
	deadline := time.Now().Add(wait)
	announced := false
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			f.Close()
			return nil, fmt.Errorf("lock %s: %w", path, err)
		}
		holder := readLockNote(path)
		if time.Now().After(deadline) {
			f.Close()
			return nil, fmt.Errorf("another release still holds %s after %s (%s)", path, wait, holder)
		}
		if !announced {
			fmt.Fprintf(out, "homelab: another release is running (%s); waiting for it to finish\n", holder)
			announced = true
		}
		time.Sleep(200 * time.Millisecond)
	}
	if err := f.Truncate(0); err == nil {
		_, _ = f.WriteAt([]byte(note+"\n"), 0)
	}
	return func() {
		_ = f.Truncate(0)
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, nil
}

func readLockNote(path string) string {
	b, err := os.ReadFile(path)
	if err != nil || len(bytes.TrimSpace(b)) == 0 {
		return "holder unknown"
	}
	return strings.TrimSpace(string(b))
}

// registryClient asks ghcr (or any registry with the same token flow) whether
// a tag exists, with the release bot's credential. Nothing is pulled.
type registryClient struct {
	base  string // https://ghcr.io
	user  string
	token string
	http  *http.Client
}

type ociManifest struct {
	Layers []struct {
		Digest      string            `json:"digest"`
		Annotations map[string]string `json:"annotations"`
	} `json:"layers"`
}

// layerDigest returns the hex sha256 of the layer titled name (oras sets the
// title to the pushed file name), which is the sha256 of that file.
func (m *ociManifest) layerDigest(name string) string {
	for _, l := range m.Layers {
		if l.Annotations["org.opencontainers.image.title"] == name {
			return strings.TrimPrefix(l.Digest, "sha256:")
		}
	}
	return ""
}

// repoPath turns ghcr.io/owner/name into owner/name.
func repoPath(image string) string {
	if i := strings.Index(image, "/"); i >= 0 && strings.Contains(image[:i], ".") {
		return image[i+1:]
	}
	return image
}

func (r *registryClient) bearer(repo string) (string, error) {
	q := url.Values{"service": {"ghcr.io"}, "scope": {"repository:" + repo + ":pull"}}
	req, _ := http.NewRequest("GET", r.base+"/token?"+q.Encode(), nil)
	req.SetBasicAuth(r.user, r.token)
	resp, err := r.http.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("registry refused the release credential for %s (HTTP %d)", repo, resp.StatusCode)
	}
	var t struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&t); err != nil || t.Token == "" {
		return "", fmt.Errorf("registry token for %s: unreadable answer", repo)
	}
	return t.Token, nil
}

// manifest returns the manifest of image:tag, ok=false when the tag does not exist.
func (r *registryClient) manifest(image, tag string) (*ociManifest, bool, error) {
	repo := repoPath(image)
	tok, err := r.bearer(repo)
	if err != nil {
		return nil, false, err
	}
	req, _ := http.NewRequest("GET", r.base+"/v2/"+repo+"/manifests/"+tag, nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", strings.Join([]string{
		"application/vnd.oci.image.manifest.v1+json",
		"application/vnd.oci.image.index.v1+json",
		"application/vnd.docker.distribution.manifest.v2+json",
		"application/vnd.docker.distribution.manifest.list.v2+json",
	}, ", "))
	resp, err := r.http.Do(req)
	if err != nil {
		return nil, false, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	switch {
	case resp.StatusCode == http.StatusNotFound:
		return nil, false, nil
	case resp.StatusCode != http.StatusOK:
		return nil, false, fmt.Errorf("registry GET %s:%s -> HTTP %d", image, tag, resp.StatusCode)
	}
	var m ociManifest
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, false, fmt.Errorf("manifest %s:%s: %w", image, tag, err)
	}
	return &m, true, nil
}

// newWPClientWithToken is newWPClient with an explicit token (the release
// bot's, from Vault), dialled through the internal LB the same way.
func newWPClientWithToken(tok string) *wpClient {
	c, _ := newWPClientFor(tok)
	return c
}

// startManualPipeline starts a manual pipeline on master with variables, the
// same POST the GitHub Actions workflows make, and returns its number.
func (c *wpClient) startManualPipeline(repoID int, vars map[string]string) (int, error) {
	body, _ := json.Marshal(map[string]interface{}{"branch": "master", "variables": vars})
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(10 * time.Second)
		}
		req, _ := http.NewRequest("POST", fmt.Sprintf("%s/api/repos/%d/pipelines", c.base, repoID), bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+c.token)
		req.Header.Set("Content-Type", "application/json")
		resp, err := c.http.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode >= 300 {
			lastErr = fmt.Errorf("woodpecker POST pipelines on repo %d -> HTTP %d: %s", repoID, resp.StatusCode, strings.TrimSpace(string(b)))
			if resp.StatusCode < 500 {
				return 0, lastErr
			}
			continue
		}
		var p struct {
			Number int `json:"number"`
		}
		if err := json.Unmarshal(b, &p); err != nil || p.Number == 0 {
			return 0, fmt.Errorf("woodpecker started a pipeline but its answer had no number: %s", strings.TrimSpace(string(b)))
		}
		return p.Number, nil
	}
	return 0, lastErr
}

type wpPipelineDetail struct {
	Number    int    `json:"number"`
	Status    string `json:"status"`
	Workflows []struct {
		Name     string `json:"name"`
		State    string `json:"state"`
		Children []struct {
			Name  string `json:"name"`
			State string `json:"state"`
		} `json:"children"`
	} `json:"workflows"`
}

func (p wpPipelineDetail) failedSteps() []string {
	var out []string
	for _, w := range p.Workflows {
		for _, s := range w.Children {
			if isFailureStatus(s.State) {
				out = append(out, s.Name)
			}
		}
	}
	return out
}

func (c *wpClient) pipeline(repoID, number int) (wpPipelineDetail, error) {
	var p wpPipelineDetail
	err := c.getJSON(fmt.Sprintf("/api/repos/%d/pipelines/%d", repoID, number), &p)
	return p, err
}

// waitPipeline polls a pipeline until it ends, printing each status change.
func (c *wpClient) waitPipeline(repoID, number int, timeout time.Duration, out io.Writer) (wpPipelineDetail, error) {
	deadline := time.Now().Add(timeout)
	last := ""
	for {
		p, err := c.pipeline(repoID, number)
		if err == nil {
			if p.Status != last {
				fmt.Fprintf(out, "homelab: Woodpecker repo %d pipeline %d: %s\n", repoID, number, p.Status)
				last = p.Status
			}
			if isTerminalStatus(p.Status) {
				return p, nil
			}
		}
		if time.Now().After(deadline) {
			return p, fmt.Errorf("Woodpecker repo %d pipeline %d still %q after %s", repoID, number, last, timeout)
		}
		time.Sleep(5 * time.Second)
	}
}
