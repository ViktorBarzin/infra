package main

import (
	"encoding/json"
	"encoding/xml"
	"fmt"
	"net/http"
	"net/url"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Pure pieces of `homelab map`: GeoJSON in, a Geoapify request body, KML or GPX
// out, and the selection of stale shared map files. No network or Vault here,
// so each is table-tested in map_test.go. Decision record: ADR-0028.

const (
	kindPoint   = "point"
	kindLine    = "line"
	kindPolygon = "polygon"
)

type mapPoint struct {
	Lat float64 `json:"lat"`
	Lon float64 `json:"lon"`
}

// mapItem is one drawable thing. Multi* geometries are flattened into several
// items sharing a name, and a polygon keeps only its outer ring.
type mapItem struct {
	Kind        string
	Name        string
	Description string
	// Address is set when the feature had no geometry and must be geocoded
	// before it can be drawn. Points stays empty until then.
	Address string
	Points  []mapPoint
}

type geoJSONGeometry struct {
	Type        string          `json:"type"`
	Coordinates json.RawMessage `json:"coordinates"`
}

type geoJSONFeature struct {
	Type       string           `json:"type"`
	Properties map[string]any   `json:"properties"`
	Geometry   *geoJSONGeometry `json:"geometry"`
}

// parseMapInput reads a FeatureCollection or a single Feature.
func parseMapInput(data []byte) ([]mapItem, error) {
	var doc struct {
		Type       string           `json:"type"`
		Features   []geoJSONFeature `json:"features"`
		Properties map[string]any   `json:"properties"`
		Geometry   *geoJSONGeometry `json:"geometry"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("input is not GeoJSON: %w", err)
	}
	var features []geoJSONFeature
	switch doc.Type {
	case "FeatureCollection":
		features = doc.Features
	case "Feature":
		features = []geoJSONFeature{{Type: "Feature", Properties: doc.Properties, Geometry: doc.Geometry}}
	default:
		return nil, fmt.Errorf("want a GeoJSON FeatureCollection or Feature, got type %q", doc.Type)
	}
	if len(features) == 0 {
		return nil, fmt.Errorf("the FeatureCollection has no features")
	}
	var items []mapItem
	for i, f := range features {
		got, err := featureItems(f)
		if err != nil {
			return nil, fmt.Errorf("feature %d: %w", i+1, err)
		}
		items = append(items, got...)
	}
	return items, nil
}

func propString(props map[string]any, key string) string {
	if v, ok := props[key].(string); ok {
		return strings.TrimSpace(v)
	}
	return ""
}

func featureItems(f geoJSONFeature) ([]mapItem, error) {
	base := mapItem{
		Name:        propString(f.Properties, "name"),
		Description: propString(f.Properties, "description"),
	}
	if f.Geometry == nil {
		addr := propString(f.Properties, "address")
		if addr == "" {
			return nil, fmt.Errorf("no geometry and no \"address\" property to geocode")
		}
		base.Kind = kindPoint
		base.Address = addr
		return []mapItem{base}, nil
	}
	g := f.Geometry
	with := func(kind string, pts []mapPoint) mapItem {
		it := base
		it.Kind = kind
		it.Points = pts
		return it
	}
	switch g.Type {
	case "Point":
		var c []float64
		if err := json.Unmarshal(g.Coordinates, &c); err != nil {
			return nil, fmt.Errorf("Point coordinates: %w", err)
		}
		p, err := toPoint(c)
		if err != nil {
			return nil, err
		}
		return []mapItem{with(kindPoint, []mapPoint{p})}, nil
	case "MultiPoint", "LineString":
		var cs [][]float64
		if err := json.Unmarshal(g.Coordinates, &cs); err != nil {
			return nil, fmt.Errorf("%s coordinates: %w", g.Type, err)
		}
		pts, err := toPoints(cs)
		if err != nil {
			return nil, err
		}
		if g.Type == "LineString" {
			return []mapItem{with(kindLine, pts)}, nil
		}
		var out []mapItem
		for _, p := range pts {
			out = append(out, with(kindPoint, []mapPoint{p}))
		}
		return out, nil
	case "MultiLineString", "Polygon":
		var css [][][]float64
		if err := json.Unmarshal(g.Coordinates, &css); err != nil {
			return nil, fmt.Errorf("%s coordinates: %w", g.Type, err)
		}
		if g.Type == "Polygon" {
			if len(css) == 0 {
				return nil, fmt.Errorf("Polygon has no rings")
			}
			pts, err := toPoints(css[0])
			if err != nil {
				return nil, err
			}
			return []mapItem{with(kindPolygon, pts)}, nil
		}
		var out []mapItem
		for _, cs := range css {
			pts, err := toPoints(cs)
			if err != nil {
				return nil, err
			}
			out = append(out, with(kindLine, pts))
		}
		return out, nil
	case "MultiPolygon":
		var polys [][][][]float64
		if err := json.Unmarshal(g.Coordinates, &polys); err != nil {
			return nil, fmt.Errorf("MultiPolygon coordinates: %w", err)
		}
		var out []mapItem
		for _, rings := range polys {
			if len(rings) == 0 {
				continue
			}
			pts, err := toPoints(rings[0])
			if err != nil {
				return nil, err
			}
			out = append(out, with(kindPolygon, pts))
		}
		return out, nil
	default:
		return nil, fmt.Errorf("unsupported geometry %q (use Point, LineString, Polygon or their Multi forms)", g.Type)
	}
}

// toPoint converts a GeoJSON position, which is [lon, lat].
func toPoint(c []float64) (mapPoint, error) {
	if len(c) < 2 {
		return mapPoint{}, fmt.Errorf("position %v needs [lon, lat]", c)
	}
	p := mapPoint{Lat: c[1], Lon: c[0]}
	if p.Lat < -90 || p.Lat > 90 || p.Lon < -180 || p.Lon > 180 {
		return mapPoint{}, fmt.Errorf("position %v is out of range; GeoJSON order is [lon, lat]", c)
	}
	return p, nil
}

func toPoints(cs [][]float64) ([]mapPoint, error) {
	out := make([]mapPoint, 0, len(cs))
	for _, c := range cs {
		p, err := toPoint(c)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, nil
}

// --- geocoding ----------------------------------------------------------------

type geocodeResult struct {
	Lat        float64 `json:"lat"`
	Lon        float64 `json:"lon"`
	Formatted  string  `json:"formatted"`
	ResultType string  `json:"result_type"`
}

// coarse reports a match at area level rather than the place itself. Geoapify
// returns the city centre when it cannot find a street, and a pin there looks
// plausible while being wrong.
func (r geocodeResult) coarse() bool {
	switch r.ResultType {
	case "country", "state", "county", "city", "postcode", "suburb", "district":
		return true
	}
	return false
}

func parseGeocodeResponse(body []byte) (geocodeResult, error) {
	var r struct {
		Results    []geocodeResult `json:"results"`
		StatusCode int             `json:"statusCode"`
		Message    string          `json:"message"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return geocodeResult{}, fmt.Errorf("unexpected geocoder response: %s", truncateForError(string(body)))
	}
	if r.StatusCode != 0 && r.StatusCode != http.StatusOK {
		return geocodeResult{}, fmt.Errorf("geocoder refused the request (%d): %s", r.StatusCode, r.Message)
	}
	if len(r.Results) == 0 {
		return geocodeResult{}, fmt.Errorf("no match")
	}
	return r.Results[0], nil
}

func geocodeURL(base, address, apiKey string) string {
	q := url.Values{}
	q.Set("text", address)
	q.Set("limit", "1")
	q.Set("format", "json")
	q.Set("apiKey", apiKey)
	return base + "?" + q.Encode()
}

// --- static map request -------------------------------------------------------

type staticMapOptions struct {
	Width, Height int
	Style         string
}

type staticMarker struct {
	Lat          float64 `json:"lat"`
	Lon          float64 `json:"lon"`
	Type         string  `json:"type"`
	Color        string  `json:"color"`
	Size         string  `json:"size"`
	Text         string  `json:"text"`
	ContentColor string  `json:"contentcolor"`
}

type staticGeometry struct {
	Type        string     `json:"type"`
	Value       []mapPoint `json:"value"`
	LineColor   string     `json:"linecolor"`
	LineWidth   int        `json:"linewidth"`
	FillColor   string     `json:"fillcolor,omitempty"`
	FillOpacity float64    `json:"fillopacity,omitempty"`
}

type staticMapRequest struct {
	Style      string           `json:"style"`
	Width      int              `json:"width"`
	Height     int              `json:"height"`
	Format     string           `json:"format"`
	Markers    []staticMarker   `json:"markers,omitempty"`
	Geometries []staticGeometry `json:"geometries,omitempty"`
}

type legendEntry struct {
	Number   int
	Name     string
	Lat, Lon float64
}

const mapAccent = "#d6336c"

// buildStaticMapRequest turns drawable items into Geoapify's POST body. Points
// become markers numbered in input order; the returned legend maps each number
// back to its name. No centre or zoom is sent, so Geoapify fits the view.
func buildStaticMapRequest(items []mapItem, o staticMapOptions) (staticMapRequest, []legendEntry) {
	req := staticMapRequest{Style: o.Style, Width: o.Width, Height: o.Height, Format: "png"}
	var legend []legendEntry
	for _, it := range items {
		if len(it.Points) == 0 {
			continue
		}
		switch it.Kind {
		case kindPoint:
			n := len(req.Markers) + 1
			p := it.Points[0]
			req.Markers = append(req.Markers, staticMarker{
				Lat: p.Lat, Lon: p.Lon, Type: "material", Color: mapAccent, Size: "large",
				Text: strconv.Itoa(n), ContentColor: "#ffffff",
			})
			legend = append(legend, legendEntry{Number: n, Name: it.Name, Lat: p.Lat, Lon: p.Lon})
		case kindLine:
			req.Geometries = append(req.Geometries, staticGeometry{
				Type: "polyline", Value: it.Points, LineColor: mapAccent, LineWidth: 4,
			})
		case kindPolygon:
			req.Geometries = append(req.Geometries, staticGeometry{
				Type: "polygon", Value: it.Points, LineColor: mapAccent, LineWidth: 2,
				FillColor: mapAccent, FillOpacity: 0.2,
			})
		}
	}
	return req, legend
}

// parseSize reads WIDTHxHEIGHT within Geoapify's 4096px limit.
func parseSize(s string) (int, int, error) {
	w, h, ok := strings.Cut(strings.ToLower(s), "x")
	if !ok {
		return 0, 0, fmt.Errorf("--size wants WIDTHxHEIGHT, got %q", s)
	}
	wi, err1 := strconv.Atoi(w)
	hi, err2 := strconv.Atoi(h)
	if err1 != nil || err2 != nil || wi < 1 || hi < 1 || wi > 4096 || hi > 4096 {
		return 0, 0, fmt.Errorf("--size wants WIDTHxHEIGHT between 1 and 4096, got %q", s)
	}
	return wi, hi, nil
}

// --- KML and GPX --------------------------------------------------------------

func xmlEscape(s string) string {
	var b strings.Builder
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}

func fmtCoord(f float64) string { return strconv.FormatFloat(f, 'f', -1, 64) }

// kmlCoords renders lon,lat pairs, the order KML uses.
func kmlCoords(pts []mapPoint) string {
	parts := make([]string, len(pts))
	for i, p := range pts {
		parts[i] = fmtCoord(p.Lon) + "," + fmtCoord(p.Lat)
	}
	return strings.Join(parts, " ")
}

func encodeKML(items []mapItem, docName string) string {
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?>` + "\n")
	b.WriteString(`<kml xmlns="http://www.opengis.net/kml/2.2"><Document>` + "\n")
	fmt.Fprintf(&b, "<name>%s</name>\n", xmlEscape(docName))
	for _, it := range items {
		if len(it.Points) == 0 {
			continue
		}
		b.WriteString("<Placemark>")
		if it.Name != "" {
			fmt.Fprintf(&b, "<name>%s</name>", xmlEscape(it.Name))
		}
		if it.Description != "" {
			fmt.Fprintf(&b, "<description>%s</description>", xmlEscape(it.Description))
		}
		switch it.Kind {
		case kindPoint:
			fmt.Fprintf(&b, "<Point><coordinates>%s</coordinates></Point>", kmlCoords(it.Points[:1]))
		case kindLine:
			fmt.Fprintf(&b, "<LineString><coordinates>%s</coordinates></LineString>", kmlCoords(it.Points))
		case kindPolygon:
			fmt.Fprintf(&b, "<Polygon><outerBoundaryIs><LinearRing><coordinates>%s</coordinates></LinearRing></outerBoundaryIs></Polygon>", kmlCoords(it.Points))
		}
		b.WriteString("</Placemark>\n")
	}
	b.WriteString("</Document></kml>\n")
	return b.String()
}

// encodeGPX writes points as waypoints and lines as tracks. GPX has no polygon,
// so polygons are skipped and counted for the caller to report.
func encodeGPX(items []mapItem, docName string) (string, int) {
	var b strings.Builder
	skipped := 0
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?>` + "\n")
	b.WriteString(`<gpx version="1.1" creator="homelab map" xmlns="http://www.topografix.com/GPX/1/1">` + "\n")
	fmt.Fprintf(&b, "<metadata><name>%s</name></metadata>\n", xmlEscape(docName))
	var tracks strings.Builder
	for _, it := range items {
		if len(it.Points) == 0 {
			continue
		}
		switch it.Kind {
		case kindPoint:
			p := it.Points[0]
			fmt.Fprintf(&b, `<wpt lat="%s" lon="%s">`, fmtCoord(p.Lat), fmtCoord(p.Lon))
			if it.Name != "" {
				fmt.Fprintf(&b, "<name>%s</name>", xmlEscape(it.Name))
			}
			if it.Description != "" {
				fmt.Fprintf(&b, "<desc>%s</desc>", xmlEscape(it.Description))
			}
			b.WriteString("</wpt>\n")
		case kindLine:
			tracks.WriteString("<trk>")
			if it.Name != "" {
				fmt.Fprintf(&tracks, "<name>%s</name>", xmlEscape(it.Name))
			}
			tracks.WriteString("<trkseg>")
			for _, p := range it.Points {
				fmt.Fprintf(&tracks, `<trkpt lat="%s" lon="%s"></trkpt>`, fmtCoord(p.Lat), fmtCoord(p.Lon))
			}
			tracks.WriteString("</trkseg></trk>\n")
		case kindPolygon:
			skipped++
		}
	}
	// GPX 1.1 requires every wpt before any trk.
	b.WriteString(tracks.String())
	b.WriteString("</gpx>\n")
	return b.String(), skipped
}

