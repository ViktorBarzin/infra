package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
)

// videoUploadDir is the one Nextcloud folder every downloaded video lands in,
// so the phone app has a single place to look.
const videoUploadDir = "/Videos/"

// videoChunkSize keeps each upload request well under the ~1 GiB body limit
// that answered 413 for a single PUT (memory #14305).
const videoChunkSize = 100 << 20

const videoUsage = `homelab video get <url>... [--quality 1080|720|480|best] [--expire DAYS] [--no-link] [--force]

Downloads each video with yt-dlp as an H.264 MP4 that plays in a phone's own
player, uploads it to Videos/ in your Nextcloud, and prints the path plus a
public link that expires after DAYS (default 30).

  --quality   height cap, default 1080. "best" drops the cap.
  --expire    public-link lifetime in days, default 30. 0 means no expiry.
  --no-link   upload only, print no public link.
  --force     download even when Videos/ already has the video.

Before downloading, the link is compared with what Videos/ already holds. The
same video id, or a length within 2% plus two shared title words (a repost by
another account), counts as already there: nothing downloads and the existing
file's path and link are printed instead.

YouTube links fetch visitor cookies from the cluster Chrome first, because
YouTube blocks yt-dlp from the homelab's address without them. Several URLs run
one after another; a failed one is reported and the rest still run.
`

var videoQualities = map[string]bool{"1080": true, "720": true, "480": true, "best": true}

type videoArgs struct {
	urls       []string
	quality    string
	expireDays int
	noLink     bool
	force      bool
	help       bool
}

// parseVideoArgs parses the argv strictly, like parseShareArgs: an unknown
// flag or a bad value is an error rather than a silent default, because the
// download that follows can take hours.
func parseVideoArgs(args []string) (videoArgs, error) {
	out := videoArgs{quality: "1080", expireDays: defaultShareExpireDays}
	value := func(i *int, name, inline string, hasInline bool) (string, error) {
		if hasInline {
			return inline, nil
		}
		if *i+1 >= len(args) || strings.HasPrefix(args[*i+1], "-") {
			return "", fmt.Errorf("--%s needs a value", name)
		}
		*i++
		return args[*i], nil
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "-h" || a == "--help" {
			out.help = true
			continue
		}
		if !strings.HasPrefix(a, "-") {
			if !strings.HasPrefix(a, "http://") && !strings.HasPrefix(a, "https://") {
				return out, fmt.Errorf("%q is not a URL; homelab video get takes http(s) links", a)
			}
			out.urls = append(out.urls, a)
			continue
		}
		name, inline, hasInline := flagToken(a)
		switch name {
		case "no-link":
			out.noLink = true
		case "force":
			out.force = true
		case "quality":
			v, err := value(&i, name, inline, hasInline)
			if err != nil {
				return out, fmt.Errorf("%w (1080, 720, 480 or best)", err)
			}
			if !videoQualities[v] {
				return out, fmt.Errorf("--quality wants 1080, 720, 480 or best, got %q", v)
			}
			out.quality = v
		case "expire":
			v, err := value(&i, name, inline, hasInline)
			if err != nil {
				return out, err
			}
			d, err := strconv.Atoi(v)
			if err != nil {
				return out, fmt.Errorf("--expire wants a number of days, got %q", v)
			}
			out.expireDays = d
		default:
			return out, fmt.Errorf("unknown flag %q; homelab video get takes --quality, --expire, --no-link or --force", a)
		}
	}
	if len(out.urls) == 0 && !out.help {
		return out, fmt.Errorf("usage: %s", strings.SplitN(videoUsage, "\n", 2)[0])
	}
	return out, nil
}

// isYouTube reports whether the link needs the YouTube cookie recipe.
func isYouTube(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	switch strings.ToLower(u.Hostname()) {
	case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be":
		return true
	}
	return false
}

