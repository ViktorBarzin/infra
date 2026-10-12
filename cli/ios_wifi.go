package main

// The Wi-Fi side of the iOS rig: the phone driven from this box with no Mac in
// the loop. ios_assets/wifi/ios_rig_wifi.py holds the RemotePairing tunnel and
// serves a loopback HTTP API (ios-rig-wifi.service runs it via `ios wifi-fg`);
// this file is the client and the verbs that only exist on this path.
//
// What needs no Mac: screenshots, Safari, launching apps, installing a signed
// .ipa, location simulation, and WebDriverAgent taps while WDA's 7-day
// free-team signature is valid. What still needs the Mac: building apps and
// re-signing WDA. Runbook: docs/runbooks/ios-test-rig.md.

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func iosWifiURL() string { return envOr("IOS_RIG_WIFI_URL", "http://127.0.0.1:8102") }

type iosWifiStatus struct {
	Connected   bool   `json:"connected"`
	Error       string `json:"error"`
	Host        string `json:"host"`
	IOS         string `json:"ios"`
	ProductType string `json:"product_type"`
	PairingPort int    `json:"pairing_port"`
	Battery     *struct {
		Percent       int  `json:"percent"`
		Charging      bool `json:"charging"`
		ExternalPower bool `json:"external_power"`
		FullyCharged  bool `json:"fully_charged"`
	} `json:"battery"`
	BatteryError string `json:"battery_error"`
	WDA          struct {
		Ready bool   `json:"ready"`
		URL   string `json:"url"`
		Error string `json:"error"`
	} `json:"wda"`
}

// iosShotTransport picks the path for `ios shot`. Wi-Fi whenever the phone is
// connected, except that a tap needs WebDriverAgent, so a tap with WDA down
// goes to the Mac, which can re-sign and restart it.
func iosShotTransport(st *iosWifiStatus, tap string) string {
	if st == nil || !st.Connected {
		return "mac"
	}
	if tap != "" && !st.WDA.Ready {
		return "mac"
	}
	return "wifi"
}

func iosWifiGetStatus(base string) (*iosWifiStatus, error) {
	resp, err := (&http.Client{Timeout: 90 * time.Second}).Get(base + "/status")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("ios-rig-wifi /status: HTTP %d", resp.StatusCode)
	}
	var st iosWifiStatus
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		return nil, err
	}
	return &st, nil
}

// iosWifiStatusOrNil is the "is the Wi-Fi path usable" probe the verbs share.
func iosWifiStatusOrNil() *iosWifiStatus {
	st, err := iosWifiGetStatus(iosWifiURL())
	if err != nil {
		return nil
	}
	return st
}

