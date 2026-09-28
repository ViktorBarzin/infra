package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
)

func TestParseVideoArgs(t *testing.T) {
	cases := []struct {
		name    string
		args    []string
		want    videoArgs
		wantErr string
	}{
		{name: "one url takes the defaults",
			args: []string{"https://x.com/a/status/1"},
			want: videoArgs{urls: []string{"https://x.com/a/status/1"}, quality: "1080", expireDays: 30}},
		{name: "several urls keep their order",
			args: []string{"https://x.com/1", "https://youtu.be/abc"},
			want: videoArgs{urls: []string{"https://x.com/1", "https://youtu.be/abc"}, quality: "1080", expireDays: 30}},
		{name: "quality and expire as separate tokens",
			args: []string{"--quality", "720", "--expire", "7", "https://x.com/1"},
			want: videoArgs{urls: []string{"https://x.com/1"}, quality: "720", expireDays: 7}},
		{name: "quality and expire with =",
			args: []string{"https://x.com/1", "--quality=best", "--expire=3", "--no-link"},
			want: videoArgs{urls: []string{"https://x.com/1"}, quality: "best", expireDays: 3, noLink: true}},
		{name: "help needs no url",
			args: []string{"--help"},
			want: videoArgs{quality: "1080", expireDays: 30, help: true}},
		{name: "short help alongside a url still only asks for help",
			args: []string{"https://x.com/1", "-h"},
			want: videoArgs{urls: []string{"https://x.com/1"}, quality: "1080", expireDays: 30, help: true}},
		{name: "unknown flag", args: []string{"--qualty", "720", "https://x.com/1"}, wantErr: "unknown flag"},
		{name: "unsupported quality", args: []string{"--quality", "4k", "https://x.com/1"}, wantErr: "--quality"},
		{name: "valueless quality", args: []string{"https://x.com/1", "--quality"}, wantErr: "--quality"},
		{name: "non-numeric expire", args: []string{"--expire", "soon", "https://x.com/1"}, wantErr: "--expire"},
		{name: "no url", args: nil, wantErr: "usage"},
		{name: "not a url", args: []string{"video.mp4"}, wantErr: "not a URL"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := parseVideoArgs(c.args)
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("want error containing %q, got %v", c.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if strings.Join(got.urls, " ") != strings.Join(c.want.urls, " ") ||
				got.quality != c.want.quality || got.expireDays != c.want.expireDays ||
				got.noLink != c.want.noLink || got.help != c.want.help {
				t.Errorf("got %+v, want %+v", got, c.want)
			}
		})
	}
}

func TestIsYouTube(t *testing.T) {
	cases := map[string]bool{
		"https://www.youtube.com/watch?v=abc":    true,
		"https://youtube.com/watch?v=abc":        true,
		"https://m.youtube.com/watch?v=abc":      true,
		"https://music.youtube.com/watch?v=abc":  true,
		"https://youtu.be/abc":                   true,
		"https://www.youtube.com/shorts/abc":     true,
		"https://x.com/someone/status/1":         false,
		"https://twitter.com/someone/status/1":   false,
		"https://notyoutube.com/watch?v=abc":     false,
		"https://example.com/?u=youtube.com":     false,
		"https://youtube.com.evil.example/watch": false,
		"not a url":                              false,
	}
	for in, want := range cases {
		if got := isYouTube(in); got != want {
			t.Errorf("isYouTube(%q) = %v, want %v", in, got, want)
		}
	}
}

func argValue(args []string, flag string) (string, bool) {
	for i, a := range args {
		if a == flag && i+1 < len(args) {
			return args[i+1], true
		}
	}
	return "", false
}

