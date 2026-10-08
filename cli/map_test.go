package main

import (
	"encoding/json"
	"encoding/xml"
	"strings"
	"testing"
	"time"
)

const sampleFC = `{"type":"FeatureCollection","features":[
 {"type":"Feature","properties":{"name":"NDK","description":"Palace of Culture"},
  "geometry":{"type":"Point","coordinates":[23.3189,42.6847]}},
 {"type":"Feature","properties":{"name":"Nevsky","address":"Alexander Nevsky Cathedral, Sofia"},
  "geometry":null},
 {"type":"Feature","properties":{"name":"Walk"},
  "geometry":{"type":"LineString","coordinates":[[23.3189,42.6847],[23.3329,42.6958]]}},
 {"type":"Feature","properties":{"name":"Park"},
  "geometry":{"type":"Polygon","coordinates":[[[23.33,42.68],[23.34,42.68],[23.34,42.69],[23.33,42.68]]]}}
]}`

func TestParseMapInputFeatureCollection(t *testing.T) {
	items, err := parseMapInput([]byte(sampleFC))
	if err != nil {
		t.Fatalf("parseMapInput: %v", err)
	}
	if len(items) != 4 {
		t.Fatalf("want 4 items, got %d: %+v", len(items), items)
	}
	ndk := items[0]
	if ndk.Kind != kindPoint || ndk.Name != "NDK" || ndk.Description != "Palace of Culture" {
		t.Errorf("point parsed wrong: %+v", ndk)
	}
	// GeoJSON is [lon, lat]; the model is lat/lon. Getting this backwards puts
	// Sofia in Somalia, so pin it.
	if ndk.Points[0].Lat != 42.6847 || ndk.Points[0].Lon != 23.3189 {
		t.Errorf("coordinate order wrong: %+v", ndk.Points[0])
	}
	if items[1].Address != "Alexander Nevsky Cathedral, Sofia" || len(items[1].Points) != 0 {
		t.Errorf("address-only feature parsed wrong: %+v", items[1])
	}
	if items[2].Kind != kindLine || len(items[2].Points) != 2 {
		t.Errorf("line parsed wrong: %+v", items[2])
	}
	if items[3].Kind != kindPolygon || len(items[3].Points) != 4 {
		t.Errorf("polygon parsed wrong: %+v", items[3])
	}
}

func TestParseMapInputAcceptsASingleFeatureAndMultiGeometries(t *testing.T) {
	single := `{"type":"Feature","properties":{"name":"A"},"geometry":{"type":"Point","coordinates":[1,2]}}`
	items, err := parseMapInput([]byte(single))
	if err != nil || len(items) != 1 {
		t.Fatalf("single feature: items=%+v err=%v", items, err)
	}
	multi := `{"type":"Feature","properties":{"name":"M"},"geometry":{"type":"MultiPoint","coordinates":[[1,2],[3,4]]}}`
	items, err = parseMapInput([]byte(multi))
	if err != nil || len(items) != 2 || items[1].Points[0].Lat != 4 {
		t.Fatalf("multipoint should flatten into two points: items=%+v err=%v", items, err)
	}
	ml := `{"type":"Feature","properties":{},"geometry":{"type":"MultiLineString","coordinates":[[[1,2],[3,4]],[[5,6],[7,8]]]}}`
	items, err = parseMapInput([]byte(ml))
	if err != nil || len(items) != 2 || items[0].Kind != kindLine {
		t.Fatalf("multilinestring should flatten into two lines: items=%+v err=%v", items, err)
	}
}

