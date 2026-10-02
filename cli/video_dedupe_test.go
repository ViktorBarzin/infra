package main

import (
	"errors"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
)

func sortedWords(m map[string]bool) string {
	var out []string
	for w := range m {
		out = append(out, w)
	}
	sort.Strings(out)
	return strings.Join(out, " ")
}

func TestVideoTitleWords(t *testing.T) {
	cases := []struct {
		name, title, uploader, want string
	}{
		{name: "drops stopwords, one-letter words and the uploader",
			title:    "Lunar - Andrew Ng just dropped the best 2-hour course on Graph Engineering: f...",
			uploader: "Lunar",
			want:     "andrew course dropped engineering graph hour ng"},
		{name: "a file name loses its extension and id",
			title: "res1dualedge - Andrew Ng graph engineering course [2105633067884789760].mp4",
			want:  "andrew course engineering graph ng res1dualedge"},
		{name: "full-width colon from a file name splits words",
			title: "Graph：Engineering.mp4",
			want:  "engineering graph"},
		{name: "empty", title: "", want: ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := sortedWords(videoTitleWords(c.title, c.uploader)); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestDurationsClose(t *testing.T) {
	cases := []struct {
		a, b float64
		want bool
	}{
		{6675.2, 6745.98, true}, // the two Andrew Ng reposts, 1% apart
		{30, 34, true},          // short clips get the 5-second floor
		{30, 36, false},
		{6675, 7000, false},
		{0, 0, false}, // unknown length never matches
		{0, 30, false},
	}
	for _, c := range cases {
		if got := durationsClose(c.a, c.b); got != c.want {
			t.Errorf("durationsClose(%v, %v) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestParseVideoMeta(t *testing.T) {
	m, err := parseVideoMeta(`{"id":"2105633067884789760","title":"Lunar - Andrew Ng","duration":6675.233,"uploader":"Lunar","formats":[]}`)
	if err != nil {
		t.Fatal(err)
	}
	if m.ID != "2105633067884789760" || m.Title != "Lunar - Andrew Ng" || m.Duration != 6675.233 || m.Uploader != "Lunar" {
		t.Errorf("got %+v", m)
	}
	if _, err := parseVideoMeta("not json"); err == nil {
		t.Error("want an error for garbage")
	}
	if _, err := parseVideoMeta(`{"title":"no id"}`); err == nil {
		t.Error("want an error when yt-dlp reports no id")
	}
}

func TestIDFromFilename(t *testing.T) {
	cases := map[string]string{
		"Lunar - Course [2105633067884789760].mp4": "2105633067884789760",
		"Talk [dQw4w9WgXcQ].mp4":                   "dQw4w9WgXcQ",
		"res1dualedge - Andrew Ng.mp4":             "",
		"[a] middle [b].mp4":                       "b",
	}
	for in, want := range cases {
		if got := idFromFilename(in); got != want {
			t.Errorf("idFromFilename(%q) = %q, want %q", in, got, want)
		}
	}
}

const listingXML = `<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns">
 <d:response><d:href>/remote.php/dav/files/alice/Videos/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/alice/Videos/res1dualedge%20-%20Andrew%20Ng%20graph%20engineering%20course.mp4</d:href>
  <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>1126201511</d:getcontentlength>
   <x1:duration xmlns:x1="https://viktorbarzin.me/ns/homelab-video">6745.98</x1:duration></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  <d:propstat><d:prop><x1:id xmlns:x1="https://viktorbarzin.me/ns/homelab-video"/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/alice/Videos/Talk%20%5babc%5d.mp4</d:href>
  <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>10</d:getcontentlength>
   <x1:id xmlns:x1="https://viktorbarzin.me/ns/homelab-video">xyz</x1:id></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/alice/Videos/sub/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>`

func TestParseVideoListing(t *testing.T) {
	got, err := parseVideoListing(listingXML)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 files (folders skipped), got %d: %+v", len(got), got)
	}
	a := got[0]
	if a.Path != "/Videos/res1dualedge - Andrew Ng graph engineering course.mp4" || a.Name != "res1dualedge - Andrew Ng graph engineering course.mp4" ||
		a.Duration != 6745.98 || a.ID != "" || a.Size != 1126201511 {
		t.Errorf("first file: %+v", a)
	}
	b := got[1]
	if b.ID != "xyz" || b.Duration != 0 || b.Name != "Talk [abc].mp4" {
		t.Errorf("a stored id must win over the file name's id: %+v", b)
	}
}

func TestFindDuplicate(t *testing.T) {
	have := []remoteVideo{
		{Path: "/Videos/proAlishke - Met a guy who got a 750k offer from Anthropic.mp4", Name: "proAlishke - Met a guy who got a 750k offer from Anthropic.mp4", Duration: 5000},
		{Path: "/Videos/res1dualedge - Andrew Ng graph engineering course.mp4", Name: "res1dualedge - Andrew Ng graph engineering course.mp4", Duration: 6745.98},
		{Path: "/Videos/Short [111].mp4", Name: "Short [111].mp4", Duration: 30},
	}
	cases := []struct {
		name     string
		meta     videoMeta
		wantPath string
	}{
		{name: "a repost by another account: close length, shared title words",
			meta:     videoMeta{ID: "2105633067884789760", Title: "Lunar - Andrew Ng just dropped the best 2-hour course on Graph Engineering: f...", Uploader: "Lunar", Duration: 6675.233},
			wantPath: "/Videos/res1dualedge - Andrew Ng graph engineering course.mp4"},
		{name: "the same id matches whatever the length and title",
			meta:     videoMeta{ID: "111", Title: "Totally different", Duration: 999},
			wantPath: "/Videos/Short [111].mp4"},
		{name: "same length but unrelated title is not a duplicate",
			meta: videoMeta{ID: "9", Title: "Cats doing backflips", Duration: 30}},
		{name: "one shared word is not enough",
			meta: videoMeta{ID: "9", Title: "Graph theory for kids", Duration: 6700}},
		{name: "the shared uploader name does not count",
			meta: videoMeta{ID: "9", Title: "proAlishke - Another offer story", Uploader: "proAlishke", Duration: 5000}},
		{name: "matching title but far-off length is not a duplicate",
			meta: videoMeta{ID: "9", Title: "Andrew Ng graph engineering course part 2", Duration: 3000}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, reason, ok := findDuplicate(c.meta, have)
			if c.wantPath == "" {
				if ok {
					t.Fatalf("want no duplicate, got %s (%s)", got.Path, reason)
				}
				return
			}
			if !ok || got.Path != c.wantPath {
				t.Fatalf("want %s, got %+v ok=%v", c.wantPath, got, ok)
			}
			if reason == "" {
				t.Error("a match must say why")
			}
		})
	}
}

func TestFillDurationsProbesAndSavesOnlyUnknownOnes(t *testing.T) {
	have := []remoteVideo{
		{Path: "/Videos/a.mp4", Duration: 10},
		{Path: "/Videos/b.mp4"},
		{Path: "/Videos/c.mp4"},
	}
	var probed, saved []string
	probe := func(p string) (float64, error) {
		probed = append(probed, p)
		if p == "/Videos/c.mp4" {
			return 0, errors.New("not a video")
		}
		return 42, nil
	}
	save := func(p string, d float64) { saved = append(saved, p) }
	fillDurations(have, probe, save)
	if strings.Join(probed, ",") != "/Videos/b.mp4,/Videos/c.mp4" {
		t.Errorf("probed %v", probed)
	}
	if strings.Join(saved, ",") != "/Videos/b.mp4" {
		t.Errorf("saved %v", saved)
	}
	if have[1].Duration != 42 || have[2].Duration != 0 {
		t.Errorf("durations not filled in place: %+v", have)
	}
}

func TestListVideosAndSetProps(t *testing.T) {
	fake := newFakeNextcloud()
	fake.files["/Videos/Talk [abc].mp4"] = []byte("0123456789")
	srv := httptest.NewServer(fake)
	defer srv.Close()
	u := testUploader(srv)

	if err := u.setVideoProps("/Videos/Talk [abc].mp4", map[string]string{"duration": "12.5", "id": "abc"}); err != nil {
		t.Fatalf("setVideoProps: %v", err)
	}
	got, err := u.listVideos()
	if err != nil {
		t.Fatalf("listVideos: %v", err)
	}
	if len(got) != 1 || got[0].Duration != 12.5 || got[0].ID != "abc" || got[0].Path != "/Videos/Talk [abc].mp4" {
		t.Errorf("got %+v", got)
	}
}

func TestListVideosWithNoFolderIsEmpty(t *testing.T) {
	srv := httptest.NewServer(newFakeNextcloud())
	defer srv.Close()
	got, err := testUploader(srv).listVideos()
	if err != nil || len(got) != 0 {
		t.Errorf("a missing Videos/ means nothing to compare against, got %v, %v", got, err)
	}
}