func TestYtdlpArgsWithoutCookies(t *testing.T) {
	args := ytdlpArgs("https://x.com/a/status/1", "/tmp/out", "720", "")
	if args[len(args)-1] != "https://x.com/a/status/1" {
		t.Errorf("the URL must be the last argument, got %v", args)
	}
	format, ok := argValue(args, "-f")
	if !ok || !strings.Contains(format, "height<=720") || !strings.Contains(format, "vcodec^=avc1") {
		t.Errorf("want an H.264 format capped at 720p, got %q", format)
	}
	if v, _ := argValue(args, "--merge-output-format"); v != "mp4" {
		t.Errorf("want an mp4 merge, got %q", v)
	}
	// The final path goes to a file, so yt-dlp's progress can stream to the
	// terminal instead of being mixed into the output we parse.
	if v, _ := argValue(args, "--print-to-file"); v != "after_move:filepath" {
		t.Errorf("want the final path recorded after the merge, got %q", v)
	}
	if v, _ := argValue(args, "after_move:filepath"); v != videoPathFile("/tmp/out") {
		t.Errorf("want the path file inside the temp dir, got %q", v)
	}
	out, _ := argValue(args, "-o")
	if !strings.HasPrefix(out, "/tmp/out/") || !strings.Contains(out, "[%(id)s]") {
		t.Errorf("want the output template inside the temp dir, got %q", out)
	}
	if !containsArg(args, "--no-playlist") {
		t.Errorf("want --no-playlist, got %v", args)
	}
	for _, yt := range []string{"--cookies", "--extractor-args", "--remote-components", "--js-runtimes"} {
		if containsArg(args, yt) {
			t.Errorf("a non-YouTube download must not carry %s: %v", yt, args)
		}
	}
}

func TestYtdlpArgsWithCookies(t *testing.T) {
	args := ytdlpArgs("https://youtu.be/abc", "/tmp/out", "1080", "/tmp/out/cookies.txt")
	want := map[string]string{
		"--cookies":           "/tmp/out/cookies.txt",
		"--extractor-args":    "youtube:player_client=web_safari",
		"--remote-components": "ejs:github",
		"--js-runtimes":       "node",
	}
	for flag, v := range want {
		if got, _ := argValue(args, flag); got != v {
			t.Errorf("%s = %q, want %q", flag, got, v)
		}
	}
	if args[len(args)-1] != "https://youtu.be/abc" {
		t.Errorf("the URL must be the last argument, got %v", args)
	}
	// node is the runtime the playbook installs for every user. Clearing the
	// defaults first stops a per-user deno from hiding a node failure.
	clear, set := -1, -1
	for i, a := range args {
		switch a {
		case "--no-js-runtimes":
			clear = i
		case "--js-runtimes":
			set = i
		}
	}
	if clear < 0 || clear > set {
		t.Errorf("want --no-js-runtimes before --js-runtimes node, got %v", args)
	}
}

func TestYtdlpFormatBestHasNoHeightCap(t *testing.T) {
	format, _ := argValue(ytdlpArgs("https://x.com/1", "/o", "best", ""), "-f")
	if strings.Contains(format, "height") {
		t.Errorf("best should not cap the height, got %q", format)
	}
	if !strings.Contains(format, "vcodec^=avc1") {
		t.Errorf("best should still prefer H.264 for the phone player, got %q", format)
	}
}

