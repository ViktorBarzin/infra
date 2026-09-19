package main

import (
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
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
	// SSHPort, MacSubnet and MacHWAddr exist only for finding the Mac again
	// after its Wi-Fi address rotates. See the discovery section below.
	SSHPort   string
	MacSubnet string
	MacHWAddr string
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
		SSHPort:      envOr("IOS_RIG_SSH_PORT", "22"),
		MacSubnet:    envOr("IOS_RIG_MAC_SUBNET", "192.168.8.0/24"),
		// The hardware address, not whatever private address the card is
		// presenting today. This is the one identifier the rotation cannot
		// change, which is what makes discovery trustworthy.
		MacHWAddr: envOr("IOS_RIG_MAC_HW_ADDR", "84:2f:57:39:9a:d9"),
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

// Finding the Mac when its address moves.
//
// The Mac is addressed by name through a Technitium record backed by a Flint
// reservation. Both key on the Wi-Fi address, and macOS rotates the private
// one: twice in the seven days after the rig was built, each time leaving the
// name pointing at an address with nothing behind it. The symptom is the whole
// rig looking absent, which is indistinguishable by eye from the laptop having
// left the building.
//
// The hardware address does not rotate. So when the name stops answering, the
// rig sweeps the LAN for SSH and asks each candidate for its hardware address,
// which is the one identity the rotation cannot change. This mirrors how
// wdaURL already heals the phone's address when its DHCP lease moves.

// iosHardwareAddr pulls the MAC out of `networksetup -getmacaddress`, whose
// output is "Ethernet Address: 84:2f:57:39:9a:d9 (Device: en0)". Compared
// lowercase, because the two sides of the comparison come from different
// commands and only one of them is consistent about case.
func iosHardwareAddr(out string) string {
	m := macAddrRe.FindString(oscRe.ReplaceAllString(out, ""))
	return strings.ToLower(m)
}

var macAddrRe = regexp.MustCompile(`(?i)\b[0-9a-f]{2}(?::[0-9a-f]{2}){5}\b`)

// iosMaxScanHosts caps a sweep. A wrong prefix should be an error rather than
// an hour of traffic, and no home LAN the rig lives on is larger than a /22.
const iosMaxScanHosts = 1024

// iosSubnetHosts enumerates the usable addresses in a CIDR, skipping the
// network and broadcast addresses except on a /32, which is how someone pins
// discovery to a single host.
func iosSubnetHosts(cidr string) ([]string, error) {
	_, network, err := net.ParseCIDR(cidr)
	if err != nil {
		return nil, fmt.Errorf("%q is not a CIDR: %w", cidr, err)
	}
	if network.IP.To4() == nil {
		return nil, fmt.Errorf("%q is not IPv4; the rig's LAN is v4 only", cidr)
	}
	ones, bits := network.Mask.Size()
	if n := 1 << uint(bits-ones); n > iosMaxScanHosts {
		return nil, fmt.Errorf("%q covers %d addresses, more than the %d cap; narrow it", cidr, n, iosMaxScanHosts)
	}
	var hosts []string
	for ip := network.IP.Mask(network.Mask).To4(); network.Contains(ip); ip = nextIPv4(ip) {
		hosts = append(hosts, ip.String())
	}
	if ones == bits {
		return hosts, nil
	}
	if len(hosts) < 3 {
		return nil, fmt.Errorf("%q has no usable host addresses", cidr)
	}
	return hosts[1 : len(hosts)-1], nil
}

func nextIPv4(ip net.IP) net.IP {
	out := make(net.IP, len(ip))
	copy(out, ip)
	for i := len(out) - 1; i >= 0; i-- {
		out[i]++
		if out[i] != 0 {
			break
		}
	}
	return out
}

// iosScanPort returns the hosts answering on port, probed concurrently. A
// closed or filtered port is not an error here, it is the common case, so
// everything that is not a completed handshake is simply left out.
func iosScanPort(hosts []string, port string, timeout time.Duration) []string {
	type result struct {
		i    int
		host string
	}
	ch := make(chan result, len(hosts))
	sem := make(chan struct{}, 64)
	var wg sync.WaitGroup
	for i, h := range hosts {
		wg.Add(1)
		go func(i int, h string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			conn, err := net.DialTimeout("tcp", net.JoinHostPort(h, port), timeout)
			if err != nil {
				return
			}
			conn.Close()
			ch <- result{i, h}
		}(i, h)
	}
	wg.Wait()
	close(ch)
	var found []result
	for r := range ch {
		found = append(found, r)
	}
	// Stable order, so a rescan of an unchanged LAN picks the same host and
	// the logs do not shuffle for no reason.
	sort.Slice(found, func(a, b int) bool { return found[a].i < found[b].i })
	out := make([]string, 0, len(found))
	for _, r := range found {
		out = append(out, r.host)
	}
	return out
}

// iosDiscoverMac sweeps the configured subnet for a host that answers SSH as
// our user AND reports the expected hardware address. The address check is
// what makes this safe to run unattended: an open port 22 on the LAN is not
// enough to start driving a machine.
func (c iosConfig) iosDiscoverMac() (string, error) {
	if c.MacHWAddr == "" {
		return "", fmt.Errorf("no hardware address configured, so a discovered host cannot be identified; set IOS_RIG_MAC_HW_ADDR")
	}
	hosts, err := iosSubnetHosts(c.MacSubnet)
	if err != nil {
		return "", err
	}
	candidates := iosScanPort(hosts, c.SSHPort, 2*time.Second)
	want := strings.ToLower(c.MacHWAddr)
	for _, h := range candidates {
		probe := c
		probe.MacHost = h
		out, err := probe.onMac("networksetup -getmacaddress en0")
		if err != nil {
			continue
		}
		if iosHardwareAddr(out) == want {
			return h, nil
		}
	}
	return "", fmt.Errorf("no host on %s answered SSH as %s with hardware address %s (%d had port %s open)",
		c.MacSubnet, c.MacUser, want, len(candidates), c.SSHPort)
}

// resolveMacHost returns an address that actually answers. The configured name
// is always tried first and discovery only runs when it does not, so the
// normal path costs one TCP handshake and the scan stays a fallback. discover
// is injected so the preference can be tested without a LAN.
func (c iosConfig) resolveMacHost(discover func() (string, error)) (string, error) {
	if hostAnswers(c.MacHost, c.SSHPort, 3*time.Second) {
		return c.MacHost, nil
	}
	if cached := strings.TrimSpace(readFileString(iosMacHostCachePath())); cached != "" && cached != c.MacHost {
		if hostAnswers(cached, c.SSHPort, 3*time.Second) {
			return cached, nil
		}
	}
	marker := iosFailureMarkerPath()
	if !iosShouldSweep(iosReadFailureMarker(marker), time.Now(), iosDiscoveryCooldown()) {
		return "", fmt.Errorf("%s does not answer and a sweep of %s failed less than %s ago, "+
			"so this one is skipped; the Mac is away or on another network",
			c.MacHost, c.MacSubnet, iosDiscoveryCooldown())
	}

	found, err := discover()
	if err != nil {
		iosWriteFailureMarker(marker, time.Now())
		return "", err
	}
	if found == "" {
		return "", fmt.Errorf("%s does not answer on port %s and no replacement was found", c.MacHost, c.SSHPort)
	}
	// Cache it so the next command skips the sweep. It is only ever a hint:
	// every read re-checks that it still answers.
	iosClearFailureMarker(marker)
	_ = os.WriteFile(iosMacHostCachePath(), []byte(found+"\n"), 0o644)
	fmt.Fprintf(os.Stderr, "%s did not answer; using %s, found by hardware address\n", c.MacHost, found)
	return found, nil
}

func hostAnswers(host, port string, timeout time.Duration) bool {
	if host == "" {
		return false
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), timeout)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func iosMacHostCachePath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".ios-rig-mac-host"
	}
	return filepath.Join(home, ".ios-rig-mac-host")
}