func TestParseMapInputRejectsBadInput(t *testing.T) {
	cases := map[string]string{
		"not json":            `nope`,
		"wrong type":          `{"type":"Topology"}`,
		"empty collection":    `{"type":"FeatureCollection","features":[]}`,
		"no geometry or addr": `{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"x"},"geometry":null}]}`,
		"latitude out of range": `{"type":"FeatureCollection","features":[{"type":"Feature","properties":{},
			"geometry":{"type":"Point","coordinates":[23.3,142.6]}}]}`,
		"unsupported geometry": `{"type":"FeatureCollection","features":[{"type":"Feature","properties":{},
			"geometry":{"type":"GeometryCollection","geometries":[]}}]}`,
	}
	for name, in := range cases {
		if _, err := parseMapInput([]byte(in)); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}

func TestParseGeocodeResponse(t *testing.T) {
	body := `{"results":[{"lat":42.6958,"lon":23.3329,"formatted":"Alexander Nevsky Cathedral, Sofia, Bulgaria"}]}`
	r, err := parseGeocodeResponse([]byte(body))
	if err != nil {
		t.Fatalf("parseGeocodeResponse: %v", err)
	}
	if r.Lat != 42.6958 || r.Lon != 23.3329 || !strings.Contains(r.Formatted, "Nevsky") {
		t.Errorf("unexpected result %+v", r)
	}
	if _, err := parseGeocodeResponse([]byte(`{"results":[]}`)); err == nil {
		t.Error("no results must be an error, not a 0,0 pin off the coast of Africa")
	}
	if _, err := parseGeocodeResponse([]byte(`{"statusCode":401,"message":"Invalid apiKey"}`)); err == nil {
		t.Error("an API error body must be an error")
	}
}

func TestBuildStaticMapRequestNumbersPointsInOrder(t *testing.T) {
	items, _ := parseMapInput([]byte(sampleFC))
	items[1].Points = []mapPoint{{Lat: 42.6958, Lon: 23.3329}} // as if geocoded
	req, legend := buildStaticMapRequest(items, staticMapOptions{Width: 800, Height: 600, Style: "osm-bright"})
	if req.Width != 800 || req.Height != 600 || req.Style != "osm-bright" || req.Format != "png" {
		t.Errorf("options not carried: %+v", req)
	}
	if len(req.Markers) != 2 || req.Markers[0].Text != "1" || req.Markers[1].Text != "2" {
		t.Fatalf("want two markers numbered 1 and 2, got %+v", req.Markers)
	}
	if req.Markers[1].Lat != 42.6958 {
		t.Errorf("marker 2 should be the geocoded point: %+v", req.Markers[1])
	}
	if len(req.Geometries) != 2 || req.Geometries[0].Type != "polyline" || req.Geometries[1].Type != "polygon" {
		t.Fatalf("want a polyline and a polygon, got %+v", req.Geometries)
	}
	if len(req.Geometries[0].Value) != 2 || req.Geometries[0].Value[1].Lat != 42.6958 {
		t.Errorf("polyline points wrong: %+v", req.Geometries[0].Value)
	}
	if len(legend) != 2 || legend[0] != (legendEntry{Number: 1, Name: "NDK", Lat: 42.6847, Lon: 23.3189}) {
		t.Errorf("legend wrong: %+v", legend)
	}
	// The body is what goes over the wire; Geoapify wants {lat, lon} objects.
	b, _ := json.Marshal(req)
	if !strings.Contains(string(b), `"lat":42.6847`) || !strings.Contains(string(b), `"lon":23.3189`) {
		t.Errorf("wire body lacks lat/lon objects: %s", b)
	}
}

func TestParseSize(t *testing.T) {
	good := map[string][2]int{"1024x768": {1024, 768}, "400X300": {400, 300}}
	for in, want := range good {
		w, h, err := parseSize(in)
		if err != nil || w != want[0] || h != want[1] {
			t.Errorf("parseSize(%q) = %d,%d,%v want %v", in, w, h, err, want)
		}
	}
	for _, in := range []string{"", "1024", "0x10", "5000x100", "axb"} {
		if _, _, err := parseSize(in); err == nil {
			t.Errorf("parseSize(%q) should fail", in)
		}
	}
}

func TestEncodeKMLIsValidXMLAndCarriesEverything(t *testing.T) {
	items, _ := parseMapInput([]byte(sampleFC))
	items[1].Points = []mapPoint{{Lat: 42.6958, Lon: 23.3329}}
	items[0].Description = `Fish & chips <b>here</b>`
	out := encodeKML(items, "Sofia walk")
	var doc struct {
		XMLName xml.Name
	}
	if err := xml.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("KML is not well-formed XML: %v\n%s", err, out)
	}
	for _, want := range []string{
		"<name>Sofia walk</name>",
		"<name>NDK</name>",
		"Fish &amp; chips &lt;b&gt;here&lt;/b&gt;",
		"<coordinates>23.3189,42.6847</coordinates>", // KML is lon,lat
		"<LineString>", "<Polygon>", "<outerBoundaryIs>",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("KML missing %q", want)
		}
	}
}