func TestCookiesToNetscape(t *testing.T) {
	in := `[
	  {"name":"VISITOR_INFO1_LIVE","value":"v1","domain":".youtube.com","path":"/","expires":1790000000.5,"httpOnly":true,"secure":true,"sameSite":"None"},
	  {"name":"YSC","value":"y1","domain":".youtube.com","path":"/","expires":-1,"httpOnly":true,"secure":true,"sameSite":"None"},
	  {"name":"PREF","value":"f6=40","domain":"www.youtube.com","path":"/","expires":1790000000,"httpOnly":false,"secure":false,"sameSite":"Lax"},
	  {"name":"NID","value":"g1","domain":".google.com","path":"/","expires":1790000000,"httpOnly":true,"secure":true,"sameSite":"None"},
	  {"name":"X","value":"e1","domain":"youtube.com.evil.example","path":"/","expires":-1,"httpOnly":false,"secure":false,"sameSite":"Lax"}
	]`
	got, err := cookiesToNetscape(in)
	if err != nil {
		t.Fatalf("cookiesToNetscape: %v", err)
	}
	if !strings.HasPrefix(got, "# Netscape HTTP Cookie File\n") {
		t.Errorf("want the Netscape header first, got %q", got)
	}
	if strings.Contains(got, "google.com") || strings.Contains(got, "evil") {
		t.Errorf("only youtube.com rows may survive (google.com rows break extraction):\n%s", got)
	}
	wantLines := []string{
		"#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t1790000000\tVISITOR_INFO1_LIVE\tv1",
		"#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t0\tYSC\ty1", // session cookie: expires 0
		"www.youtube.com\tFALSE\t/\tFALSE\t1790000000\tPREF\tf6=40",
	}
	for _, l := range wantLines {
		if !strings.Contains(got, l+"\n") {
			t.Errorf("missing line %q in:\n%s", l, got)
		}
	}
}

func TestCookiesToNetscapeRejectsGarbageAndEmpty(t *testing.T) {
	if _, err := cookiesToNetscape("not json"); err == nil {
		t.Error("want an error for non-JSON input")
	}
	if _, err := cookiesToNetscape(`[{"name":"NID","value":"g","domain":".google.com","path":"/","expires":-1}]`); err == nil {
		t.Error("want an error when no youtube.com cookie is left, since yt-dlp would then fail obscurely")
	}
}

func TestExtractCookieJSON(t *testing.T) {
	out := "homelab browser: pool session abc\nsome log line\n" +
		cookieMarkerBegin + "\n[{\"name\":\"a\"}]\n" + cookieMarkerEnd + "\ntrailing\n"
	got, err := extractCookieJSON(out)
	if err != nil {
		t.Fatalf("extractCookieJSON: %v", err)
	}
	if got != `[{"name":"a"}]` {
		t.Errorf("got %q", got)
	}
	if _, err := extractCookieJSON("no markers here"); err == nil {
		t.Error("want an error when the markers are missing")
	}
}

func TestChunkPlan(t *testing.T) {
	cases := []struct {
		size, chunk int64
		want        []chunkRange
	}{
		{0, 100, nil},
		{100, 100, []chunkRange{{"00001", 0, 100}}},
		{300, 100, []chunkRange{{"00001", 0, 100}, {"00002", 100, 100}, {"00003", 200, 100}}},
		{250, 100, []chunkRange{{"00001", 0, 100}, {"00002", 100, 100}, {"00003", 200, 50}}},
		{1, 100, []chunkRange{{"00001", 0, 1}}},
	}
	for _, c := range cases {
		got := chunkPlan(c.size, c.chunk)
		if len(got) != len(c.want) {
			t.Errorf("chunkPlan(%d,%d) = %v, want %v", c.size, c.chunk, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("chunkPlan(%d,%d)[%d] = %v, want %v", c.size, c.chunk, i, got[i], c.want[i])
			}
		}
	}
}

