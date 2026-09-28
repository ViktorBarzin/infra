package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func videoCommands() []Command {
	return []Command{
		{Path: []string{"video", "get"}, Tier: TierWrite,
			Summary: "download videos (X, YouTube, any yt-dlp site) to Videos/ in your Nextcloud with a phone link: video get <url>... [--quality Q] [--expire DAYS] [--no-link]",
			Run:     videoGet},
	}
}

func videoGet(args []string) error {
	opts, err := parseVideoArgs(args)
	if err != nil {
		return err
	}
	if opts.help {
		fmt.Print(videoUsage)
		return nil
	}
	if _, err := exec.LookPath("yt-dlp"); err != nil {
		return fmt.Errorf("yt-dlp is not on PATH; the devvm playbook installs it at /usr/local/bin/yt-dlp")
	}
	user, pass, err := nextcloudCreds()
	if err != nil {
		return err
	}
	up := ncUploader{host: nextcloudHost, user: user, pass: pass, chunkSize: videoChunkSize,
		client: &http.Client{Timeout: 15 * time.Minute}, log: os.Stderr, backoff: 2 * time.Second}

	failed := 0
	for i, u := range opts.urls {
		if len(opts.urls) > 1 {
			fmt.Fprintf(os.Stderr, "[%d/%d] %s\n", i+1, len(opts.urls), u)
		}
		if err := getOneVideo(u, opts, up); err != nil {
			failed++
			fmt.Fprintf(os.Stderr, "homelab video get: %s: %v\n", u, err)
		}
	}
	if failed > 0 {
		return fmt.Errorf("%d of %d video(s) failed", failed, len(opts.urls))
	}
	return nil
}

func getOneVideo(videoURL string, opts videoArgs, up ncUploader) error {
	tmp, err := os.MkdirTemp("", "homelab-video-"+currentUser()+"-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)

	cookies := ""
	if isYouTube(videoURL) {
		fmt.Fprintln(os.Stderr, "fetching YouTube cookies from the cluster Chrome…")
		if cookies, err = fetchYouTubeCookies(videoURL, tmp); err != nil {
			return fmt.Errorf("could not get YouTube cookies: %w", err)
		}
	}

	cmd := exec.Command("yt-dlp", ytdlpArgs(videoURL, tmp, opts.quality, cookies)...)
	cmd.Stdout = os.Stderr // progress; stdout is kept for the path and link
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		hint := "the site may have changed; the daily yt-dlp-update timer keeps yt-dlp current"
		if cookies != "" {
			hint = "YouTube refuses some downloads from the homelab's address at random; retrying later sometimes works"
		}
		return fmt.Errorf("yt-dlp failed (%v); %s", err, hint)
	}
	recorded, _ := os.ReadFile(videoPathFile(tmp))
	local, err := finalVideoPath(string(recorded), tmp)
	if err != nil {
		return err
	}
	if out, err := exec.Command("ffprobe", "-v", "error", "-select_streams", "a",
		"-show_entries", "stream=codec_type", "-of", "csv=p=0", local).Output(); err != nil {
		fmt.Fprintf(os.Stderr, "warning: ffprobe could not read %s: %v\n", filepath.Base(local), err)
	} else if !hasAudioStream(string(out)) {
		fmt.Fprintf(os.Stderr, "warning: %s has no audio stream (fine if the clip is silent)\n", filepath.Base(local))
	}

	remote := remoteVideoPath(local)
	if err := up.upload(local, remote); err != nil {
		return err
	}
	fmt.Printf("path: %s\n", strings.TrimPrefix(remote, "/"))
	if opts.noLink {
		return nil
	}
	link, expiration, err := createPublicShare(up.user, up.pass, remote, opts.expireDays)
	if err != nil {
		return fmt.Errorf("uploaded, but the public link failed: %w", err)
	}
	fmt.Printf("link: %s\n", link)
	if expiration != "" {
		fmt.Printf("expires: %s\n", strings.Fields(expiration)[0])
	}
	return nil
}

// fetchYouTubeCookies runs the existing `browser run` verb as a subprocess
// (it owns the port-forward and pool sessions) and writes the youtube.com
// cookies it returns to a cookies.txt in dir.
func fetchYouTubeCookies(videoURL, dir string) (string, error) {
	script := filepath.Join(dir, "cookies.js")
	if err := os.WriteFile(script, []byte(youtubeCookieScript), 0o600); err != nil {
		return "", err
	}
	self, err := os.Executable()
	if err != nil {
		return "", err
	}
	var stdout bytes.Buffer
	cmd := exec.Command(self, "browser", "run", script, "--url", videoURL)
	cmd.Stdout = &stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("homelab browser run failed: %w", err)
	}
	raw, err := extractCookieJSON(stdout.String())
	if err != nil {
		return "", err
	}
	txt, err := cookiesToNetscape(raw)
	if err != nil {
		return "", err
	}
	out := filepath.Join(dir, "cookies.txt")
	return out, os.WriteFile(out, []byte(txt), 0o600)
}

// ncUploader streams a large file into Nextcloud with chunked upload v2, so no
// single request crosses the body-size limit and no chunk is held in memory.
type ncUploader struct {
	host, user, pass string
	chunkSize        int64
	client           *http.Client
	log              io.Writer
	backoff          time.Duration // base wait between retries; doubles each time
}

const uploadAttempts = 3

func (u ncUploader) filesURL(remote string) string {
	return u.host + "/remote.php/dav/files/" + url.PathEscape(u.user) + encodePath(remote)
}

