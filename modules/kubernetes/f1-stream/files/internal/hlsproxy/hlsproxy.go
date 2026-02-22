package hlsproxy

import (
	"bufio"
	"encoding/base64"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
)

// NewHandler returns an http.Handler for /hls/{base64url_encoded_full_url}.
// It proxies HLS playlists and segments, rewriting m3u8 URLs to route
// through the proxy and forwarding X-Hls-Forward-* headers upstream.
func NewHandler() http.Handler {
	client := &http.Client{
		Timeout: 30_000_000_000, // 30s
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return http.ErrUseLastResponse
			}
			return nil
		},
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			setCORS(w)
			w.WriteHeader(http.StatusNoContent)
			return
		}

		// Parse: /hls/{base64url_encoded_full_url}
		trimmed := strings.TrimPrefix(r.URL.Path, "/hls/")
		if trimmed == "" || trimmed == r.URL.Path {
			http.Error(w, "bad hls proxy URL", http.StatusBadRequest)
			return
		}

		// Decode the full upstream URL from base64url
		upstreamURL, err := base64.RawURLEncoding.DecodeString(trimmed)
		if err != nil {
			http.Error(w, "invalid base64url", http.StatusBadRequest)
			return
		}
		target := string(upstreamURL)

		parsed, err := url.Parse(target)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") {
			http.Error(w, "invalid upstream URL", http.StatusBadRequest)
			return
		}

		log.Printf("hlsproxy: %s -> %s", r.URL.Path, target)

		upReq, err := http.NewRequestWithContext(r.Context(), http.MethodGet, target, nil)
		if err != nil {
			http.Error(w, "failed to create request", http.StatusInternalServerError)
			return
		}

		// Set Referer and Origin. If the URL has a ?domain= param (CDN segments),
		// use that domain as the origin so the CDN accepts the request.
		refererOrigin := parsed.Scheme + "://" + parsed.Host
		if domainParam := parsed.Query().Get("domain"); domainParam != "" {
			refererOrigin = "https://" + domainParam
		}
		upReq.Header.Set("Referer", refererOrigin+"/")
		upReq.Header.Set("Origin", refererOrigin)
		upReq.Header.Set("User-Agent", r.Header.Get("User-Agent"))

		// Forward X-Hls-Forward-* headers (strip prefix)
		for key, vals := range r.Header {
			if strings.HasPrefix(key, "X-Hls-Forward-") {
				realKey := strings.TrimPrefix(key, "X-Hls-Forward-")
				for _, v := range vals {
					upReq.Header.Set(realKey, v)
				}
			}
		}

		resp, err := client.Do(upReq)
		if err != nil {
			log.Printf("hlsproxy: upstream fetch failed: %v", err)
			http.Error(w, "upstream fetch failed", http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()

		log.Printf("hlsproxy: %s <- %d (%s)", truncPath(r.URL.Path, 60), resp.StatusCode, resp.Header.Get("Content-Type"))

		setCORS(w)

		ct := resp.Header.Get("Content-Type")
		isM3U8 := strings.Contains(ct, "mpegurl") ||
			strings.Contains(ct, "x-mpegURL") ||
			strings.HasSuffix(parsed.Path, ".m3u8")

		if isM3U8 {
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			w.WriteHeader(resp.StatusCode)
			rewriteM3U8(w, resp.Body, target)
			return
		}

		// Stream segment or other content directly
		for key, vals := range resp.Header {
			lk := strings.ToLower(key)
			if lk == "content-type" || lk == "content-length" || lk == "cache-control" || lk == "accept-ranges" {
				for _, v := range vals {
					w.Header().Add(key, v)
				}
			}
		}
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	})
}

// rewriteM3U8 reads an m3u8 playlist from r, rewrites segment/playlist URLs
// to route through /hls/{b64}, and writes the result to w.
func rewriteM3U8(w io.Writer, r io.Reader, playlistURL string) {
	base, err := url.Parse(playlistURL)
	if err != nil {
		io.Copy(w, r)
		return
	}

	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		line := scanner.Text()

		if strings.HasPrefix(line, "#") {
			// Rewrite URI="..." in directives like #EXT-X-KEY, #EXT-X-MAP
			rewritten := rewriteURIAttribute(line, base)
			w.Write([]byte(rewritten))
			w.Write([]byte("\n"))
			continue
		}

		// Non-comment, non-empty lines are URLs
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			w.Write([]byte("\n"))
			continue
		}

		resolved := resolveURL(base, trimmed)
		encoded := encodeHLSURL(resolved)
		w.Write([]byte(encoded))
		w.Write([]byte("\n"))
	}
}

// rewriteURIAttribute rewrites URI="..." attributes in HLS directives.
func rewriteURIAttribute(line string, base *url.URL) string {
	// Look for URI="..." (case insensitive)
	uriIdx := strings.Index(strings.ToUpper(line), "URI=\"")
	if uriIdx == -1 {
		return line
	}

	// Find the actual position (preserving original case)
	prefix := line[:uriIdx+5] // everything up to and including URI="
	rest := line[uriIdx+5:]
	endQuote := strings.Index(rest, "\"")
	if endQuote == -1 {
		return line
	}

	uri := rest[:endQuote]
	suffix := rest[endQuote:] // closing quote and anything after

	resolved := resolveURL(base, uri)
	encoded := encodeHLSURL(resolved)

	return prefix + encoded + suffix
}

// resolveURL resolves a potentially relative URL against a base URL.
func resolveURL(base *url.URL, ref string) string {
	refURL, err := url.Parse(ref)
	if err != nil {
		return ref
	}
	return base.ResolveReference(refURL).String()
}

// encodeHLSURL encodes a full URL into /hls/{base64url} format.
func encodeHLSURL(fullURL string) string {
	encoded := base64.RawURLEncoding.EncodeToString([]byte(fullURL))
	return "/hls/" + encoded
}

func setCORS(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "*")
}

func truncPath(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
