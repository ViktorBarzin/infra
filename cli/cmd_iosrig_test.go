package main

import (
	"os"
	"strings"
	"testing"
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
	var iosEntry *capability
	for i := range caps {
		if strings.Contains(caps[i].Use, "homelab ios") {
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
	for _, c := range caps {
		for _, d := range c.Detail {
			if strings.Contains(d, "NO INSTRUMENT for Safari") ||
				strings.Contains(d, "there is NO iOS instrument") {
				t.Errorf("stale claim that no iOS instrument exists: %q", d)
			}
		}
	}
}
