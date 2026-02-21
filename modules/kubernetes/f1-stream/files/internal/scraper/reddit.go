package scraper

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"f1-stream/internal/models"
)

const (
	subredditURL = "https://www.reddit.com/r/motorsportsstreams2/new.json?limit=25"
	userAgent    = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
	requestDelay = 1 * time.Second
)

var (
	urlRe = regexp.MustCompile(`https?://[^\s\)\]\>"]+`)

	// Keywords in post title that indicate F1 content (matched case-insensitively)
	f1Keywords = []string{
		"f1",
		"formula 1",
		"formula one",
		"formula1",
		"grand prix",
		"gp qualifying",
		"gp race",
		"gp sprint",
		"gp practice",
	}

	f1NegativeKeywords = []string{
		"f1 key",
		"function 1",
		"help f1",
	}

	// URLs to filter out (not stream sources)
	filteredDomains = map[string]bool{
		"reddit.com":     true,
		"www.reddit.com": true,
		"imgur.com":      true,
		"i.imgur.com":    true,
		"redd.it":        true,
		"i.redd.it":      true,
		"v.redd.it":      true,
		"youtu.be":       true,
		"youtube.com":    true,
		"twitter.com":    true,
		"x.com":          true,
	}
)

type redditListing struct {
	Data struct {
		Children []struct {
			Data struct {
				Title     string  `json:"title"`
				SelfText  string  `json:"selftext"`
				Permalink string  `json:"permalink"`
				CreatedUTC float64 `json:"created_utc"`
			} `json:"data"`
		} `json:"children"`
	} `json:"data"`
}

type redditComments []struct {
	Data struct {
		Children []struct {
			Data struct {
				Body    string `json:"body"`
				Replies json.RawMessage `json:"replies"`
			} `json:"data"`
		} `json:"children"`
	} `json:"data"`
}

func scrapeReddit() ([]models.ScrapedLink, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	var allLinks []models.ScrapedLink
	seen := make(map[string]bool)

	log.Printf("scraper: fetching listing from %s", subredditURL)
	listing, err := fetchJSON[redditListing](client, subredditURL)
	if err != nil {
		return nil, fmt.Errorf("fetch listing: %w", err)
	}

	totalPosts := len(listing.Data.Children)
	matchedPosts := 0
	log.Printf("scraper: got %d posts from listing", totalPosts)

	for _, child := range listing.Data.Children {
		post := child.Data

		if !isF1Post(post.Title) {
			log.Printf("scraper: skipped post: %s", truncate(post.Title, 60))
			continue
		}

		matchedPosts++
		log.Printf("scraper: matched post: %s", truncate(post.Title, 60))

		selftextLinks := extractURLs(post.SelfText, post.Title)
		log.Printf("scraper: extracted %d URLs from selftext of %q", len(selftextLinks), truncate(post.Title, 40))
		for _, link := range selftextLinks {
			norm := normalizeURL(link.URL)
			if !seen[norm] {
				seen[norm] = true
				allLinks = append(allLinks, link)
			}
		}

		time.Sleep(requestDelay)
		commentsURL := fmt.Sprintf("https://www.reddit.com%s.json", post.Permalink)
		comments, err := fetchJSONWithRetry[redditComments](client, commentsURL, 3)
		if err != nil {
			log.Printf("scraper: failed to fetch comments for %s: %v", post.Permalink, err)
			continue
		}

		commentURLCount := 0
		walkComments(*comments, func(body string) {
			links := extractURLs(body, post.Title)
			commentURLCount += len(links)
			for _, link := range links {
				norm := normalizeURL(link.URL)
				if !seen[norm] {
					seen[norm] = true
					allLinks = append(allLinks, link)
				}
			}
		})
		log.Printf("scraper: extracted %d URLs from comments of %q", commentURLCount, truncate(post.Title, 40))

		time.Sleep(requestDelay)
	}

	log.Printf("scraper: summary — matched %d/%d posts, extracted %d unique URLs", matchedPosts, totalPosts, len(allLinks))
	return allLinks, nil
}

func fetchJSON[T any](client *http.Client, rawURL string) (*T, error) {
	req, err := http.NewRequest("GET", rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	log.Printf("scraper: GET %s -> %d", truncate(rawURL, 80), resp.StatusCode)

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 5*1024*1024))
	if err != nil {
		return nil, err
	}

	var result T
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

