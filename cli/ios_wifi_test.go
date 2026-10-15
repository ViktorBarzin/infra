package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

// A rebuilt devvm has no pairing, and pairing again needs the Mac and the
// phone on a cable. Restoring from Vault must fill only what is missing, at
// mode 600, and never overwrite a record that is there.
func TestIosRestorePairRecords(t *testing.T) {
	dir := t.TempDir()
	udid := "00008110-TEST"
	existing := filepath.Join(dir, udid+".plist")
	if err := os.WriteFile(existing, []byte("keep me"), 0o600); err != nil {
		t.Fatal(err)
	}
	fetch := func(field string) (string, error) {
		return map[string]string{
			"remote_pair_record":   "cmVtb3Rl",    // "remote"
			"lockdown_pair_record": "bG9ja2Rvd24", // "lockdown", unpadded
		}[field], nil
	}
	wrote, err := iosRestorePairRecords(dir, udid, fetch)
	if err != nil {
		t.Fatal(err)
	}
	if len(wrote) != 1 || filepath.Base(wrote[0]) != "remote_"+udid+".plist" {
		t.Errorf("wrote %v, want only the missing remote record", wrote)
	}
	if b, _ := os.ReadFile(existing); string(b) != "keep me" {
		t.Errorf("existing record was overwritten: %q", b)
	}
	fi, err := os.Stat(filepath.Join(dir, "remote_"+udid+".plist"))
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("mode %v, want 0600", fi.Mode().Perm())
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "remote_"+udid+".plist")); string(b) != "remote" {
		t.Errorf("decoded %q, want %q", b, "remote")
	}
}

// Safari's Remote Automation session ends any running XCTest session, so with
// WDA up `shot --url` must open the page through WDA instead (measured
// 2026-10-12: WDA survived screenshot, launch and apps, and died after one
// /safari call).
func TestIosWDAOpenURLNamesSafari(t *testing.T) {
	var gotBody map[string]interface{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/session" && r.Method == http.MethodPost:
			json.NewEncoder(w).Encode(map[string]interface{}{"sessionId": "S1", "value": map[string]interface{}{"sessionId": "S1"}})
		case r.URL.Path == "/session/S1/url":
			json.NewDecoder(r.Body).Decode(&gotBody)
			json.NewEncoder(w).Encode(map[string]interface{}{"value": nil})
		case r.URL.Path == "/wda/activeAppInfo":
			json.NewEncoder(w).Encode(map[string]interface{}{"value": map[string]interface{}{"bundleId": "com.apple.mobilesafari"}})
		default:
			json.NewEncoder(w).Encode(map[string]interface{}{"value": nil})
		}
	}))
	defer srv.Close()
	if err := iosWDAOpenURL(srv.URL, "https://example.com"); err != nil {
		t.Fatal(err)
	}
	if gotBody["url"] != "https://example.com" || gotBody["bundleId"] != "com.apple.mobilesafari" {
		t.Errorf("WDA got %v; the phone's default browser is not Safari, so bundleId must be explicit", gotBody)
	}
}

// The devvm renews WDA's 7-day profile itself; doctor warns before taps lapse.
func TestIosSignatureCheck(t *testing.T) {
	now := time.Date(2026, 10, 15, 0, 0, 0, 0, time.UTC)
	at := func(d time.Duration) string { return now.Add(d).Format(time.RFC3339) }
	cases := []struct {
		name, expires, err string
		level              int
		want               string
	}{
		{"never signed", "", "", 1, "not signed on the devvm yet"},
		{"fresh", at(6 * 24 * time.Hour), "", 0, "valid until 2026-10-21"},
		{"last day", at(20 * time.Hour), "", 1, "valid until 2026-10-15"},
		{"lapsed", at(-time.Hour), "", 1, "lapsed"},
		{"renewal failing", at(4 * 24 * time.Hour), "wdasign failed: login", 1, "wdasign failed: login"},
	}
	for _, c := range cases {
		level, detail := iosSignatureCheck(c.expires, c.err, now)
		if level != c.level || !strings.Contains(detail, c.want) {
			t.Errorf("%s: got (%d, %q), want level %d containing %q", c.name, level, detail, c.level, c.want)
		}
	}
}
