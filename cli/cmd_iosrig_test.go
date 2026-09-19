package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The Mac's login shell sources iTerm2 shell integration, which emits OSC
// escapes into every command's output. They are invisible in a terminal and
// broke an anchored match on a value that was plainly there, so this is the
// regression that matters most in this file.
func TestStripOSCEscapes(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"iterm SetUserVar prefix",
			"\x1b]1337;SetUserVar=agentPasteToken=\x07http://192.168.9.205:8100",
			"http://192.168.9.205:8100"},
		// An UNTERMINATED escape is deliberately left intact rather than
		// guessed at: stripping it greedily ate the payload it was clearing.
		// wdaURLRe finds the URL inside it regardless, which is the point of
		// extracting with an unanchored match.
		{"unterminated escape left alone",
			"\x1b]1337;SetUserVar=x=http://10.0.0.1:8100",
			"\x1b]1337;SetUserVar=x=http://10.0.0.1:8100"},
		{"sgr colour codes", "\x1b[32mok\x1b[0m", "ok"},
		{"clean input untouched", "passcodeRequired: false", "passcodeRequired: false"},
		{"empty", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := oscRe.ReplaceAllString(c.in, ""); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

// WebDriverAgent prints its address once, at launch, and the phone holds a
// DHCP lease, so the URL is always read back rather than assumed.
func TestWDAURLExtraction(t *testing.T) {
	cases := []struct{ in, want string }{
		{"http://192.168.9.205:8100", "http://192.168.9.205:8100"},
		{"\x1b]1337;SetUserVar=t=\x07http://192.168.8.219:8100\n", "http://192.168.8.219:8100"},
		// The unterminated case the strip deliberately leaves alone.
		{"\x1b]1337;SetUserVar=x=http://10.0.0.1:8100", "http://10.0.0.1:8100"},
		{"ServerURLHere->http://10.1.2.3:8100<-ServerURLHere", "http://10.1.2.3:8100"},
		{"https://phone.viktorbarzin.lan:8100", "https://phone.viktorbarzin.lan:8100"},
		{"", ""},
		{"cat: no such file", ""},
	}
	for _, c := range cases {
		if got := wdaURLRe.FindString(c.in); got != c.want {
			t.Errorf("FindString(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestParseXY(t *testing.T) {
	if x, y, err := parseXY("200,400"); err != nil || x != 200 || y != 400 {
		t.Errorf("parseXY(200,400) = %d,%d,%v", x, y, err)
	}
	if x, y, err := parseXY(" 12 , 34 "); err != nil || x != 12 || y != 34 {
		t.Errorf("parseXY with spaces = %d,%d,%v", x, y, err)
	}
	for _, bad := range []string{"200", "a,b", "", "1,2,3x", "200,"} {
		if _, _, err := parseXY(bad); err == nil {
			t.Errorf("parseXY(%q) should have failed", bad)
		}
	}
}

// Every field is overridable so a second phone or a rebuilt Mac needs no code
// change; the defaults describe the one rig that exists today.
func TestConfigEnvOverrides(t *testing.T) {
	d := iosDefaults()
	if d.MacHost != "mbp-london.viktorbarzin.lan" {
		t.Errorf("default MacHost = %q", d.MacHost)
	}
	if !strings.HasPrefix(d.UDID, "00008110-") {
		t.Errorf("default UDID = %q", d.UDID)
	}
	if d.target() != "viktorbarzin@mbp-london.viktorbarzin.lan" {
		t.Errorf("target() = %q", d.target())
	}

	os.Setenv("IOS_RIG_MAC_HOST", "other.lan")
	os.Setenv("IOS_RIG_MAC_USER", "someone")
	os.Setenv("IOS_RIG_UDID", "00008130-AAAA")
	defer func() {
		os.Unsetenv("IOS_RIG_MAC_HOST")
		os.Unsetenv("IOS_RIG_MAC_USER")
		os.Unsetenv("IOS_RIG_UDID")
	}()
	o := iosDefaults()
	if o.target() != "someone@other.lan" || o.UDID != "00008130-AAAA" {
		t.Errorf("overrides not honoured: %+v", o)
	}
}

// bootstrap writes these to the Mac, so a missing one is a broken provision
// rather than a compile error.
func TestEmbeddedAssetsPresent(t *testing.T) {
	want := []string{
		"ios_assets/build-install.sh",
		"ios_assets/resign-wda.sh",
		"ios_assets/run-wda.sh",
		"ios_assets/ios-rig-tunnel.service",
		"ios_assets/ios-rig-doctor.service",
		"ios_assets/ios-rig-doctor.timer",
		"ios_assets/testapp/project.yml",
		"ios_assets/testapp/Sources/RigTestApp.swift",
	}
	for _, f := range want {
		b, err := iosAssets.ReadFile(f)
		if err != nil {
			t.Errorf("missing embedded asset %s: %v", f, err)
			continue
		}
		if len(b) == 0 {
			t.Errorf("embedded asset %s is empty", f)
		}
	}
	for _, label := range []string{
		"me.viktorbarzin.appium",
		"me.viktorbarzin.ios-rig-awake",
		"me.viktorbarzin.wda-run",
		"me.viktorbarzin.wda-resign",
		"me.viktorbarzin.ios-rig-build",
	} {
		b, err := iosAssets.ReadFile("ios_assets/launchagents/" + label + ".plist.tmpl")
		if err != nil {
			t.Errorf("missing plist template for %s: %v", label, err)
			continue
		}
		if !strings.Contains(string(b), "<key>Label</key><string>"+label+"</string>") {
			t.Errorf("%s template does not declare its own Label", label)
		}
		// Aqua is load-bearing on the three that touch Xcode: codesign cannot
		// reach the login keychain from a Background (SSH) session.
		if strings.Contains(label, "wda") || strings.Contains(label, "build") {
			if !strings.Contains(string(b), "LimitLoadToSessionType</key><string>Aqua") {
				t.Errorf("%s must be Aqua-only or codesign fails with errSecInternalComponent", label)
			}
		}
	}
}

// A placeholder left unrendered ships a plist naming a directory that does not
// exist, which launchd accepts and then fails at run time.
func TestPlistTemplatesRenderFully(t *testing.T) {
	c := iosDefaults()
	entries, err := iosAssets.ReadDir("ios_assets/launchagents")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) == 0 {
		t.Fatal("no launchagent templates embedded")
	}
	for _, e := range entries {
		b, err := iosAssets.ReadFile("ios_assets/launchagents/" + e.Name())
		if err != nil {
			t.Fatal(err)
		}
		out := strings.NewReplacer(
			"@DEVELOPER_DIR@", c.DeveloperDir,
			"@APPIUM_PORT@", c.AppiumPort,
		).Replace(string(b))
		if strings.Contains(out, "@") && strings.Contains(out, "@\n") {
			t.Errorf("%s still holds an unrendered placeholder", e.Name())
		}
		for _, ph := range []string{"@DEVELOPER_DIR@", "@APPIUM_PORT@"} {
			if strings.Contains(out, ph) {
				t.Errorf("%s still holds %s after rendering", e.Name(), ph)
			}
		}
	}
}

func TestIosCommandsRegistered(t *testing.T) {
	reg := buildRegistry()
	want := map[string]bool{
		"ios": false, "ios doctor": false, "ios shot": false,
		"ios install": false, "ios apps": false, "ios wda-url": false,
		"ios bootstrap": false,
	}
	for _, c := range reg {
		if k := strings.Join(c.Path, " "); want[k] == false {
			if _, ok := want[k]; ok {
				want[k] = true
				if c.Run == nil {
					t.Errorf("%q has no Run", k)
				}
				if c.Summary == "" {
					t.Errorf("%q has no Summary", k)
				}
			}
		}
	}
	for k, found := range want {
		if !found {
			t.Errorf("verb %q is not in the registry", k)
		}
	}
}

// The catalog told every agent there was no iOS instrument. That claim is what
// stopped anyone reaching for the rig, so it is worth a test.
func TestCapabilityCatalogKnowsAboutIOS(t *testing.T) {
	caps := capabilities()
	// Key on Intent, not on Use containing "homelab ios": several entries now
	// point at the rig, and matching the first of them found the wrong one.
	var iosEntry *capability
	for i := range caps {
		if strings.Contains(caps[i].Intent, "on a real iPhone") {
			iosEntry = &caps[i]
			break
		}
	}
	if iosEntry == nil {
		t.Fatal("no capability entry points at homelab ios")
	}
	for _, syn := range []string{"iphone", "safari", "sideload"} {
		found := false
		for _, s := range iosEntry.Synonyms {
			if s == syn {
				found = true
			}
		}
		if !found {
			t.Errorf("iOS capability is not findable by %q", syn)
		}
	}
	named := 0
	for _, c := range caps {
		if strings.Contains(c.Use, "homelab ios") {
			named++
		}
	}
	if named < 2 {
		t.Errorf("only %d capability summary lines name homelab ios; the browser and "+
			"phone entries should both, since the Use line is what gets skimmed", named)
	}

	for _, c := range caps {
		for _, d := range c.Detail {
			if strings.Contains(d, "NO INSTRUMENT for Safari") ||
				strings.Contains(d, "there is NO iOS instrument") {
				t.Errorf("stale claim that no iOS instrument exists: %q", d)
			}
		}
	}
}

// The bug this test exists for: the embedded tunnel unit called
// `homelab ios tunnel-fg`, a verb that existed nowhere in the repo. The rig's
// predecessor had a `tunnel` subcommand, and folding the rig into the CLI on
// 2026-09-12 deleted it without porting it. Nothing failed at build time,
// nothing failed in CI, and the unit failed at exec on the devvm every 15
// seconds for 7 days. A unit asset naming a verb is a claim the registry has
// to honour.
func TestIosUnitAssetsNameRegisteredVerbs(t *testing.T) {
	registered := map[string]bool{}
	for _, c := range buildRegistry() {
		registered[strings.Join(c.Path, " ")] = true
	}
	entries, err := iosAssets.ReadDir("ios_assets")
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".service") {
			continue
		}
		b, err := iosAssets.ReadFile("ios_assets/" + e.Name())
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range strings.Split(string(b), "\n") {
			if !strings.HasPrefix(line, "ExecStart=") {
				continue
			}
			fields := strings.Fields(strings.TrimPrefix(line, "ExecStart="))
			if len(fields) < 3 || !strings.HasSuffix(fields[0], "/homelab") {
				t.Errorf("%s: ExecStart does not invoke the homelab binary: %q", e.Name(), line)
				continue
			}
			verb := fields[1] + " " + fields[2]
			checked++
			if !registered[verb] {
				t.Errorf("%s calls %q, which is not a registered verb", e.Name(), verb)
			}
		}
	}
	if checked == 0 {
		t.Fatal("no ExecStart lines found; the test is not looking at anything")
	}
}

// The tunnel is the whole reason `ios shot` can reach Appium: the Mac binds it
// to loopback, so without this forward the devvm has nothing to dial.
func TestIosTunnelArgs(t *testing.T) {
	c := iosDefaults()
	c.MacHost = "mac.example"
	c.MacUser = "someone"
	c.AppiumPort = "4999"
	args := iosTunnelArgs(c)
	joined := strings.Join(args, " ")

	if got := args[len(args)-1]; got != "someone@mac.example" {
		t.Errorf("target must be last so ssh parses it as the host, got %q", got)
	}
	if !strings.Contains(joined, "-L 4999:127.0.0.1:4999") {
		t.Errorf("forward does not carry the configured port: %q", joined)
	}
	// Without this, ssh stays up with no forward, systemd sees a healthy
	// process, and every `ios shot` fails on a connection nothing is watching.
	if !strings.Contains(joined, "ExitOnForwardFailure=yes") {
		t.Errorf("a failed forward must kill the process so systemd restarts it: %q", joined)
	}
	if !strings.Contains(joined, "ServerAliveInterval=") {
		t.Errorf("a roaming laptop needs keepalives to detect a dead link: %q", joined)
	}
	if !strings.Contains(joined, "-N") {
		t.Errorf("the tunnel must not request a remote command: %q", joined)
	}
}

// Repairing the devvm side must not depend on the Mac. The units broke while
// the Mac was away, and bootstrap refuses at its ssh precheck, so without this
// flag the one machine that could be fixed was the one that could not be.
func TestIosBootstrapUnitsOnlySkipsTheMac(t *testing.T) {
	t.Setenv("IOS_RIG_MAC_HOST", "192.0.2.1") // TEST-NET-1, never answers
	if err := iosBootstrap([]string{"--units-only", "--dry-run"}); err != nil {
		t.Fatalf("--units-only must not touch the Mac, got %v", err)
	}
}

// The Mac's private Wi-Fi address has rotated twice in seven days, each time
// stranding a reservation and a DNS record that both name .168. The hardware
// address does not rotate, which is what makes it usable as the identity.
func TestIosHardwareAddrFromNetworksetup(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"the real output",
			"Ethernet Address: 84:2f:57:39:9a:d9 (Device: en0)", "84:2f:57:39:9a:d9"},
		{"uppercase normalises",
			"Ethernet Address: 84:2F:57:39:9A:D9 (Device: en0)", "84:2f:57:39:9a:d9"},
		// The Mac's login shell emits iTerm2 OSC escapes into every command's
		// output, so the parser has to survive them here as it does elsewhere.
		{"with an OSC escape in front",
			"\x1b]1337;SetUserVar=x=\x07Ethernet Address: 84:2f:57:39:9a:d9 (Device: en0)", "84:2f:57:39:9a:d9"},
		{"nothing there", "command not found", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := iosHardwareAddr(c.in); got != c.want {
				t.Errorf("got %q want %q", got, c.want)
			}
		})
	}
}