// do sends the request built by mk, retrying transport errors and 5xx up to
// uploadAttempts times. A 401 stops at once with a readable error. It returns
// the last status code, 0 if no response ever came back.
func (u ncUploader) do(what string, mk func() (*http.Request, error)) (int, error) {
	var lastErr error
	status := 0
	for attempt := 1; attempt <= uploadAttempts; attempt++ {
		if attempt > 1 && u.backoff > 0 {
			time.Sleep(u.backoff << (attempt - 2))
		}
		req, err := mk()
		if err != nil {
			return 0, err
		}
		req.SetBasicAuth(u.user, u.pass)
		req.Header.Set("User-Agent", homelabUserAgent())
		resp, err := u.client.Do(req)
		if err != nil {
			lastErr = err
			fmt.Fprintf(u.log, "%s: %v (attempt %d/%d)\n", what, err, attempt, uploadAttempts)
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		resp.Body.Close()
		status = resp.StatusCode
		if status == http.StatusUnauthorized {
			return status, fmt.Errorf("Nextcloud rejected the credential (401) — is the app password still valid?")
		}
		if status < 500 {
			return status, nil
		}
		lastErr = fmt.Errorf("%d %s", status, truncateForError(string(body)))
		fmt.Fprintf(u.log, "%s: %v (attempt %d/%d)\n", what, lastErr, attempt, uploadAttempts)
	}
	return status, fmt.Errorf("%s failed after %d attempts: %w", what, uploadAttempts, lastErr)
}

func (u ncUploader) upload(local, remote string) (err error) {
	st, err := os.Stat(local)
	if err != nil {
		return err
	}
	size := st.Size()
	if size == 0 {
		return fmt.Errorf("%s is empty", filepath.Base(local))
	}
	f, err := os.Open(local)
	if err != nil {
		return err
	}
	defer f.Close()

	status, err := u.do("creating "+path.Dir(remote), func() (*http.Request, error) {
		return http.NewRequest("MKCOL", u.filesURL(path.Dir(remote)), nil)
	})
	if err != nil {
		return err
	}
	if status >= 300 && status != http.StatusMethodNotAllowed { // 405: already exists
		return fmt.Errorf("creating %s failed: %d", path.Dir(remote), status)
	}

	id := make([]byte, 8)
	rand.Read(id)
	uploadDir := u.host + "/remote.php/dav/uploads/" + url.PathEscape(u.user) + "/homelab-video-" + hex.EncodeToString(id)
	dest := u.filesURL(remote)
	total := strconv.FormatInt(size, 10)
	defer func() {
		if err != nil { // Nextcloud removes the upload folder itself on success
			if req, e := http.NewRequest("DELETE", uploadDir, nil); e == nil {
				req.SetBasicAuth(u.user, u.pass)
				if resp, e := u.client.Do(req); e == nil {
					resp.Body.Close()
				}
			}
		}
	}()

	status, err = u.do("starting the upload", func() (*http.Request, error) {
		req, err := http.NewRequest("MKCOL", uploadDir, nil)
		if err == nil {
			req.Header.Set("Destination", dest)
		}
		return req, err
	})
	if err != nil {
		return err
	}
	if status >= 300 {
		return fmt.Errorf("starting the upload failed: %d", status)
	}

	plan := chunkPlan(size, u.chunkSize)
	for i, c := range plan {
		fmt.Fprintf(u.log, "uploading chunk %d/%d\n", i+1, len(plan))
		c := c
		status, err := u.do("chunk "+c.name, func() (*http.Request, error) {
			req, err := http.NewRequest("PUT", uploadDir+"/"+c.name, io.NewSectionReader(f, c.offset, c.length))
			if err == nil {
				req.ContentLength = c.length
				req.Header.Set("Destination", dest)
				req.Header.Set("OC-Total-Length", total)
			}
			return req, err
		})
		if err != nil {
			return err
		}
		if status >= 300 {
			return fmt.Errorf("chunk %s failed: %d", c.name, status)
		}
	}

	// The MOVE status does not decide success: a MOVE retried after a lost
	// response answers 404 although Nextcloud already assembled the file.
	moveStatus, moveErr := u.do("assembling the file", func() (*http.Request, error) {
		req, err := http.NewRequest("MOVE", uploadDir+"/.file", nil)
		if err == nil {
			req.Header.Set("Destination", dest)
			req.Header.Set("OC-Total-Length", total)
			req.Header.Set("Overwrite", "T")
		}
		return req, err
	})
	got, ok := u.remoteSize(remote)
	if ok && got == size {
		return nil
	}
	if moveErr != nil {
		return moveErr
	}
	if !ok {
		return fmt.Errorf("upload finished (MOVE %d) but %s is not in Nextcloud", moveStatus, remote)
	}
	return fmt.Errorf("upload finished (MOVE %d) but %s is %d bytes, want %d", moveStatus, remote, got, size)
}

// remoteSize asks Nextcloud for the file's size with a Depth: 0 PROPFIND.
func (u ncUploader) remoteSize(remote string) (int64, bool) {
	const body = `<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getcontentlength/></d:prop></d:propfind>`
	req, err := http.NewRequest("PROPFIND", u.filesURL(remote), strings.NewReader(body))
	if err != nil {
		return 0, false
	}
	req.SetBasicAuth(u.user, u.pass)
	req.Header.Set("Depth", "0")
	req.Header.Set("User-Agent", homelabUserAgent())
	resp, err := u.client.Do(req)
	if err != nil {
		return 0, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != 207 {
		return 0, false
	}
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	return parsePropfindSize(string(b))
}