func TestRemoteVideoPath(t *testing.T) {
	cases := map[string]string{
		"/tmp/homelab-video-x/Someone - Talk [123].mp4": "/Videos/Someone - Talk [123].mp4",
		"../../etc/passwd": "/Videos/passwd",
		".hidden.mp4":      "/Videos/hidden.mp4",
		"":                 "/Videos/video.mp4",
	}
	for in, want := range cases {
		if got := remoteVideoPath(in); got != want {
			t.Errorf("remoteVideoPath(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestFinalVideoPath(t *testing.T) {
	got, err := finalVideoPath("/tmp/v/a [1].mp4\n", "/tmp/v")
	if err != nil || got != "/tmp/v/a [1].mp4" {
		t.Errorf("got %q, %v", got, err)
	}
	if _, err := finalVideoPath("", "/tmp/v"); err == nil {
		t.Error("want an error when yt-dlp printed nothing")
	}
	if _, err := finalVideoPath("/etc/passwd\n", "/tmp/v"); err == nil {
		t.Error("want an error for a path outside the download directory")
	}
}

func TestParsePropfindSize(t *testing.T) {
	n, ok := parsePropfindSize(`<d:multistatus xmlns:d="DAV:"><d:prop><d:getcontentlength>1234</d:getcontentlength></d:prop></d:multistatus>`)
	if !ok || n != 1234 {
		t.Errorf("got %d, %v", n, ok)
	}
	if _, ok := parsePropfindSize(`<d:multistatus/>`); ok {
		t.Error("want no size when the property is absent")
	}
}

func TestHasAudioStream(t *testing.T) {
	if !hasAudioStream("audio\n") {
		t.Error("an ffprobe line naming audio means there is an audio stream")
	}
	if hasAudioStream("\n") || hasAudioStream("") {
		t.Error("empty ffprobe output means no audio stream")
	}
}

// fakeNextcloud is just enough of Nextcloud's WebDAV + chunked-upload v2 API to
// exercise the upload path, with knobs for the failures seen in practice.
type fakeNextcloud struct {
	mu            sync.Mutex
	chunks        map[string][]byte // chunk name -> body, for the one upload in flight
	files         map[string][]byte // path under /remote.php/dav/files/<user> -> content
	failChunkOnce map[string]bool   // chunk name -> answer 500 on its first PUT
	moveAnswer404 bool              // assemble the file, then pretend the MOVE was lost
	mkcolFiles405 bool              // the destination folder already exists
	calls         []string
}

func newFakeNextcloud() *fakeNextcloud {
	return &fakeNextcloud{chunks: map[string][]byte{}, files: map[string][]byte{}, failChunkOnce: map[string]bool{}}
}

func (f *fakeNextcloud) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, r.Method+" "+r.URL.Path)
	if u, p, ok := r.BasicAuth(); !ok || u != "alice" || p != "pw" {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	const filesPrefix = "/remote.php/dav/files/alice"
	const uploadsPrefix = "/remote.php/dav/uploads/alice/"
	switch {
	case r.Method == "MKCOL" && strings.HasPrefix(r.URL.Path, filesPrefix):
		if f.mkcolFiles405 {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.WriteHeader(http.StatusCreated)
	case r.Method == "MKCOL" && strings.HasPrefix(r.URL.Path, uploadsPrefix):
		if r.Header.Get("Destination") == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusCreated)
	case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, uploadsPrefix):
		name := filepath.Base(r.URL.Path)
		if f.failChunkOnce[name] {
			delete(f.failChunkOnce, name)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		body, _ := io.ReadAll(r.Body)
		f.chunks[name] = body
		w.WriteHeader(http.StatusCreated)
	case r.Method == "MOVE" && strings.HasSuffix(r.URL.Path, "/.file"):
		total, _ := strconv.ParseInt(r.Header.Get("OC-Total-Length"), 10, 64)
		dest := r.Header.Get("Destination")
		i := strings.Index(dest, filesPrefix)
		if i < 0 {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		names := make([]string, 0, len(f.chunks))
		for n := range f.chunks {
			names = append(names, n)
		}
		sort.Strings(names)
		var buf bytes.Buffer
		for _, n := range names {
			buf.Write(f.chunks[n])
		}
		if int64(buf.Len()) != total {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		path := dest[i+len(filesPrefix):]
		if dec, err := decodeTestPath(path); err == nil {
			path = dec
		}
		f.files[path] = buf.Bytes()
		f.chunks = map[string][]byte{}
		if f.moveAnswer404 {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusCreated)
	case r.Method == "PROPFIND" && strings.HasPrefix(r.URL.Path, filesPrefix):
		p := strings.TrimPrefix(r.URL.Path, filesPrefix)
		content, ok := f.files[p]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(207)
		io.WriteString(w, `<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>`+r.URL.Path+
			`</d:href><d:propstat><d:prop><d:getcontentlength>`+strconv.Itoa(len(content))+
			`</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>`)
	case r.Method == "DELETE":
		w.WriteHeader(http.StatusNoContent)
	default:
		w.WriteHeader(http.StatusNotImplemented)
	}
}

func decodeTestPath(p string) (string, error) { return url.PathUnescape(p) }

func writeTempVideo(t *testing.T, size int) (string, []byte) {
	t.Helper()
	content := bytes.Repeat([]byte("0123456789abcdef"), size/16+1)[:size]
	p := filepath.Join(t.TempDir(), "clip [id1].mp4")
	if err := os.WriteFile(p, content, 0o600); err != nil {
		t.Fatal(err)
	}
	return p, content
}

func testUploader(srv *httptest.Server) ncUploader {
	return ncUploader{host: srv.URL, user: "alice", pass: "pw", chunkSize: 100, client: srv.Client(), log: io.Discard}
}

func TestChunkedUploadAssemblesTheFile(t *testing.T) {
	fake := newFakeNextcloud()
	fake.mkcolFiles405 = true // Videos/ already exists: must not be an error
	srv := httptest.NewServer(fake)
	defer srv.Close()
	local, content := writeTempVideo(t, 250)

	if err := testUploader(srv).upload(local, "/Videos/clip [id1].mp4"); err != nil {
		t.Fatalf("upload: %v", err)
	}
	if got := fake.files["/Videos/clip [id1].mp4"]; !bytes.Equal(got, content) {
		t.Errorf("assembled file differs: got %d bytes, want %d", len(got), len(content))
	}
}

func TestChunkedUploadRetriesAFailedChunk(t *testing.T) {
	fake := newFakeNextcloud()
	fake.failChunkOnce["00002"] = true
	srv := httptest.NewServer(fake)
	defer srv.Close()
	local, content := writeTempVideo(t, 250)

	if err := testUploader(srv).upload(local, "/Videos/clip [id1].mp4"); err != nil {
		t.Fatalf("upload: %v", err)
	}
	if got := fake.files["/Videos/clip [id1].mp4"]; !bytes.Equal(got, content) {
		t.Errorf("assembled file differs after a retried chunk")
	}
	puts := 0
	for _, c := range fake.calls {
		if strings.HasPrefix(c, "PUT ") && strings.HasSuffix(c, "/00002") {
			puts++
		}
	}
	if puts != 2 {
		t.Errorf("want chunk 00002 sent twice (fail, then succeed), got %d", puts)
	}
}

func TestChunkedUploadTrustsSizeOverMoveStatus(t *testing.T) {
	// A MOVE retried after a lost response answers 404 even though Nextcloud
	// already assembled the file. The size check is what decides.
	fake := newFakeNextcloud()
	fake.moveAnswer404 = true
	srv := httptest.NewServer(fake)
	defer srv.Close()
	local, _ := writeTempVideo(t, 250)

	if err := testUploader(srv).upload(local, "/Videos/clip [id1].mp4"); err != nil {
		t.Fatalf("a 404 MOVE with the right-sized file in place must count as success, got %v", err)
	}
}

func TestChunkedUploadFailsWhenTheFileIsMissing(t *testing.T) {
	fake := newFakeNextcloud()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "MOVE" { // never assembles
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		fake.ServeHTTP(w, r)
	}))
	defer srv.Close()
	local, _ := writeTempVideo(t, 250)

	if err := testUploader(srv).upload(local, "/Videos/clip [id1].mp4"); err == nil {
		t.Fatal("want an error when the file never appears at the destination")
	}
}

func TestChunkedUploadStopsOnBadCredential(t *testing.T) {
	srv := httptest.NewServer(newFakeNextcloud())
	defer srv.Close()
	local, _ := writeTempVideo(t, 250)
	u := testUploader(srv)
	u.pass = "wrong"
	err := u.upload(local, "/Videos/clip [id1].mp4")
	if err == nil || !strings.Contains(err.Error(), "401") {
		t.Fatalf("want a 401 error, got %v", err)
	}
}
