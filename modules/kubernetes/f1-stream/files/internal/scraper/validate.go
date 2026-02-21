package scraper

import (
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"f1-stream/internal/models"
)

// videoMarkers are substrings checked (case-insensitively) against the HTML
// body to detect the presence of a video player or streaming manifest.
var videoMarkers = []string{
	// HTML5 video element
	"<video",
	// HLS manifests
	".m3u8",
	"application/x-mpegurl",
	"application/vnd.apple.mpegurl",
	// DASH manifests
	".mpd",
	"application/dash+xml",
	// Player libraries
	"hls.js",
	"hls.min.js",
	"dash.js",
	"dash.all.min.js",
	"video.js",
	"video.min.js",
	"videojs",
	"jwplayer",
	"clappr",
	"flowplayer",
	"plyr",
	"shaka-player",
	"mediaelement",
	"fluidplayer",
}

// videoContentTypes are Content-Type prefixes/substrings that indicate a
// direct video response (no HTML inspection needed).
var videoContentTypes = []string{
	"video/",
	"application/x-mpegurl",
	"application/vnd.apple.mpegurl",
	"application/dash+xml",
}

// validateBodyLimit caps how much HTML we read when looking for markers.
const validateBodyLimit = 2 * 1024 * 1024 // 2 MB

// validateLinks fetches each link and keeps only those whose response
// contains video/player content markers.
func validateLinks(links []models.ScrapedLink, timeout time.Duration) []models.ScrapedLink {
	client := &http.Client{
		Timeout: timeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 3 {
				return http.ErrUseLastResponse
			}
			return nil
		},
	}

	var kept []models.ScrapedLink
	for _, link := range links {
		if HasVideoContent(client, link.URL) {
			kept = append(kept, link)
		} else {
			log.Printf("scraper: discarded %s (no video markers)", truncate(link.URL, 60))
		}
	}
	return kept
}

// HasVideoContent performs a GET request for rawURL and returns true if the
// response is a direct video file (by Content-Type) or an HTML page that
// contains at least one video marker substring.
func HasVideoContent(client *http.Client, rawURL string) bool {
	req, err := http.NewRequest("GET", rawURL, nil)
	if err != nil {
		log.Printf("scraper: validate request error for %s: %v", truncate(rawURL, 60), err)
		return false
	}
	req.Header.Set("User-Agent", userAgent)

	resp, err := client.Do(req)
	if err != nil {
		log.Printf("scraper: validate fetch error for %s: %v", truncate(rawURL, 60), err)
		return false
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 400 {
		return false
	}

	ct := strings.ToLower(resp.Header.Get("Content-Type"))

	// Direct video content type — no need to inspect body.
	if isDirectVideoContentType(ct) {
		return true
	}

	// Only inspect HTML pages for markers.
	if !strings.Contains(ct, "text/html") && !strings.Contains(ct, "application/xhtml") {
		return false
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, validateBodyLimit))
	if err != nil {
		log.Printf("scraper: validate read error for %s: %v", truncate(rawURL, 60), err)
		return false
	}

	return containsVideoMarkers(strings.ToLower(string(body)))
}

// containsVideoMarkers returns true if loweredBody contains any known video
// player or streaming marker substring.
func containsVideoMarkers(loweredBody string) bool {
	for _, marker := range videoMarkers {
		if strings.Contains(loweredBody, marker) {
			return true
		}
	}
	return false
}

// isDirectVideoContentType returns true if ct (already lowercased) matches a
// known video content type.
func isDirectVideoContentType(ct string) bool {
	ct = strings.ToLower(ct)
	for _, vct := range videoContentTypes {
		if strings.Contains(ct, vct) {
			return true
		}
	}
	return false
}
