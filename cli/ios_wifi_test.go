package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The transport decision is the part that silently picks the wrong path, so it
// is a pure function and tested on its own.
func TestIosShotTransport(t *testing.T) {
	ready := &iosWifiStatus{Connected: true}
	ready.WDA.Ready = true
	noWDA := &iosWifiStatus{Connected: true}
	down := &iosWifiStatus{Connected: false}

	cases := []struct {
		name string
		st   *iosWifiStatus
		tap  string
		want string
	}{
		{"service not running", nil, "", "mac"},
		{"phone not connected", down, "", "mac"},
		{"plain screenshot over wifi", noWDA, "", "wifi"},
		{"tap needs WDA, which is up", ready, "10,20", "wifi"},
		{"tap needs WDA, which is down", noWDA, "10,20", "mac"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := iosShotTransport(tc.st, tc.tap); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestIosWifiStatusDecodesTheServiceReply(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/status" {
			http.NotFound(w, r)
			return
		}
		json.NewEncoder(w).Encode(map[string]interface{}{
			"connected": true, "ios": "26.5.2", "product_type": "iPhone14,2", "pairing_port": 49152,
			"battery": map[string]interface{}{"percent": 100, "charging": false, "external_power": true, "fully_charged": true},
			"wda":     map[string]interface{}{"ready": false, "url": nil, "error": "WDA would not launch"},
		})
	}))
	defer srv.Close()

	st, err := iosWifiGetStatus(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	if !st.Connected || st.IOS != "26.5.2" || st.PairingPort != 49152 {
		t.Errorf("unexpected status %+v", st)
	}
	if st.Battery == nil || !st.Battery.ExternalPower || st.Battery.Percent != 100 {
		t.Errorf("battery not decoded: %+v", st.Battery)
	}
	if st.WDA.Ready || !strings.Contains(st.WDA.Error, "would not launch") {
		t.Errorf("wda not decoded: %+v", st.WDA)
	}
}

func TestIosWifiStatusReportsAServiceThatIsNotRunning(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close()
	if _, err := iosWifiGetStatus(url); err == nil {
		t.Error("expected an error from a closed port")
	}
}

// A service error must reach the caller as the service's own words, since
// those name the fix (toggle Web Inspector, re-sign WDA, ...).
func TestIosWifiPostSurfacesTheServiceDetail(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"detail": "WebInspectorNotEnabledError: "})
	}))
	defer srv.Close()
	_, err := iosWifiPost(srv.URL, "/safari", map[string]string{"url": "https://example.com"})
	if err == nil || !strings.Contains(err.Error(), "WebInspectorNotEnabled") {
		t.Errorf("want the service detail in the error, got %v", err)
	}
}

func TestIosWifiScriptIsWrittenFromTheEmbed(t *testing.T) {
	dir := t.TempDir()
	path, err := iosWriteWifiScript(dir)
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want, _ := iosAssets.ReadFile("ios_assets/wifi/ios_rig_wifi.py")
	if string(got) != string(want) || filepath.Dir(path) != dir {
		t.Errorf("script at %s does not match the embedded copy", path)
	}
}