func iosWifiDo(method, url, contentType string, body io.Reader, timeout time.Duration) ([]byte, error) {
	req, err := http.NewRequest(method, url, body)
	if err != nil {
		return nil, err
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := (&http.Client{Timeout: timeout}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		var e struct {
			Detail string `json:"detail"`
		}
		if json.Unmarshal(raw, &e) == nil && e.Detail != "" {
			return nil, fmt.Errorf("%s", e.Detail)
		}
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return raw, nil
}

func iosWifiPost(base, path string, body interface{}) (map[string]interface{}, error) {
	buf, _ := json.Marshal(body)
	raw, err := iosWifiDo(http.MethodPost, base+path, "application/json", bytes.NewReader(buf), 5*time.Minute)
	if err != nil {
		return nil, err
	}
	var out map[string]interface{}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func iosWifiScreenshot(base, out string) error {
	raw, err := iosWifiDo(http.MethodGet, base+"/screenshot", "", nil, 2*time.Minute)
	if err != nil {
		return err
	}
	if err := os.WriteFile(out, raw, 0o644); err != nil {
		return err
	}
	fmt.Printf("%s (%d bytes, over Wi-Fi)\n", out, len(raw))
	return nil
}

// iosWifiShot is `ios shot` without the Mac.
func iosWifiShot(st *iosWifiStatus, out, url, tap, bundle string) error {
	base := iosWifiURL()
	if bundle != "" {
		if _, err := iosWifiPost(base, "/launch", map[string]interface{}{"bundle_id": bundle}); err != nil {
			return err
		}
		time.Sleep(2 * time.Second) // launch returns at exec, not at first frame
	}
	if url != "" {
		// Safari's Remote Automation ends WDA's XCTest session, so with WDA up
		// the page is opened through WDA and taps keep working afterwards.
		if st.WDA.Ready {
			if err := iosWDAOpenURL(st.WDA.URL, url); err != nil {
				return err
			}
		} else {
			r, err := iosWifiPost(base, "/safari", map[string]interface{}{"url": url})
			if err != nil {
				return fmt.Errorf("Safari over Wi-Fi: %w", err)
			}
			fmt.Fprintf(os.Stderr, "safari: %v\n", r["title"])
		}
	}
	if tap != "" {
		x, y, err := parseXY(tap)
		if err != nil {
			return err
		}
		if err := iosWDATap(st.WDA.URL, x, y); err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "tapped %d,%d\n", x, y)
		time.Sleep(800 * time.Millisecond)
	}
	return iosWifiScreenshot(base, out)
}

// iosWDASession opens a WebDriverAgent session and returns its id and a
// function that closes it.
func iosWDASession(wda string) (string, func(), error) {
	resp, err := postJSON(wda+"/session", map[string]interface{}{"capabilities": map[string]interface{}{}}, time.Minute)
	if err != nil {
		return "", nil, err
	}
	sid, _ := resp["sessionId"].(string)
	if sid == "" {
		if v, ok := resp["value"].(map[string]interface{}); ok {
			sid, _ = v["sessionId"].(string)
		}
	}
	if sid == "" {
		return "", nil, fmt.Errorf("WebDriverAgent returned no session id")
	}
	return sid, func() { doJSON(http.MethodDelete, wda+"/session/"+sid, nil, 30*time.Second) }, nil
}

// iosWDAOpenURL opens url in Safari through WebDriverAgent and waits for
// Safari to be frontmost. The bundle id is explicit because the phone's
// default browser is Chrome.
func iosWDAOpenURL(wda, url string) error {
	sid, done, err := iosWDASession(wda)
	if err != nil {
		return err
	}
	defer done()
	if _, err := postJSON(wda+"/session/"+sid+"/url",
		map[string]interface{}{"url": url, "bundleId": "com.apple.mobilesafari"}, 2*time.Minute); err != nil {
		return err
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if r, err := getJSON(wda+"/wda/activeAppInfo", 20*time.Second); err == nil {
			if v, ok := r["value"].(map[string]interface{}); ok && v["bundleId"] == "com.apple.mobilesafari" {
				// Frontmost is not the same as finished animating or loading.
				time.Sleep(2 * time.Second)
				fmt.Fprintf(os.Stderr, "safari: opened %s via WebDriverAgent\n", url)
				return nil
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("Safari never came to the front after opening %s", url)
}

// iosWDATap speaks W3C WebDriver straight to WebDriverAgent on the phone. No
// Appium: WDA implements sessions and pointer actions itself.
func iosWDATap(wda string, x, y int) error {
	sid, done, err := iosWDASession(wda)
	if err != nil {
		return err
	}
	defer done()
	_, err = postJSON(wda+"/session/"+sid+"/actions", map[string]interface{}{
		"actions": []interface{}{map[string]interface{}{
			"type": "pointer", "id": "finger1",
			"parameters": map[string]interface{}{"pointerType": "touch"},
			"actions": []interface{}{
				map[string]interface{}{"type": "pointerMove", "duration": 0, "x": x, "y": y},
				map[string]interface{}{"type": "pointerDown", "button": 0},
				map[string]interface{}{"type": "pause", "duration": 120},
				map[string]interface{}{"type": "pointerUp", "button": 0},
			},
		}},
	}, time.Minute)
	return err
}

// --- verbs that exist only on the Wi-Fi path ------------------------------------

func iosNeedWifi() (*iosWifiStatus, error) {
	st, err := iosWifiGetStatus(iosWifiURL())
	if err != nil {
		return nil, fmt.Errorf("the Wi-Fi service is not answering on %s (%v); "+
			"`systemctl --user status ios-rig-wifi`, repair with `homelab ios bootstrap --units-only`", iosWifiURL(), err)
	}
	if !st.Connected {
		return nil, fmt.Errorf("the phone is not reachable over Wi-Fi: %s", st.Error)
	}
	return st, nil
}

func iosSafari(args []string) error {
	if iosHelpWanted(args) || len(args) == 0 {
		fmt.Print(iosHelp())
		if len(args) == 0 {
			return fmt.Errorf("ios safari needs a URL")
		}
		return nil
	}
	body := map[string]interface{}{"url": args[0]}
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--js":
			if i+1 < len(args) {
				body["script"] = args[i+1]
				i++
			}
		case "--settle":
			if i+1 < len(args) {
				s, err := strconv.ParseFloat(args[i+1], 64)
				if err != nil {
					return fmt.Errorf("--settle wants seconds, got %q", args[i+1])
				}
				body["settle"] = s
				i++
			}
		default:
			return fmt.Errorf("unknown flag %q", args[i])
		}
	}
	if _, err := iosNeedWifi(); err != nil {
		return err
	}
	r, err := iosWifiPost(iosWifiURL(), "/safari", body)
	if err != nil {
		return err
	}
	out, _ := json.MarshalIndent(r, "", "  ")
	fmt.Println(string(out))
	return nil
}

func iosLaunch(args []string) error {
	if iosHelpWanted(args) || len(args) == 0 {
		fmt.Print(iosHelp())
		if len(args) == 0 {
			return fmt.Errorf("ios launch needs a bundle id")
		}
		return nil
	}
	if _, err := iosNeedWifi(); err != nil {
		return err
	}
	r, err := iosWifiPost(iosWifiURL(), "/launch", map[string]interface{}{"bundle_id": args[0], "args": args[1:]})
	if err != nil {
		return err
	}
	fmt.Printf("%s launched, pid %v\n", args[0], r["pid"])
	return nil
}

func iosLocation(args []string) error {
	if iosHelpWanted(args) || len(args) != 1 {
		fmt.Print(iosHelp())
		if len(args) != 1 {
			return fmt.Errorf("ios location wants LAT,LON or clear")
		}
		return nil
	}
	body := map[string]interface{}{}
	if args[0] != "clear" {
		parts := strings.SplitN(args[0], ",", 2)
		if len(parts) != 2 {
			return fmt.Errorf("ios location wants LAT,LON, got %q", args[0])
		}
		lat, err1 := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64)
		lon, err2 := strconv.ParseFloat(strings.TrimSpace(parts[1]), 64)
		if err1 != nil || err2 != nil {
			return fmt.Errorf("ios location wants two numbers, got %q", args[0])
		}
		body["lat"], body["lon"] = lat, lon
	}
	if _, err := iosNeedWifi(); err != nil {
		return err
	}
	if _, err := iosWifiPost(iosWifiURL(), "/location", body); err != nil {
		return err
	}
	if args[0] == "clear" {
		fmt.Println("location simulation cleared")
	} else {
		fmt.Printf("location simulated at %s\n", args[0])
	}
	return nil
}

func iosWifiApps(st *iosWifiStatus) error {
	raw, err := iosWifiDo(http.MethodGet, iosWifiURL()+"/apps", "", nil, 2*time.Minute)
	if err != nil {
		return err
	}
	var apps map[string]struct {
		Name    string `json:"name"`
		Version string `json:"version"`
	}
	if err := json.Unmarshal(raw, &apps); err != nil {
		return err
	}
	fmt.Printf("%d user apps on %s (iOS %s), over Wi-Fi:\n", len(apps), st.ProductType, st.IOS)
	for b, a := range apps {
		fmt.Printf("  %-45s %s %s\n", b, a.Name, a.Version)
	}
	return nil
}

func iosWifiInstall(ipa string) error {
	if _, err := iosNeedWifi(); err != nil {
		return err
	}
	f, err := os.Open(ipa)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := iosWifiDo(http.MethodPost, iosWifiURL()+"/install", "application/octet-stream", f, 10*time.Minute); err != nil {
		return err
	}
	fmt.Printf("%s installed over Wi-Fi\n", ipa)
	return nil
}

// iosWifiChecks are doctor's view of the Wi-Fi path. connected reports whether
// the phone answered, which decides how hard a missing Mac counts.
func iosWifiChecks(add func(level int, name, detail string)) (connected bool) {
	st, err := iosWifiGetStatus(iosWifiURL())
	if err != nil {
		add(2, "wifi-service", fmt.Sprintf("not answering on %s; `systemctl --user status ios-rig-wifi`, "+
			"repair with `homelab ios bootstrap --units-only`", iosWifiURL()))
		return false
	}
	add(0, "wifi-service", iosWifiURL())
	if !st.Connected {
		add(2, "phone-wifi", "no tunnel to "+st.Host+": "+st.Error)
		return false
	}
	add(0, "phone-wifi", fmt.Sprintf("%s, %s iOS %s, pairing port %d", st.Host, st.ProductType, st.IOS, st.PairingPort))
	switch {
	case st.Battery == nil:
		add(1, "power", "battery unreadable: "+st.BatteryError)
	case st.Battery.ExternalPower:
		add(0, "power", fmt.Sprintf("on the charger, %d%%", st.Battery.Percent))
	default:
		add(1, "power", fmt.Sprintf("on battery, %d%%; the rig expects the phone on a charger", st.Battery.Percent))
	}
	if st.WDA.Ready {
		add(0, "wda-wifi", st.WDA.URL+" (taps work without the Mac)")
	} else {
		detail := "not running; screenshots, Safari, launch and installs still work, taps do not"
		if st.WDA.Error != "" {
			detail += ". " + st.WDA.Error
		}
		add(1, "wda-wifi", detail)
	}
	return true
}

// iosWriteWifiScript puts the embedded service where the venv can run it.
// Rewritten on every start so the service always matches this binary.
func iosWriteWifiScript(dir string) (string, error) {
	body, err := iosAssets.ReadFile("ios_assets/wifi/ios_rig_wifi.py")
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(dir, "ios_rig_wifi.py")
	return path, os.WriteFile(path, body, 0o644)
}

// iosWifiFg runs the Wi-Fi service in the foreground for ios-rig-wifi.service.
// The Python lives in a venv the devvm playbook builds (pymobiledevice3 needs
// Python 3.13+ for the tunnel's TLS-PSK).
func iosWifiFg(args []string) error {
	if iosHelpWanted(args) {
		fmt.Print(iosHelp())
		return nil
	}
	if len(args) > 0 {
		return fmt.Errorf("unknown flag %q", args[0])
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	script, err := iosWriteWifiScript(filepath.Join(home, ".local", "share", "ios-rig"))
	if err != nil {
		return err
	}
	python := envOr("IOS_RIG_PYTHON", "/opt/ios-rig/venv/bin/python")
	if _, err := os.Stat(python); err != nil {
		return fmt.Errorf("%s is missing; the devvm playbook installs it (infra playbooks/devvm.yml, ios-rig venv)", python)
	}
	// exec, so systemd supervises the service process itself.
	return syscall.Exec(python, []string{python, "-I", script}, os.Environ())
}

// iosRestorePairRecords writes any missing pairing record from Vault
// (secret/ios-rig, base64 values). Pairing again would need the Mac and the
// phone on a cable, so a rebuilt devvm restores instead. Existing files win.
func iosRestorePairRecords(dir, udid string, fetch func(field string) (string, error)) ([]string, error) {
	var wrote []string
	for _, r := range []struct{ file, field string }{
		{"remote_" + udid + ".plist", "remote_pair_record"},
		{udid + ".plist", "lockdown_pair_record"},
	} {
		path := filepath.Join(dir, r.file)
		if _, err := os.Stat(path); err == nil {
			continue
		}
		b64, err := fetch(r.field)
		if err != nil {
			return wrote, fmt.Errorf("reading %s from Vault: %w", r.field, err)
		}
		raw, err := base64.RawStdEncoding.DecodeString(strings.TrimRight(strings.TrimSpace(b64), "="))
		if err != nil {
			return wrote, fmt.Errorf("%s is not base64: %w", r.field, err)
		}
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return wrote, err
		}
		if err := os.WriteFile(path, raw, 0o600); err != nil {
			return wrote, err
		}
		wrote = append(wrote, path)
	}
	return wrote, nil
}

func iosVaultField(field string) (string, error) {
	out, err := exec.Command("vault", vaultKVGetFieldArgs("secret/ios-rig", field)...).Output()
	return string(out), err
}
