package main

import (
	"encoding/json"
	"encoding/xml"
	"fmt"
	"math"
	"net/url"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// videoPropNS is the WebDAV namespace for the properties video get stores on
// each uploaded file, so a later run can compare without re-reading the video.
const videoPropNS = "https://viktorbarzin.me/ns/homelab-video"

// videoMeta is what yt-dlp reports about a link before anything downloads.
type videoMeta struct {
	ID       string  `json:"id"`
	Title    string  `json:"title"`
	Uploader string  `json:"uploader"`
	Duration float64 `json:"duration"`
}

func parseVideoMeta(raw string) (videoMeta, error) {
	var m videoMeta
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		return m, fmt.Errorf("yt-dlp printed metadata that is not JSON: %w", err)
	}
	if m.ID == "" {
		return m, fmt.Errorf("yt-dlp reported no video id")
	}
	return m, nil
}

// remoteVideo is one file already in Videos/. Duration 0 means unknown.
type remoteVideo struct {
	Path, Name, ID string
	Duration       float64
	Size           int64
}

var filenameIDRe = regexp.MustCompile(`\[([^\[\]]+)\]\.[A-Za-z0-9]+$`)

// idFromFilename reads the "[id]" yt-dlp puts before the extension.
func idFromFilename(name string) string {
	if m := filenameIDRe.FindStringSubmatch(name); m != nil {
		return m[1]
	}
	return ""
}

// parseVideoListing reads a Depth: 1 PROPFIND of Videos/, skipping folders.
// A stored id property wins over the one in the file name.
func parseVideoListing(body string) ([]remoteVideo, error) {
	type prop struct {
		Collection *struct{} `xml:"DAV: resourcetype>collection"`
		Length     string    `xml:"DAV: getcontentlength"`
		Duration   string    `xml:"https://viktorbarzin.me/ns/homelab-video duration"`
		ID         string    `xml:"https://viktorbarzin.me/ns/homelab-video id"`
	}
	type propstat struct {
		Prop   prop   `xml:"DAV: prop"`
		Status string `xml:"DAV: status"`
	}
	var ms struct {
		Responses []struct {
			Href      string     `xml:"DAV: href"`
			Propstats []propstat `xml:"DAV: propstat"`
		} `xml:"DAV: response"`
	}
	if err := xml.Unmarshal([]byte(body), &ms); err != nil {
		return nil, fmt.Errorf("could not read the Videos/ listing: %w", err)
	}
	var out []remoteVideo
	for _, r := range ms.Responses {
		href, err := url.PathUnescape(r.Href)
		if err != nil || strings.HasSuffix(href, "/") {
			continue
		}
		var p prop
		folder := false
		for _, ps := range r.Propstats {
			if !strings.Contains(ps.Status, " 200 ") {
				continue
			}
			folder = folder || ps.Prop.Collection != nil
			p.Length = firstNonEmpty(p.Length, ps.Prop.Length)
			p.Duration = firstNonEmpty(p.Duration, ps.Prop.Duration)
			p.ID = firstNonEmpty(p.ID, ps.Prop.ID)
		}
		if folder {
			continue
		}
		name := path.Base(href)
		v := remoteVideo{Path: videoUploadDir + name, Name: name, ID: strings.TrimSpace(p.ID)}
		if v.ID == "" {
			v.ID = idFromFilename(name)
		}
		v.Size, _ = strconv.ParseInt(strings.TrimSpace(p.Length), 10, 64)
		v.Duration, _ = strconv.ParseFloat(strings.TrimSpace(p.Duration), 64)
		out = append(out, v)
	}
	return out, nil
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// titleStopwords are words too common in post titles to say two are the same.
var titleStopwords = map[string]bool{
	"the": true, "and": true, "for": true, "with": true, "just": true, "best": true, "this": true,
	"that": true, "from": true, "you": true, "your": true, "how": true, "what": true, "why": true,
	"his": true, "her": true, "its": true, "are": true, "was": true, "has": true, "have": true,
	"of": true, "in": true, "on": true, "to": true, "is": true, "it": true, "an": true, "at": true,
	"by": true, "or": true, "be": true, "we": true, "my": true, "so": true, "me": true, "new": true,
	"video": true, "mp4": true,
}

// videoTitleWords lowercases a title or file name into its distinctive words,
// dropping the extension, the "[id]", stopwords, one-letter words and the
// uploader's own name, which two posts by one account share whatever they are.
func videoTitleWords(title, uploader string) map[string]bool {
	title = filenameIDRe.ReplaceAllString(title, "")
	title = strings.TrimSuffix(title, ".mp4")
	split := func(s string) []string {
		return strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
			return !unicode.IsLetter(r) && !unicode.IsDigit(r)
		})
	}
	skip := map[string]bool{}
	for _, w := range split(uploader) {
		skip[w] = true
	}
	out := map[string]bool{}
	for _, w := range split(title) {
		if len([]rune(w)) < 2 || titleStopwords[w] || skip[w] {
			continue
		}
		out[w] = true
	}
	return out
}

// durationsClose is true when two lengths are within 2% of the longer one,
// with a 5-second floor for short clips. An unknown length never matches.
func durationsClose(a, b float64) bool {
	if a <= 0 || b <= 0 {
		return false
	}
	return math.Abs(a-b) <= math.Max(5, 0.02*math.Max(a, b))
}

// minSharedTitleWords is how many distinctive words two titles must share,
// on top of a close length, to count as the same video.
const minSharedTitleWords = 2

// findDuplicate looks for a file in Videos/ that is the same video as m: the
// same yt-dlp id, or a close length plus shared title words (a repost by
// another account has a different id and title). It returns why it matched.
func findDuplicate(m videoMeta, have []remoteVideo) (remoteVideo, string, bool) {
	for _, v := range have {
		if id := firstNonEmpty(v.ID, idFromFilename(v.Name)); id != "" && id == m.ID {
			return v, "same video id " + m.ID, true
		}
	}
	words := videoTitleWords(m.Title, m.Uploader)
	for _, v := range have {
		if !durationsClose(m.Duration, v.Duration) {
			continue
		}
		var shared []string
		for w := range videoTitleWords(v.Name, m.Uploader) {
			if words[w] {
				shared = append(shared, w)
			}
		}
		if len(shared) >= minSharedTitleWords {
			sort.Strings(shared)
			return v, fmt.Sprintf("length %s vs %s, shared title words: %s",
				formatClock(m.Duration), formatClock(v.Duration), strings.Join(shared, " ")), true
		}
	}
	return remoteVideo{}, "", false
}

// formatClock renders seconds as h:mm:ss, or m:ss under an hour.
func formatClock(sec float64) string {
	s := int(math.Round(sec))
	if s >= 3600 {
		return fmt.Sprintf("%d:%02d:%02d", s/3600, s/60%60, s%60)
	}
	return fmt.Sprintf("%d:%02d", s/60, s%60)
}

// fillDurations probes the files whose length is unknown, in place, and saves
// each length it learns so the next run does not probe that file again. A file
// that cannot be probed stays unknown and simply never matches on length.
func fillDurations(have []remoteVideo, probe func(remote string) (float64, error), save func(remote string, d float64)) {
	for i := range have {
		if have[i].Duration > 0 {
			continue
		}
		d, err := probe(have[i].Path)
		if err != nil || d <= 0 {
			continue
		}
		have[i].Duration = d
		save(have[i].Path, d)
	}
}