// videoFormat picks H.264 video with AAC audio, which every phone's native
// player handles, and falls back step by step to whatever the site has.
func videoFormat(quality string) string {
	h := ""
	if quality != "best" {
		h = "[height<=" + quality + "]"
	}
	return "bv*" + h + "[vcodec^=avc1]+ba[ext=m4a]/b" + h + "[ext=mp4]/bv*" + h + "+ba/b"
}

// videoPathFile is where yt-dlp records the path of the finished download.
func videoPathFile(outDir string) string {
	return strings.TrimSuffix(outDir, "/") + "/.filepath"
}

// ytdlpArgs builds the yt-dlp command line. `after_move:filepath` records the
// final merged file, never the video-only intermediate yt-dlp writes first.
// The title alone names the file: X titles already start with the uploader. A cookies path switches on the YouTube recipe from memory
// #12269: visitor cookies, the web_safari client, and the remote EJS solver,
// without which only storyboard formats appear. The solver runs on node,
// which the playbook installs for every user; the defaults are cleared first
// so a per-user deno cannot hide a node failure.
func ytdlpArgs(videoURL, outDir, quality, cookiesPath string) []string {
	args := []string{
		"-f", videoFormat(quality),
		"--merge-output-format", "mp4",
		"-o", strings.TrimSuffix(outDir, "/") + "/%(title).150B [%(id)s].%(ext)s",
		"--print-to-file", "after_move:filepath", videoPathFile(outDir),
		"--no-playlist",
		"--newline", "--progress",
	}
	return append(append(args, youtubeCookieArgs(cookiesPath)...), videoURL)
}

func youtubeCookieArgs(cookiesPath string) []string {
	if cookiesPath == "" {
		return nil
	}
	return []string{
		"--cookies", cookiesPath,
		"--extractor-args", "youtube:player_client=web_safari",
		"--remote-components", "ejs:github",
		"--no-js-runtimes", "--js-runtimes", "node",
	}
}

// ytdlpProbeArgs asks yt-dlp for the link's metadata as JSON without
// downloading it, so a duplicate is caught before the transfer starts.
func ytdlpProbeArgs(videoURL, cookiesPath string) []string {
	args := []string{"-j", "--no-playlist", "--ignore-no-formats-error", "--no-warnings"}
	return append(append(args, youtubeCookieArgs(cookiesPath)...), videoURL)
}

// finalVideoPath picks the file yt-dlp recorded: the last non-empty line,
// which must sit inside the download directory.
func finalVideoPath(recorded, outDir string) (string, error) {
	lines := strings.Split(strings.TrimSpace(recorded), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		l := strings.TrimSpace(lines[i])
		if l == "" {
			continue
		}
		if strings.HasPrefix(l, strings.TrimSuffix(outDir, "/")+"/") {
			return l, nil
		}
		break
	}
	return "", fmt.Errorf("yt-dlp finished but reported no downloaded file")
}

// playwrightCookie is one entry of Playwright's context.cookies().
type playwrightCookie struct {
	Name     string  `json:"name"`
	Value    string  `json:"value"`
	Domain   string  `json:"domain"`
	Path     string  `json:"path"`
	Expires  float64 `json:"expires"`
	HTTPOnly bool    `json:"httpOnly"`
	Secure   bool    `json:"secure"`
}

func isYouTubeCookieDomain(d string) bool {
	d = strings.ToLower(strings.TrimPrefix(d, "."))
	return d == "youtube.com" || strings.HasSuffix(d, ".youtube.com")
}