// --- sharing and pruning ------------------------------------------------------

// mapShareMarker is what every shared map file carries in its remote name, so
// pruning can tell map uploads apart from other `homelab share` files.
const mapShareMarker = "-map-"

const mapShareMaxAge = 30 * 24 * time.Hour

func mapShareName(local string) string {
	base := filepath.Base(local)
	if strings.HasPrefix(base, "map-") {
		return base
	}
	return "map-" + base
}

type davEntry struct {
	Href     string
	Modified time.Time
}

func parsePropfind(body []byte) ([]davEntry, error) {
	var ms struct {
		Responses []struct {
			Href     string `xml:"href"`
			Modified string `xml:"propstat>prop>getlastmodified"`
		} `xml:"response"`
	}
	if err := xml.Unmarshal(body, &ms); err != nil {
		return nil, fmt.Errorf("unexpected PROPFIND response: %w", err)
	}
	var out []davEntry
	for _, r := range ms.Responses {
		t, err := http.ParseTime(r.Modified)
		if err != nil {
			continue
		}
		out = append(out, davEntry{Href: r.Href, Modified: t})
	}
	return out, nil
}

// selectPrunable returns the hrefs of map uploads older than maxAge. Anything
// without the map marker, and the directory itself, is never selected.
func selectPrunable(entries []davEntry, now time.Time, maxAge time.Duration) []string {
	var out []string
	for _, e := range entries {
		name := path.Base(strings.TrimSuffix(e.Href, "/"))
		if strings.HasSuffix(e.Href, "/") || !strings.Contains(name, mapShareMarker) {
			continue
		}
		if now.Sub(e.Modified) > maxAge {
			out = append(out, e.Href)
		}
	}
	return out
}

