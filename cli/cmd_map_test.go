package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func withGeoapify(t *testing.T, h http.HandlerFunc) {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	oldS, oldG := geoapifyStaticURL, geoapifyGeocodeURL
	geoapifyStaticURL, geoapifyGeocodeURL = srv.URL+"/v1/staticmap", srv.URL+"/v1/geocode/search"
	t.Cleanup(func() { geoapifyStaticURL, geoapifyGeocodeURL = oldS, oldG })
}

func TestFetchStaticMapPostsJSONWithKey(t *testing.T) {
	var gotBody staticMapRequest
	var gotKey, gotCT string
	withGeoapify(t, func(w http.ResponseWriter, r *http.Request) {
		gotKey = r.URL.Query().Get("apiKey")
		gotCT = r.Header.Get("Content-Type")
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &gotBody)
		w.Header().Set("Content-Type", "image/png")
		w.Write([]byte("\x89PNG fake"))
	})
	req := staticMapRequest{Style: "osm-bright", Width: 10, Height: 10, Format: "png",
		Markers: []staticMarker{{Lat: 1, Lon: 2, Text: "1"}}}
	img, err := fetchStaticMap("k3y", req)
	if err != nil {
		t.Fatalf("fetchStaticMap: %v", err)
	}
	if string(img) != "\x89PNG fake" || gotKey != "k3y" || gotCT != "application/json" {
		t.Errorf("img=%q key=%q ct=%q", img, gotKey, gotCT)
	}
	if len(gotBody.Markers) != 1 || gotBody.Markers[0].Lat != 1 {
		t.Errorf("body not sent as JSON: %+v", gotBody)
	}
}

func TestFetchStaticMapErrorIsReadable(t *testing.T) {
	withGeoapify(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(401)
		w.Write([]byte(`{"statusCode":401,"message":"Invalid apiKey"}`))
	})
	_, err := fetchStaticMap("k3y", staticMapRequest{})
	if err == nil || !strings.Contains(err.Error(), "Invalid apiKey") {
		t.Fatalf("want the API's message surfaced, got %v", err)
	}
	if strings.Contains(err.Error(), "k3y") {
		t.Errorf("error leaks the key: %v", err)
	}
}

func TestGeocodeAddressSendsTextAndParses(t *testing.T) {
	var gotText string
	withGeoapify(t, func(w http.ResponseWriter, r *http.Request) {
		gotText = r.URL.Query().Get("text")
		w.Write([]byte(`{"results":[{"lat":42.6958,"lon":23.3329,"formatted":"Nevsky, Sofia"}]}`))
	})
	r, err := geocodeAddress("k3y", "Alexander Nevsky, Sofia")
	if err != nil {
		t.Fatalf("geocodeAddress: %v", err)
	}
	if gotText != "Alexander Nevsky, Sofia" || r.Lat != 42.6958 {
		t.Errorf("text=%q result=%+v", gotText, r)
	}
}

func TestRedactKeyHidesTheKeyInURLErrors(t *testing.T) {
	err := redactKey(io.ErrUnexpectedEOF, "")
	if err != io.ErrUnexpectedEOF {
		t.Errorf("empty key should pass the error through")
	}
	e := redactKey(errString(`Post "https://maps.geoapify.com/v1/staticmap?apiKey=abc123": timeout`), "abc123")
	if strings.Contains(e.Error(), "abc123") || !strings.Contains(e.Error(), "REDACTED") {
		t.Errorf("key not redacted: %v", e)
	}
}

type errString string

func (e errString) Error() string { return string(e) }

func TestGeocodeItemsSkipsVaultWhenNothingToGeocode(t *testing.T) {
	items := []mapItem{{Kind: kindPoint, Points: []mapPoint{{Lat: 1, Lon: 2}}}}
	key := ""
	if err := geocodeItems(items, &key); err != nil {
		t.Fatalf("no addresses should mean no Vault read and no error: %v", err)
	}
	if key != "" {
		t.Errorf("key fetched unnecessarily")
	}
}