// cookiesToNetscape converts Playwright cookies to the cookies.txt yt-dlp
// reads, keeping only youtube.com rows: google.com rows make YouTube answer
// "The page needs to be reloaded" (memory #12269).
func cookiesToNetscape(raw string) (string, error) {
	var cookies []playwrightCookie
	if err := json.Unmarshal([]byte(raw), &cookies); err != nil {
		return "", fmt.Errorf("the browser returned cookies that are not JSON: %w", err)
	}
	var b strings.Builder
	b.WriteString("# Netscape HTTP Cookie File\n")
	kept := 0
	bool2 := func(v bool) string {
		if v {
			return "TRUE"
		}
		return "FALSE"
	}
	for _, c := range cookies {
		if !isYouTubeCookieDomain(c.Domain) {
			continue
		}
		domain := c.Domain
		if c.HTTPOnly {
			domain = "#HttpOnly_" + domain
		}
		expires := int64(0) // session cookie
		if c.Expires > 0 {
			expires = int64(c.Expires)
		}
		p := c.Path
		if p == "" {
			p = "/"
		}
		fmt.Fprintf(&b, "%s\t%s\t%s\t%s\t%d\t%s\t%s\n",
			domain, bool2(strings.HasPrefix(c.Domain, ".")), p, bool2(c.Secure), expires, c.Name, c.Value)
		kept++
	}
	if kept == 0 {
		return "", fmt.Errorf("the browser returned no youtube.com cookies")
	}
	return b.String(), nil
}

const (
	cookieMarkerBegin = "---HOMELAB-VIDEO-COOKIES-BEGIN---"
	cookieMarkerEnd   = "---HOMELAB-VIDEO-COOKIES-END---"
)

// youtubeCookieScript runs inside `homelab browser run --url <video>`. The
// runner has already opened the page; a short wait lets YouTube set its
// visitor cookies. The markers let extractCookieJSON ignore the runner's
// other output.
const youtubeCookieScript = `await page.waitForTimeout(4000);
return '` + cookieMarkerBegin + `\n' + JSON.stringify(await context.cookies()) + '\n` + cookieMarkerEnd + `';
`

// extractCookieJSON pulls the cookie JSON out from between the markers.
func extractCookieJSON(stdout string) (string, error) {
	_, rest, ok := strings.Cut(stdout, cookieMarkerBegin)
	if !ok {
		return "", fmt.Errorf("the browser script printed no cookies")
	}
	body, _, ok := strings.Cut(rest, cookieMarkerEnd)
	if !ok {
		return "", fmt.Errorf("the browser script's cookie output was cut short")
	}
	return strings.TrimSpace(body), nil
}

// chunkRange is one piece of a chunked upload: its name in the upload
// folder and the byte range of the local file it carries.
type chunkRange struct {
	name   string
	offset int64
	length int64
}

// chunkPlan splits a file of size bytes into chunk-sized pieces named 00001,
// 00002, …, which Nextcloud assembles in name order.
func chunkPlan(size, chunk int64) []chunkRange {
	var out []chunkRange
	for off, n := int64(0), 1; off < size; off, n = off+chunk, n+1 {
		l := chunk
		if size-off < l {
			l = size - off
		}
		out = append(out, chunkRange{name: fmt.Sprintf("%05d", n), offset: off, length: l})
	}
	return out
}

// remoteVideoPath puts the file directly in Videos/, flattened to its base
// name the way remoteSharePath does, so the name cannot escape the folder.
// No timestamp: yt-dlp's name already carries the video id, so a --force
// download of the same video replaces it rather than making a copy.
func remoteVideoPath(localFile string) string {
	base := path.Base(strings.ReplaceAll(localFile, "\\", "/"))
	base = strings.TrimLeft(base, ".")
	if base == "" || base == "/" {
		base = "video.mp4"
	}
	return videoUploadDir + base
}

// hasAudioStream reads `ffprobe -select_streams a -show_entries
// stream=codec_type -of csv=p=0`, which prints one line per audio stream.
func hasAudioStream(ffprobeOut string) bool {
	return strings.Contains(ffprobeOut, "audio")
}

var propfindLengthRe = regexp.MustCompile(`(?i)<(?:[a-z0-9]+:)?getcontentlength>\s*(\d+)\s*<`)

// parsePropfindSize reads getcontentlength out of a Depth: 0 PROPFIND answer.
func parsePropfindSize(body string) (int64, bool) {
	m := propfindLengthRe.FindStringSubmatch(body)
	if m == nil {
		return 0, false
	}
	n, err := strconv.ParseInt(m[1], 10, 64)
	return n, err == nil
}