// --- arguments ----------------------------------------------------------------

type mapArgs struct {
	input         string
	output        string
	width, height int
	style         string
	format        string
	share         bool
}

// parseMapArgs parses render and export argv strictly: an unknown flag, a
// second input or a valueless flag is an error, never a silent default.
func parseMapArgs(sub string, args []string) (mapArgs, error) {
	out := mapArgs{width: 1024, height: 768, style: "osm-bright"}
	value := func(i *int, name, v string, has bool) (string, error) {
		if has {
			return v, nil
		}
		if *i+1 >= len(args) || (strings.HasPrefix(args[*i+1], "-") && args[*i+1] != "-") {
			return "", fmt.Errorf("--%s needs a value", name)
		}
		*i++
		return args[*i], nil
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "-" || !strings.HasPrefix(a, "-") {
			if out.input != "" {
				return out, fmt.Errorf("unexpected argument %q; map %s takes ONE input file (or - for stdin)", a, sub)
			}
			out.input = a
			continue
		}
		name, v, has := flagToken(a)
		var err error
		switch {
		case name == "o" || name == "output":
			out.output, err = value(&i, "output", v, has)
		case name == "share":
			out.share = true
		case name == "size" && sub == "render":
			var s string
			if s, err = value(&i, "size", v, has); err == nil {
				out.width, out.height, err = parseSize(s)
			}
		case name == "style" && sub == "render":
			out.style, err = value(&i, "style", v, has)
		case name == "format" && sub == "export":
			out.format, err = value(&i, "format", v, has)
		default:
			return out, fmt.Errorf("unknown flag %q for map %s (see homelab map --help)", a, sub)
		}
		if err != nil {
			return out, err
		}
	}
	if out.input == "" {
		return out, fmt.Errorf("usage: homelab map %s <file.geojson|-> (see homelab map --help)", sub)
	}
	if sub == "export" && out.format != "kml" && out.format != "gpx" {
		return out, fmt.Errorf("map export needs --format kml or --format gpx")
	}
	return out, nil
}

func defaultMapOutput(input, ext string) string {
	if input == "-" {
		return "map." + ext
	}
	base := filepath.Base(input)
	return strings.TrimSuffix(base, filepath.Ext(base)) + "." + ext
}
