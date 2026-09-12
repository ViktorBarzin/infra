package main

import (
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// The iOS test rig: a personal iPhone cabled to the London MacBook, driven
// from here. This file owns the devvm side. The Mac side stays as shell and
// plists because it has to run under launchd, and it is embedded here so
// `homelab ios bootstrap` works without a checkout of infra.
//
// Architecture and every measured constraint: docs/runbooks/ios-test-rig.md.

//go:embed ios_assets/build-install.sh ios_assets/resign-wda.sh ios_assets/run-wda.sh
//go:embed ios_assets/launchagents/*.tmpl
//go:embed ios_assets/ios-rig-tunnel.service ios_assets/ios-rig-doctor.service ios_assets/ios-rig-doctor.timer
//go:embed ios_assets/testapp/project.yml ios_assets/testapp/Sources/RigTestApp.swift
var iosAssets embed.FS

// iosConfig is everything that differs between rigs. Defaults describe the one
// rig that exists; every field is overridable so a second phone or a rebuilt
// Mac needs no code change.
type iosConfig struct {
	MacHost      string
	MacUser      string
	UDID         string
	TeamID       string
	WDABundleID  string
	DeveloperDir string
	AppiumPort   string
}

func iosDefaults() iosConfig {
	return iosConfig{
		MacHost: envOr("IOS_RIG_MAC_HOST", "mbp-london.viktorbarzin.lan"),
		MacUser: envOr("IOS_RIG_MAC_USER", "viktorbarzin"),
		UDID:    envOr("IOS_RIG_UDID", "00008110-001614D03442801E"),
		TeamID:  envOr("IOS_RIG_TEAM_ID", "26NB4W97WL"),
		// The .xctrunner suffix is appended by Xcode, so the installed bundle
		// is me.viktorbarzin.wda.xctrunner while this is what we sign as.
		WDABundleID:  envOr("IOS_RIG_WDA_BUNDLE_ID", "me.viktorbarzin.wda"),
		DeveloperDir: envOr("IOS_RIG_DEVELOPER_DIR", "/Applications/Xcode_26.6.0_17F113_fb.app/Contents/Developer"),
		AppiumPort:   envOr("IOS_RIG_APPIUM_PORT", "4723"),
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func (c iosConfig) target() string { return c.MacUser + "@" + c.MacHost }

// oscRe strips the OSC escape sequences the Mac's login shell emits via iTerm2
// shell integration. They are invisible in a terminal and silently break any
// anchored match on otherwise-correct output.
// A well-formed OSC ends in BEL or ST, and the terminator is REQUIRED here: an
// earlier version allowed it to be optional with a greedy [a-zA-Z=]* body, and
// on an unterminated sequence that body ate the "http" off the front of the
// payload it was supposed to be clearing. An unterminated escape is left alone
// instead, which costs nothing because every value is extracted with an
// unanchored match rather than a prefix test.
var oscRe = regexp.MustCompile("\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)|\x1b\\[[0-9;]*[A-Za-z]")

var iosSSHOpts = []string{
	"-o", "ConnectTimeout=10",
	"-o", "BatchMode=yes",
	"-o", "StrictHostKeyChecking=accept-new",
}

// onMac runs a command in a LOGIN shell on the Mac, so Homebrew and the user's
// npm prefix are on PATH, and returns its cleaned combined output.
func (c iosConfig) onMac(script string) (string, error) {
	rigPath := `export PATH="$HOME/bin:$HOME/.npm-global/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; `
	args := append(append([]string{}, iosSSHOpts...), c.target(), "bash -lc "+shellQuote(rigPath+script))
	out, err := exec.Command("ssh", args...).CombinedOutput()
	return strings.TrimSpace(oscRe.ReplaceAllString(string(out), "")), err
}

// deviceDetails is the CoreDevice view. iOS 17+ keeps two independent pairing
// records and the classic lockdown one is blocked on this phone by Stolen
// Device Protection, so everything that must work unattended reads from here.
func (c iosConfig) deviceDetails() (string, error) {
	return c.onMac(fmt.Sprintf("%s/usr/bin/devicectl device info details --device %s", c.DeveloperDir, c.UDID))
}

// phoneLocked matters more than it sounds. A locked phone can be screenshotted
// and nothing else: opening an app fails, WebDriverAgent's listener stops
// answering, and it cannot unlock a device that has a passcode.
func (c iosConfig) phoneLocked() bool {
	out, _ := c.onMac(fmt.Sprintf("%s/usr/bin/devicectl device info lockState --device %s", c.DeveloperDir, c.UDID))
	return strings.Contains(out, "passcodeRequired: true")
}

var wdaURLRe = regexp.MustCompile(`https?://[0-9A-Za-z.\-]+:\d+`)

func (c iosConfig) publishedWDAURL() string {
	out, _ := c.onMac("cat ~/.ios-rig-wda-url 2>/dev/null")
	return wdaURLRe.FindString(out)
}

func httpOK(url string, timeout time.Duration) bool {
	client := &http.Client{Timeout: timeout}
	resp, err := client.Get(url)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	return resp.StatusCode == http.StatusOK
}

// wdaURL returns a WebDriverAgent that actually answers.
//
// WDA reports its address once, at launch, and the phone holds a DHCP lease, so
// a new lease leaves it listening while the published URL points at nobody.
// Restarting the runner makes it rebind and republish. A locked phone cannot be
// healed that way, so that case returns immediately rather than burning the
// retry window on something only a human fixes.
func (c iosConfig) wdaURL() (string, error) {
	if u := c.publishedWDAURL(); u != "" && httpOK(u+"/status", 8*time.Second) {
		return u, nil
	}
	if c.phoneLocked() {
		return "", fmt.Errorf("phone is locked; WebDriverAgent cannot run until someone unlocks it. Set Auto-Lock to Never")
	}
	fmt.Fprintln(os.Stderr, "WebDriverAgent is not answering, restarting the runner")
	c.onMac("launchctl kickstart -k gui/$(id -u)/me.viktorbarzin.wda-run")
	deadline := time.Now().Add(3 * time.Minute)
	for time.Now().Before(deadline) {
		if u := c.publishedWDAURL(); u != "" && httpOK(u+"/status", 8*time.Second) {
			return u, nil
		}
		time.Sleep(5 * time.Second)
	}
	return "", fmt.Errorf("WebDriverAgent did not come up; check /tmp/wda-run.log on %s", c.MacHost)
}

// postJSON and getJSON speak the W3C WebDriver protocol to Appium directly, so
// the rig needs no Appium client library on the devvm.
func postJSON(url string, body interface{}, timeout time.Duration) (map[string]interface{}, error) {
	buf, _ := json.Marshal(body)
	return doJSON(http.MethodPost, url, bytes.NewReader(buf), timeout)
}

func getJSON(url string, timeout time.Duration) (map[string]interface{}, error) {
	return doJSON(http.MethodGet, url, nil, timeout)
}

func doJSON(method, url string, body io.Reader, timeout time.Duration) (map[string]interface{}, error) {
	req, err := http.NewRequest(method, url, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: timeout}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]interface{}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("%s %s: %s", method, url, strings.TrimSpace(string(raw)))
	}
	if resp.StatusCode >= 400 {
		return out, fmt.Errorf("%s %s: %s", method, url, jsonErrMessage(out, raw))
	}
	return out, nil
}

func jsonErrMessage(out map[string]interface{}, raw []byte) string {
	if v, ok := out["value"].(map[string]interface{}); ok {
		if m, ok := v["message"].(string); ok {
			return m
		}
	}
	return strings.TrimSpace(string(raw))
}
