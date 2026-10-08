package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// `homelab map`: static map images, KML/GPX files and geocoding for agents on
// the workstation, through the Geoapify key every workstation user can read.
// Design: docs/plans/2026-10-08-homelab-map-verb-design.md, ADR-0028.

// mapsKeyPath holds a copy of the Geoapify key Dawarich and secret/viktor use.
// wizard reads it through vault-admin, emo through the projects-emo policy.
const mapsKeyPath = "secret/workstation/shared/maps"

var (
	geoapifyStaticURL  = "https://maps.geoapify.com/v1/staticmap"
	geoapifyGeocodeURL = "https://api.geoapify.com/v1/geocode/search"
	mapHTTP            = &http.Client{Timeout: 60 * time.Second}
	// Geoapify's free plan allows 5 requests per second.
	geocodeSpacing = 220 * time.Millisecond
)

func mapCommands() []Command {
	return []Command{
		{Path: []string{"map"}, Tier: TierRead,
			Summary: "make maps: PNG with pins and lines, KML/GPX for a phone, geocode an address (run `map --help`)", Run: mapTopHelp},
		{Path: []string{"map", "render"}, Tier: TierWrite,
			Summary: "render GeoJSON to a PNG via Geoapify: map render <file.geojson|-> [-o out.png] [--size WxH] [--style S] [--share]", Run: mapRender},
		{Path: []string{"map", "export"}, Tier: TierWrite,
			Summary: "convert GeoJSON to KML or GPX: map export <file.geojson|-> --format kml|gpx [-o out] [--share]", Run: mapExport},
		{Path: []string{"map", "geocode"}, Tier: TierRead,
			Summary: "address to coordinates via Geoapify: map geocode \"<address>\" [--json]", Run: mapGeocode},
	}
}

func mapTopHelp(args []string) error { fmt.Print(mapHelp()); return nil }

func mapHelp() string {
	return `homelab map — maps on demand (Geoapify for images and geocoding, OSM data)

  map render <file.geojson|-> [flags]    PNG with numbered pins, lines, polygons
        -o, --output <file>              default: <input>.png, or map.png from stdin
        --size <WxH>                     default 1024x768, max 4096 per side
        --style <name>                   Geoapify style, default osm-bright
                                         (also: osm-carto, klokantech-basic, positron, dark-matter)
        --share                          upload to your Nextcloud, print a 30-day link
  map export <file.geojson|-> --format kml|gpx [-o file] [--share]
                                         KML for Google My Maps, GPX for nav apps.
                                         GPX has no polygons, so they are skipped.
  map geocode "<address>" [--json]       print lat,lon and the matched address

Input is a GeoJSON FeatureCollection (or one Feature). Point, LineString,
Polygon and their Multi forms are drawn. properties.name labels a feature,
properties.description goes into KML/GPX. A feature with "geometry": null and an
"address" property is geocoded first:

  {"type":"FeatureCollection","features":[
    {"type":"Feature","properties":{"name":"NDK","address":"NDK, Sofia"},"geometry":null},
    {"type":"Feature","properties":{"name":"Walk"},
     "geometry":{"type":"LineString","coordinates":[[23.3189,42.6847],[23.3329,42.6958]]}}]}

GeoJSON order is [lon, lat]. render prints the pin numbers with their names, so
a reply can carry the legend.

Cost: Geoapify's free plan has 3,000 credits a day, shared with Dawarich. A
static map is 1 + tiles/4 + 1 per pin (800x600 with six pins is 9); a geocode
is 1. The key is read from ` + mapsKeyPath + `.

Interactive map in a pages doc: no key, keyless OSM tiles. Paste this into the
markdown (it passes through as HTML) with your GeoJSON. Coordinates must be
filled in; geocode addresses first with "homelab map geocode".

  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <div id="map" style="height:420px;border-radius:8px"></div>
  <script>
  const data = {"type":"FeatureCollection","features":[]}; // your GeoJSON
  const map = L.map('map');
  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'}).addTo(map);
  const layer = L.geoJSON(data, {onEachFeature: (f, l) =>
    f.properties && f.properties.name && l.bindPopup(f.properties.name)}).addTo(map);
  map.fitBounds(layer.getBounds(), {padding: [24, 24]});
  </script>
`
}

func mapHelpWanted(args []string) bool {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			return true
		}
	}
	return false
}

// mapsAPIKey reads the Geoapify key with the caller's own Vault token.
func mapsAPIKey() (string, error) {
	ensureVaultAddr()
	k, err := kvGetField(realRunner, mapsKeyPath, "geoapify_api_key")
	if err != nil || strings.TrimSpace(k) == "" {
		return "", fmt.Errorf("cannot read geoapify_api_key from %s: %v\n"+
			"Access comes from vault-admin (wizard) or the projects-emo policy (emo) in stacks/vault/main.tf;\n"+
			"another user needs that path added to the policy their devvm token carries", mapsKeyPath, err)
	}
	return strings.TrimSpace(k), nil
}