func TestIosSubnetHosts(t *testing.T) {
	hosts, err := iosSubnetHosts("192.168.8.0/24")
	if err != nil {
		t.Fatal(err)
	}
	// Network and broadcast are not hosts, so a /24 offers 254.
	if len(hosts) != 254 {
		t.Fatalf("a /24 has 254 usable hosts, got %d", len(hosts))
	}
	if hosts[0] != "192.168.8.1" || hosts[253] != "192.168.8.254" {
		t.Errorf("bounds wrong: %s .. %s", hosts[0], hosts[253])
	}
	// A /32 is how someone pins discovery to one address; it must not be empty.
	one, err := iosSubnetHosts("10.0.0.5/32")
	if err != nil || len(one) != 1 || one[0] != "10.0.0.5" {
		t.Errorf("/32 should yield exactly itself, got %v (%v)", one, err)
	}
	if _, err := iosSubnetHosts("not-a-cidr"); err == nil {
		t.Error("a bad CIDR must be an error, not an empty scan that looks like 'nothing found'")
	}
	// A sweep of the whole internet is a mistake, not a request.
	if _, err := iosSubnetHosts("10.0.0.0/8"); err == nil {
		t.Error("an oversized range must be refused rather than attempted")
	}
}

func TestIosScanPortFindsAListener(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	port := strings.TrimPrefix(ln.Addr().String(), "127.0.0.1:")

	found := iosScanPort([]string{"127.0.0.1", "127.0.0.2"}, port, 2*time.Second)
	if len(found) == 0 || found[0] != "127.0.0.1" {
		t.Errorf("the live listener was not found: %v", found)
	}

	// A port nobody serves must come back empty rather than hang.
	start := time.Now()
	if got := iosScanPort([]string{"127.0.0.1"}, "1", 1*time.Second); len(got) != 0 {
		t.Errorf("expected nothing on a dead port, got %v", got)
	}
	if time.Since(start) > 5*time.Second {
		t.Error("a dead port must fail fast, not hang the scan")
	}
}