func readFileString(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

// A sweep is the expensive half of discovery, and a Mac that is away stays
// away for hours. Left ungated the tunnel unit ran 137 sweeps in the hour
// after the laptop left on 2026-09-19, roughly 35,000 connection attempts
// into the LAN for a machine that was never going to answer, which is both
// wasteful and indistinguishable from someone scanning the network.
//
// The cooldown suppresses only the sweep. resolveMacHost still probes the
// configured name and the cached address on every call, and those are one
// handshake each, so a Mac returning to either address is picked up
// immediately. Only a Mac returning to a THIRD address waits, and that case
// is rare enough to trade for the quiet.
func iosDiscoveryCooldown() time.Duration {
	if v := os.Getenv("IOS_RIG_DISCOVERY_COOLDOWN"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return 5 * time.Minute
}

// iosShouldSweep is separated from the file handling so the window logic can
// be tested without a clock or a disk. A marker in the future means the clock
// moved backwards; sweeping is the safe reading, since the alternative is
// discovery disabled until the marker's time arrives.
func iosShouldSweep(lastFailure, now time.Time, cooldown time.Duration) bool {
	if lastFailure.IsZero() || lastFailure.After(now) {
		return true
	}
	return now.Sub(lastFailure) >= cooldown
}

func iosFailureMarkerPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".ios-rig-discovery-failed"
	}
	return filepath.Join(home, ".ios-rig-discovery-failed")
}

// An unreadable or unparseable marker reads as zero, which sweeps. Failing
// towards the working behaviour matters more here than saving one scan.
func iosReadFailureMarker(path string) time.Time {
	b, err := os.ReadFile(path)
	if err != nil {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(string(b)))
	if err != nil {
		return time.Time{}
	}
	return t
}

func iosWriteFailureMarker(path string, when time.Time) {
	_ = os.WriteFile(path, []byte(when.Format(time.RFC3339)+"\n"), 0o644)
}

func iosClearFailureMarker(path string) { _ = os.Remove(path) }

// iosResolved is what every verb that talks to the Mac starts from: defaults,
// with MacHost pointed at something that answers.
func iosResolved() (iosConfig, error) {
	c := iosDefaults()
	host, err := c.resolveMacHost(c.iosDiscoverMac)
	if err != nil {
		return c, err
	}
	c.MacHost = host
	return c, nil
}