func fetchJSONWithRetry[T any](client *http.Client, rawURL string, maxRetries int) (*T, error) {
	var lastErr error
	for attempt := 0; attempt <= maxRetries; attempt++ {
		result, err := fetchJSON[T](client, rawURL)
		if err == nil {
			return result, nil
		}
		lastErr = err

		errMsg := err.Error()
		if strings.Contains(errMsg, "status 429") {
			log.Printf("scraper: rate limited on %s, backing off 30s", truncate(rawURL, 60))
			time.Sleep(30 * time.Second)
			continue
		}
		if strings.Contains(errMsg, "status 502") || strings.Contains(errMsg, "status 503") {
			backoff := time.Duration(math.Pow(2, float64(attempt))) * time.Second
			log.Printf("scraper: server error on %s, retry %d/%d in %v", truncate(rawURL, 60), attempt+1, maxRetries, backoff)
			time.Sleep(backoff)
			continue
		}

		return nil, err
	}
	return nil, fmt.Errorf("after %d retries: %w", maxRetries, lastErr)
}

// deobfuscateText normalises obfuscated URLs commonly posted on Reddit to
// evade auto-moderation.  Examples:
//   - "pitsport . xyz/watch/f1" → "https://pitsport.xyz/watch/f1"
//   - "dlhd dot link"           → "https://dlhd.link"
func deobfuscateText(text string) string {
	// Common TLDs used in streaming links.
	tlds := `(?:com|net|org|xyz|link|info|live|tv|me|cc|to|io|co|stream|site|fun|top|club|watch|racing)`

	// 1. Replace " dot " (case-insensitive) between word-like parts that
	//    look like domain components:  "dlhd dot link" → "dlhd.link"
	dotWord := regexp.MustCompile(`(?i)(\b\w[\w-]*)\s+dot\s+(` + tlds + `\b)`)
	text = dotWord.ReplaceAllString(text, "${1}.${2}")

	// 2. Collapse spaces around dots in domain-like strings:
	//    "pitsport . xyz" → "pitsport.xyz"
	spaceDot := regexp.MustCompile(`(\b\w[\w-]*)\s*\.\s*(` + tlds + `\b)`)
	text = spaceDot.ReplaceAllString(text, "${1}.${2}")

	// 3. Prepend https:// to bare domain-like strings that the URL regex
	//    would otherwise miss (no scheme present).
	bareDomain := regexp.MustCompile(`(?:^|[\s(>\[])(\w[\w-]*\.` + tlds + `(?:/[^\s)\]<"]*)?)`)
	text = bareDomain.ReplaceAllStringFunc(text, func(m string) string {
		// Preserve the leading whitespace/punctuation character.
		trimmed := strings.TrimLeft(m, " \t\n(>[")
		prefix := m[:len(m)-len(trimmed)]
		if strings.HasPrefix(trimmed, "http://") || strings.HasPrefix(trimmed, "https://") {
			return m
		}
		return prefix + "https://" + trimmed
	})

	return text
}

func extractURLs(text, postTitle string) []models.ScrapedLink {
	text = deobfuscateText(text)
	matches := urlRe.FindAllString(text, -1)
	var links []models.ScrapedLink
	filtered := 0
	for _, u := range matches {
		u = strings.TrimRight(u, ".,;:!?)")

		parsed, err := url.Parse(u)
		if err != nil {
			continue
		}
		if filteredDomains[parsed.Hostname()] {
			filtered++
			continue
		}

		id := make([]byte, 16)
		if _, err := rand.Read(id); err != nil {
			continue
		}

		links = append(links, models.ScrapedLink{
			ID:        fmt.Sprintf("%x", id),
			URL:       u,
			Title:     postTitle,
			Source:    "r/motorsportsstreams2",
			ScrapedAt: time.Now(),
		})
	}
	if filtered > 0 {
		log.Printf("scraper: filtered %d URLs from known domains in %q", filtered, truncate(postTitle, 40))
	}
	return links
}

func walkComments(comments redditComments, fn func(string)) {
	for _, listing := range comments {
		for _, child := range listing.Data.Children {
			if child.Data.Body != "" {
				fn(child.Data.Body)
			}
			// Recurse into replies
			if len(child.Data.Replies) > 0 && child.Data.Replies[0] == '{' {
				var nested redditComments
				if err := json.Unmarshal([]byte("["+string(child.Data.Replies)+"]"), &nested); err == nil {
					walkComments(nested, fn)
				}
			}
		}
	}
}

func normalizeURL(u string) string {
	parsed, err := url.Parse(u)
	if err != nil {
		return strings.ToLower(u)
	}
	parsed.Host = strings.ToLower(parsed.Host)
	path := strings.TrimRight(parsed.Path, "/")
	return fmt.Sprintf("%s://%s%s", parsed.Scheme, parsed.Host, path)
}

func isF1Post(title string) bool {
	lower := strings.ToLower(title)
	for _, neg := range f1NegativeKeywords {
		if strings.Contains(lower, neg) {
			return false
		}
	}
	for _, kw := range f1Keywords {
		if strings.Contains(lower, kw) {
			return true
		}
	}
	return false
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