// Discovery is a fallback, never the normal path: it must not scan the LAN
// when the configured name answers, or every command pays for it.
func TestIosResolveMacHostPrefersTheConfiguredName(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	host, port, _ := net.SplitHostPort(ln.Addr().String())

	c := iosDefaults()
	c.MacHost = host
	c.SSHPort = port
	c.MacSubnet = "203.0.113.0/24" // TEST-NET-3; a scan here would prove we scanned
	scanned := false
	got, err := c.resolveMacHost(func() (string, error) { scanned = true; return "", nil })
	if err != nil {
		t.Fatal(err)
	}
	if got != host {
		t.Errorf("got %q, want the configured %q", got, host)
	}
	if scanned {
		t.Error("the configured host answered, so nothing should have been scanned")
	}
}

// A Mac that is genuinely away made the tunnel unit sweep all 254 addresses
// every 15 seconds: 137 sweeps in the hour after the laptop left on
// 2026-09-19, about 35,000 connection attempts into the LAN for a machine
// that was not going to answer. The cooldown suppresses the expensive sweep
// without delaying recovery, because the cheap direct checks still run every
// cycle.
func TestIosDiscoveryCooldown(t *testing.T) {
	const cool = 5 * time.Minute
	now := time.Now()
	cases := []struct {
		name  string
		last  time.Time
		sweep bool
	}{
		{"never failed before", time.Time{}, true},
		{"failed a moment ago", now.Add(-10 * time.Second), false},
		{"failed just inside the window", now.Add(-4 * time.Minute), false},
		{"failed longer ago than the window", now.Add(-6 * time.Minute), true},
		// A clock that jumped backwards must not disable discovery forever.
		{"marker in the future", now.Add(time.Hour), true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := iosShouldSweep(c.last, now, cool); got != c.sweep {
				t.Errorf("shouldSweep=%v want %v", got, c.sweep)
			}
		})
	}
}

func TestIosDiscoveryFailureMarkerRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "marker")

	if got := iosReadFailureMarker(path); !got.IsZero() {
		t.Errorf("a missing marker must read as zero, got %v", got)
	}
	when := time.Now().Add(-90 * time.Second).Truncate(time.Second)
	iosWriteFailureMarker(path, when)
	if got := iosReadFailureMarker(path); !got.Equal(when) {
		t.Errorf("round trip lost the time: wrote %v read %v", when, got)
	}
	// A success clears it, so the Mac coming back restores full discovery at once.
	iosClearFailureMarker(path)
	if got := iosReadFailureMarker(path); !got.IsZero() {
		t.Errorf("clearing must reset to zero, got %v", got)
	}
	// Garbage must not read as "failed in 1970", which would sweep every time.
	os.WriteFile(path, []byte("not a timestamp"), 0o644)
	if got := iosReadFailureMarker(path); !got.IsZero() {
		t.Errorf("an unparseable marker must read as zero, got %v", got)
	}
}