func TestEncodeGPXSkipsPolygons(t *testing.T) {
	items, _ := parseMapInput([]byte(sampleFC))
	items[1].Points = []mapPoint{{Lat: 42.6958, Lon: 23.3329}}
	out, skipped := encodeGPX(items, "Sofia walk")
	if skipped != 1 {
		t.Errorf("want the polygon skipped, skipped=%d", skipped)
	}
	var doc struct{ XMLName xml.Name }
	if err := xml.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("GPX is not well-formed XML: %v\n%s", err, out)
	}
	if strings.Count(out, "<wpt ") != 2 || strings.Count(out, "<trkpt ") != 2 {
		t.Errorf("want 2 waypoints and 2 track points:\n%s", out)
	}
	if !strings.Contains(out, `<wpt lat="42.6847" lon="23.3189">`) {
		t.Errorf("waypoint attributes wrong:\n%s", out)
	}
}

func TestMapShareName(t *testing.T) {
	cases := map[string]string{
		"places.png":       "map-places.png",
		"/tmp/x/route.kml": "map-route.kml",
		"map-sofia.png":    "map-sofia.png",
	}
	for in, want := range cases {
		if got := mapShareName(in); got != want {
			t.Errorf("mapShareName(%q) = %q want %q", in, got, want)
		}
	}
	// The remote path must carry the -map- marker the pruner keys on.
	if p := remoteSharePath(mapShareName("a.png"), "20261008-120000"); !strings.Contains(p, "-map-") {
		t.Errorf("remote path %q lacks the -map- marker", p)
	}
}

func TestParsePropfindAndSelectPrunable(t *testing.T) {
	body := `<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
 <d:response><d:href>/remote.php/dav/files/wizard/_share/</d:href>
  <d:propstat><d:prop><d:getlastmodified>Mon, 01 Jun 2026 10:00:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/wizard/_share/20260801-100000-map-old.png</d:href>
  <d:propstat><d:prop><d:getlastmodified>Sat, 01 Aug 2026 10:00:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/wizard/_share/20261001-100000-map-new.png</d:href>
  <d:propstat><d:prop><d:getlastmodified>Thu, 01 Oct 2026 10:00:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/wizard/_share/20260801-100000-app.log</d:href>
  <d:propstat><d:prop><d:getlastmodified>Sat, 01 Aug 2026 10:00:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
</d:multistatus>`
	entries, err := parsePropfind([]byte(body))
	if err != nil {
		t.Fatalf("parsePropfind: %v", err)
	}
	if len(entries) != 4 {
		t.Fatalf("want 4 entries, got %+v", entries)
	}
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	got := selectPrunable(entries, now, 30*24*time.Hour)
	if len(got) != 1 || !strings.HasSuffix(got[0], "20260801-100000-map-old.png") {
		t.Errorf("want only the old map file pruned (never the dir, never a non-map file), got %v", got)
	}
}

func TestParseMapArgs(t *testing.T) {
	a, err := parseMapArgs("render", []string{"p.geojson", "-o", "out.png", "--size=800x600", "--share"})
	if err != nil {
		t.Fatalf("render args: %v", err)
	}
	if a.input != "p.geojson" || a.output != "out.png" || a.width != 800 || a.height != 600 || !a.share || a.style != "osm-bright" {
		t.Errorf("render args parsed wrong: %+v", a)
	}
	a, err = parseMapArgs("export", []string{"-", "--format", "gpx"})
	if err != nil || a.input != "-" || a.format != "gpx" {
		t.Errorf("export args: %+v %v", a, err)
	}
	for name, argv := range map[string][]string{
		"unknown flag":      {"p.geojson", "--colour", "red"},
		"two inputs":        {"a.geojson", "b.geojson"},
		"no input":          {"-o", "x.png"},
		"valueless output":  {"p.geojson", "-o"},
		"export bad format": {"p.geojson", "--format", "shp"},
	} {
		sub := "render"
		if strings.HasPrefix(name, "export") {
			sub = "export"
		}
		if _, err := parseMapArgs(sub, argv); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
	if _, err := parseMapArgs("export", []string{"p.geojson"}); err == nil {
		t.Error("export without --format must be an error")
	}
}

func TestDefaultMapOutput(t *testing.T) {
	cases := []struct{ in, ext, want string }{
		{"places.geojson", "png", "places.png"},
		{"/data/trip.json", "kml", "trip.kml"},
		{"-", "gpx", "map.gpx"},
	}
	for _, c := range cases {
		if got := defaultMapOutput(c.in, c.ext); got != c.want {
			t.Errorf("defaultMapOutput(%q,%q) = %q want %q", c.in, c.ext, got, c.want)
		}
	}
}