func readMapInput(input string) ([]byte, error) {
	if input == "-" {
		return io.ReadAll(os.Stdin)
	}
	return os.ReadFile(input)
}

func geocodeAddress(key, address string) (geocodeResult, error) {
	req, err := http.NewRequest("GET", geocodeURL(geoapifyGeocodeURL, address, key), nil)
	if err != nil {
		return geocodeResult{}, err
	}
	req.Header.Set("User-Agent", homelabUserAgent())
	resp, err := mapHTTP.Do(req)
	if err != nil {
		return geocodeResult{}, fmt.Errorf("geocoding %q failed: %w", address, redactKey(err, key))
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	r, err := parseGeocodeResponse(body)
	if err != nil {
		return geocodeResult{}, fmt.Errorf("geocoding %q: %w", address, err)
	}
	if r.coarse() {
		fmt.Fprintf(os.Stderr, "warning: %q matched only at %s level (%s); the point may be far from the place, so give a fuller address or coordinates\n",
			address, r.ResultType, r.Formatted)
	}
	return r, nil
}

// redactKey keeps the API key out of error messages; net/http errors quote the
// full URL, which carries it as a query parameter.
func redactKey(err error, key string) error {
	if err == nil || key == "" {
		return err
	}
	return fmt.Errorf("%s", strings.ReplaceAll(err.Error(), url.QueryEscape(key), "REDACTED"))
}

// geocodeItems fills in every address-only item. It fetches the key lazily, so
// an export with coordinates only never touches Vault.
func geocodeItems(items []mapItem, key *string) error {
	first := true
	for i := range items {
		if items[i].Address == "" || len(items[i].Points) > 0 {
			continue
		}
		if *key == "" {
			k, err := mapsAPIKey()
			if err != nil {
				return err
			}
			*key = k
		}
		if !first {
			time.Sleep(geocodeSpacing)
		}
		first = false
		r, err := geocodeAddress(*key, items[i].Address)
		if err != nil {
			return err
		}
		items[i].Points = []mapPoint{{Lat: r.Lat, Lon: r.Lon}}
		fmt.Fprintf(os.Stderr, "geocoded %q -> %s,%s (%s)\n", items[i].Address, fmtCoord(r.Lat), fmtCoord(r.Lon), r.Formatted)
	}
	return nil
}

func fetchStaticMap(key string, req staticMapRequest) ([]byte, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	hreq, err := http.NewRequest("POST", geoapifyStaticURL+"?apiKey="+url.QueryEscape(key), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	hreq.Header.Set("Content-Type", "application/json")
	hreq.Header.Set("User-Agent", homelabUserAgent())
	resp, err := mapHTTP.Do(hreq)
	if err != nil {
		return nil, fmt.Errorf("static map request failed: %w", redactKey(err, key))
	}
	defer resp.Body.Close()
	img, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if resp.StatusCode != http.StatusOK || !strings.HasPrefix(resp.Header.Get("Content-Type"), "image/") {
		return nil, fmt.Errorf("Geoapify refused the static map: %s %s", resp.Status, truncateForError(string(img)))
	}
	return img, nil
}

func mapRender(args []string) error {
	if mapHelpWanted(args) {
		fmt.Print(mapHelp())
		return nil
	}
	a, err := parseMapArgs("render", args)
	if err != nil {
		return err
	}
	data, err := readMapInput(a.input)
	if err != nil {
		return fmt.Errorf("cannot read %s: %w", a.input, err)
	}
	items, err := parseMapInput(data)
	if err != nil {
		return err
	}
	key, err := mapsAPIKey()
	if err != nil {
		return err
	}
	if err := geocodeItems(items, &key); err != nil {
		return err
	}
	req, legend := buildStaticMapRequest(items, staticMapOptions{Width: a.width, Height: a.height, Style: a.style})
	img, err := fetchStaticMap(key, req)
	if err != nil {
		return err
	}
	out := a.output
	if out == "" {
		out = defaultMapOutput(a.input, "png")
	}
	if err := os.WriteFile(out, img, 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s (%dx%d)\n", out, a.width, a.height)
	for _, l := range legend {
		name := l.Name
		if name == "" {
			name = "(unnamed)"
		}
		fmt.Printf("  %d  %s  %s,%s\n", l.Number, name, fmtCoord(l.Lat), fmtCoord(l.Lon))
	}
	if a.share {
		return shareMapFile(out, img, false)
	}
	return nil
}

func mapExport(args []string) error {
	if mapHelpWanted(args) {
		fmt.Print(mapHelp())
		return nil
	}
	a, err := parseMapArgs("export", args)
	if err != nil {
		return err
	}
	data, err := readMapInput(a.input)
	if err != nil {
		return fmt.Errorf("cannot read %s: %w", a.input, err)
	}
	items, err := parseMapInput(data)
	if err != nil {
		return err
	}
	var key string
	if err := geocodeItems(items, &key); err != nil {
		return err
	}
	docName := "map"
	if a.input != "-" {
		docName = strings.TrimSuffix(filepath.Base(a.input), filepath.Ext(a.input))
	}
	var content string
	switch a.format {
	case "kml":
		content = encodeKML(items, docName)
	case "gpx":
		var skipped int
		content, skipped = encodeGPX(items, docName)
		if skipped > 0 {
			fmt.Fprintf(os.Stderr, "warning: skipped %d polygon(s); GPX has no polygon type (use --format kml)\n", skipped)
		}
	}
	out := a.output
	if out == "" {
		out = defaultMapOutput(a.input, a.format)
	}
	if err := os.WriteFile(out, []byte(content), 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s\n", out)
	if a.share {
		return shareMapFile(out, []byte(content), true)
	}
	return nil
}

func mapGeocode(args []string) error {
	if mapHelpWanted(args) {
		fmt.Print(mapHelp())
		return nil
	}
	var words []string
	asJSON := false
	for _, a := range args {
		if strings.HasPrefix(a, "-") {
			if name, _, _ := flagToken(a); name == "json" {
				asJSON = true
				continue
			}
			return fmt.Errorf("unknown flag %q; map geocode takes --json", a)
		}
		words = append(words, a)
	}
	address := strings.TrimSpace(strings.Join(words, " "))
	if address == "" {
		return fmt.Errorf("usage: homelab map geocode \"<address>\" [--json]")
	}
	key, err := mapsAPIKey()
	if err != nil {
		return err
	}
	r, err := geocodeAddress(key, address)
	if err != nil {
		return err
	}
	if asJSON {
		b, _ := json.Marshal(r)
		fmt.Println(string(b))
		return nil
	}
	fmt.Printf("%s,%s  %s\n", fmtCoord(r.Lat), fmtCoord(r.Lon), r.Formatted)
	return nil
}

// shareMapFile uploads through the `homelab share` path: the caller's own
// Nextcloud, /_share/, a 30-day public link. Stale map uploads are pruned
// first; a pruning failure is a warning, never a reason to skip the share.
func shareMapFile(local string, content []byte, scan bool) error {
	if scan {
		if err := guardContent(gitleaksScan, content, false, "share"); err != nil {
			return err
		}
	}
	user, pass, err := nextcloudCreds()
	if err != nil {
		return err
	}
	if n, err := pruneMapShares(user, pass, time.Now()); err != nil {
		fmt.Fprintf(os.Stderr, "warning: could not prune old map shares: %v\n", err)
	} else if n > 0 {
		fmt.Fprintf(os.Stderr, "pruned %d map share(s) older than 30 days\n", n)
	}
	remote := remoteSharePath(mapShareName(local), time.Now().Format("20060102-150405"))
	if err := webdavPut(user, pass, remote, content); err != nil {
		return err
	}
	link, expiration, err := createPublicShare(user, pass, remote, defaultShareExpireDays)
	if err != nil {
		return err
	}
	fmt.Println(link)
	if expiration != "" {
		fmt.Fprintf(os.Stderr, "expires %s\n", expiration)
	}
	return nil
}

func pruneMapShares(user, pass string, now time.Time) (int, error) {
	dir := nextcloudHost + "/remote.php/dav/files/" + url.PathEscape(user) + strings.TrimSuffix(shareUploadDir, "/")
	req, err := http.NewRequest("PROPFIND", dir, strings.NewReader(
		`<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getlastmodified/></d:prop></d:propfind>`))
	if err != nil {
		return 0, err
	}
	req.SetBasicAuth(user, pass)
	req.Header.Set("Depth", "1")
	req.Header.Set("Content-Type", "application/xml")
	req.Header.Set("User-Agent", homelabUserAgent())
	resp, err := mapHTTP.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return 0, nil // no /_share/ yet, nothing to prune
	}
	if resp.StatusCode != http.StatusMultiStatus {
		return 0, fmt.Errorf("PROPFIND %s: %s", shareUploadDir, resp.Status)
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	entries, err := parsePropfind(body)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, href := range selectPrunable(entries, now, mapShareMaxAge) {
		del, err := http.NewRequest("DELETE", nextcloudHost+href, nil)
		if err != nil {
			return n, err
		}
		del.SetBasicAuth(user, pass)
		del.Header.Set("User-Agent", homelabUserAgent())
		r, err := mapHTTP.Do(del)
		if err != nil {
			return n, err
		}
		r.Body.Close()
		if r.StatusCode >= 200 && r.StatusCode < 300 {
			n++
		}
	}
	return n, nil
}
