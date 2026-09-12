package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ios verbs drive the iPhone test rig: sideload a build with a free Apple ID,
// tap it, screenshot it. See docs/runbooks/ios-test-rig.md.
//
// NOT named cmd_ios.go: Go reads a trailing _<GOOS> in a file name as an
// implicit build constraint, and `ios` is a real GOOS, so that name excluded
// this file from every build here while compiling cleanly on its own. The
// symptom is `undefined: iosCommands` with no error in the file itself.
//
// This is the only iOS instrument here. The Android emulator cannot stand in
// for it, and Playwright WebKit on Linux is not Safari.

func iosCommands() []Command {
	return []Command{
		{Path: []string{"ios"}, Tier: TierRead,
			Summary: "drive the iPhone test rig (run `ios --help`)", Run: iosTopHelp},
		{Path: []string{"ios", "doctor"}, Tier: TierRead,
			Summary: "check every link: Mac, cable, Developer Mode, Appium, WebDriverAgent, lock state", Run: iosDoctor},
		{Path: []string{"ios", "shot"}, Tier: TierWrite,
			Summary: "screenshot the phone, optionally driving it first: ios shot <out.png> [--url U] [--tap X,Y] [--app BUNDLE]", Run: iosShot},
		{Path: []string{"ios", "install"}, Tier: TierWrite,
			Summary: "build an Xcode project with the free team and install it: ios install <dir> [--scheme S] [--bundle-id B] [--no-launch]", Run: iosInstall},
		{Path: []string{"ios", "apps"}, Tier: TierRead,
			Summary: "list sideloaded apps (the free tier allows 3, WebDriverAgent holds one)", Run: iosApps},
		{Path: []string{"ios", "wda-url"}, Tier: TierRead,
			Summary: "print where WebDriverAgent is listening right now", Run: iosWdaURL},
		{Path: []string{"ios", "bootstrap"}, Tier: TierWrite,
			Summary: "provision the Mac agents and the devvm units; idempotent, safe to re-run", Run: iosBootstrap},
	}
}

func iosTopHelp(args []string) error { fmt.Print(iosHelp()); return nil }

func iosHelp() string {
	return `homelab ios — drive the iPhone test rig

  ios doctor                       check every link in the chain
  ios shot <out.png> [flags]       screenshot, optionally driving the phone first
        --url <url>                open it in Safari and wait for Safari to be frontmost
        --tap <X,Y>                tap at those screen coordinates
        --app <bundle-id>          launch that app for the session instead
  ios install <dir> [flags]        build an Xcode project and put it on the phone
        --scheme <name>            xcodebuild scheme (default: directory name)
        --bundle-id <id>           sign as this (default: me.viktorbarzin.<dir>)
        --no-launch                install without launching
  ios apps                         what is installed, against the 3-app cap
  ios wda-url                      where WebDriverAgent is listening
  ios bootstrap [--dry-run]        provision the Mac and this box

Two things the rig cannot do for itself, both by design:
  - the phone must stay UNLOCKED. Set Auto-Lock to Never. A locked phone can be
    screenshotted and nothing else, and WebDriverAgent cannot unlock it.
  - a Mac reboot needs a human, because FileVault holds the disk until someone
    types the password. No agent, no SSH, no rig until then.

Free Apple ID limits: certificates last 7 days, 3 apps installed at once
(WebDriverAgent permanently holds one), 10 new App IDs per week. Reusing a
bundle id costs nothing.
`
}

func iosHelpWanted(args []string) bool {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			return true
		}
	}
	return false
}

// --- doctor -----------------------------------------------------------------

type iosCheck struct {
	name   string
	detail string
	level  int // 0 ok, 1 warn, 2 fail
}

func iosDoctor(args []string) error {
	if iosHelpWanted(args) {
		fmt.Print(iosHelp())
		return nil
	}
	c := iosDefaults()
	var checks []iosCheck
	add := func(level int, name, detail string) {
		checks = append(checks, iosCheck{name: name, detail: detail, level: level})
	}

	fmt.Printf("iOS rig via %s, %s\n\n", c.target(), time.Now().UTC().Format(time.RFC3339))

	if _, err := c.onMac("true"); err != nil {
		add(2, "ssh", fmt.Sprintf("cannot reach %s: %v", c.target(), err))
		return iosReport(checks)
	}
	add(0, "ssh", c.target())

	details, err := c.deviceDetails()
	if err != nil && !strings.Contains(details, "bootState") {
		add(2, "device", "devicectl could not read the device: "+firstLine(details))
		return iosReport(checks)
	}
	has := func(s string) bool { return strings.Contains(details, s) }

	if has("bootState: booted") {
		add(0, "device", c.UDID+" booted")
	} else {
		add(2, "device", "not connected or not booted; check the cable")
	}
	if has("pairingState: paired") {
		add(0, "pairing-coredevice", "paired")
	} else {
		add(2, "pairing-coredevice", "unpaired; run `devicectl manage pair` on the Mac and tap Trust")
	}
	if has("developerModeStatus: enabled") {
		add(0, "developer-mode", "enabled")
	} else {
		add(2, "developer-mode", "off; Settings, Privacy and Security, Developer Mode")
	}
	if has("ddiServicesAvailable: true") {
		add(0, "ddi-services", "available")
	} else {
		add(2, "ddi-services", "developer disk image services unavailable")
	}
	if v := afterKey(details, "osVersionNumber: "); v != "" {
		// The phone tracks iOS updates by choice, so a bump is expected and is
		// the likeliest cause of a sudden break.
		add(1, "ios-version", v)
	}

	// The lockdown pairing is blocked by Stolen Device Protection and stays
	// that way. It costs device logs and ideviceinstaller, not device control,
	// so it is a standing warning rather than a failure.
	if out, _ := c.onMac("idevicepair -u " + c.UDID + " validate"); strings.Contains(strings.ToUpper(out), "SUCCESS") {
		add(0, "pairing-lockdown", "trusted")
	} else {
		add(1, "pairing-lockdown", "unavailable (Stolen Device Protection); costs device logs, not control")
	}

	if c.phoneLocked() {
		add(2, "phone-unlocked", "LOCKED; WebDriverAgent cannot drive or unlock it. Set Auto-Lock to Never")
	} else {
		add(0, "phone-unlocked", "unlocked")
	}

	if out, _ := c.onMac("pmset -g assertions"); strings.Contains(out, "caffeinate") {
		add(0, "mac-awake", "caffeinate holding sleep off")
	} else {
		add(1, "mac-awake", "nothing holding sleep off; the rig stops ~11min after the laptop idles")
	}

	if out, _ := c.onMac("curl -s -m 8 http://127.0.0.1:" + c.AppiumPort + "/status"); strings.Contains(out, `"ready":true`) {
		add(0, "appium", "ready on 127.0.0.1:"+c.AppiumPort)
	} else {
		add(2, "appium", "not answering; launchctl kickstart gui/$(id -u)/me.viktorbarzin.appium")
	}

	if out, _ := c.onMac(fmt.Sprintf("%s/usr/bin/devicectl device info apps --device %s 2>/dev/null", c.DeveloperDir, c.UDID)); strings.Contains(out, c.WDABundleID) {
		add(0, "wda-installed", c.WDABundleID)
	} else {
		add(2, "wda-installed", "not installed; launchctl kickstart gui/$(id -u)/me.viktorbarzin.wda-resign")
	}

	if u, err := c.wdaURL(); err == nil {
		add(0, "wda-reachable", u)
	} else {
		add(2, "wda-reachable", err.Error())
	}

	if st, _ := c.onMac("cat ~/.ios-rig-status.json 2>/dev/null"); st != "" {
		if strings.Contains(st, `"ok":true`) {
			add(0, "last-resign", st)
		} else {
			add(2, "last-resign", st)
		}
	} else {
		add(1, "last-resign", "never run")
	}

	return iosReport(checks)
}

func iosReport(checks []iosCheck) error {
	okCount, failCount := 0, 0
	for _, c := range checks {
		switch c.level {
		case 0:
			fmt.Printf("  \033[32mok\033[0m    %-20s %s\n", c.name, c.detail)
			okCount++
		case 1:
			fmt.Printf("  \033[33mwarn\033[0m  %-20s %s\n", c.name, c.detail)
		default:
			fmt.Printf("  \033[31mFAIL\033[0m  %-20s %s\n", c.name, c.detail)
			failCount++
		}
	}
	fmt.Printf("\n%d ok, %d failing\n", okCount, failCount)
	if failCount > 0 {
		return fmt.Errorf("%d checks failing", failCount)
	}
	return nil
}

func afterKey(s, key string) string {
	i := strings.Index(s, key)
	if i < 0 {
		return ""
	}
	return firstLine(strings.TrimSpace(s[i+len(key):]))
}

// --- shot -------------------------------------------------------------------

func iosShot(args []string) error {
	if iosHelpWanted(args) || len(args) == 0 {
		fmt.Print(iosHelp())
		if len(args) == 0 {
			return fmt.Errorf("ios shot needs an output path")
		}
		return nil
	}
	c := iosDefaults()
	out := args[0]
	var url, tap, bundle string
	rest := args[1:]
	for i := 0; i < len(rest); i++ {
		switch rest[i] {
		case "--url":
			if i+1 < len(rest) {
				url = rest[i+1]
				i++
			}
		case "--tap":
			if i+1 < len(rest) {
				tap = rest[i+1]
				i++
			}
		case "--app":
			if i+1 < len(rest) {
				bundle = rest[i+1]
				i++
			}
		default:
			return fmt.Errorf("unknown flag %q", rest[i])
		}
	}

	wda, err := c.wdaURL()
	if err != nil {
		return err
	}
	base := "http://127.0.0.1:" + c.AppiumPort

	// webDriverAgentUrl is what makes this work at all: it tells the driver to
	// proxy to a WebDriverAgent already running on the device rather than
	// attaching over usbmux, which Stolen Device Protection blocks here.
	caps := map[string]interface{}{"capabilities": map[string]interface{}{
		"alwaysMatch": map[string]interface{}{
			"platformName":             "iOS",
			"appium:automationName":    "XCUITest",
			"appium:udid":              c.UDID,
			"appium:webDriverAgentUrl": wda,
			"appium:newCommandTimeout": 120,
		},
		"firstMatch": []interface{}{map[string]interface{}{}},
	}}
	if bundle != "" {
		caps["capabilities"].(map[string]interface{})["alwaysMatch"].(map[string]interface{})["appium:bundleId"] = bundle
	}

	resp, err := postJSON(base+"/session", caps, 5*time.Minute)
	if err != nil {
		return err
	}
	sid, _ := resp["value"].(map[string]interface{})["sessionId"].(string)
	if sid == "" {
		return fmt.Errorf("appium returned no session id")
	}
	defer doJSON("DELETE", base+"/session/"+sid, nil, time.Minute)
	fmt.Fprintf(os.Stderr, "session %s\n", sid)

	if url != "" {
		if _, err := postJSON(base+"/session/"+sid+"/execute/sync", map[string]interface{}{
			"script": "mobile: deepLink",
			// Naming Safari explicitly matters: the phone's default browser is
			// Chrome, so an unqualified deepLink opens the wrong app.
			"args": []interface{}{map[string]interface{}{"url": url, "bundleId": "com.apple.mobilesafari"}},
		}, 2*time.Minute); err != nil {
			return err
		}
		waitForFront(base, sid, "com.apple.mobilesafari")
	}
	if tap != "" {
		x, y, err := parseXY(tap)
		if err != nil {
			return err
		}
		if _, err := postJSON(base+"/session/"+sid+"/actions", map[string]interface{}{
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
		}, time.Minute); err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "tapped %d,%d\n", x, y)
	}

	shot, err := getJSON(base+"/session/"+sid+"/screenshot", 2*time.Minute)
	if err != nil {
		return err
	}
	b64, _ := shot["value"].(string)
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return fmt.Errorf("screenshot was not valid base64: %w", err)
	}
	if err := os.WriteFile(out, raw, 0o644); err != nil {
		return err
	}
	fmt.Printf("%s (%d bytes)\n", out, len(raw))
	return nil
}

// waitForFront polls until the target app is frontmost. A screenshot taken
// straight after a deepLink otherwise catches the iOS app-switch animation and
// comes back as a blurred frosted pane.
func waitForFront(base, sid, bundle string) {
	deadline := time.Now().Add(30 * time.Second)
	var last string
	for time.Now().Before(deadline) {
		r, err := postJSON(base+"/session/"+sid+"/execute/sync",
			map[string]interface{}{"script": "mobile: activeAppInfo", "args": []interface{}{}}, 30*time.Second)
		if err == nil {
			if v, ok := r["value"].(map[string]interface{}); ok {
				last, _ = v["bundleId"].(string)
			}
		}
		if last == bundle {
			time.Sleep(1500 * time.Millisecond) // frontmost is not finished animating
			fmt.Fprintf(os.Stderr, "%s frontmost\n", bundle)
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	fmt.Fprintf(os.Stderr, "warning: %s never came to the front (saw %q)\n", bundle, last)
}

func parseXY(s string) (int, int, error) {
	parts := strings.SplitN(s, ",", 2)
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("--tap wants X,Y, got %q", s)
	}
	x, err1 := strconv.Atoi(strings.TrimSpace(parts[0]))
	y, err2 := strconv.Atoi(strings.TrimSpace(parts[1]))
	if err1 != nil || err2 != nil {
		return 0, 0, fmt.Errorf("--tap wants two integers, got %q", s)
	}
	return x, y, nil
}

// --- install ----------------------------------------------------------------

func iosInstall(args []string) error {
	if iosHelpWanted(args) || len(args) == 0 {
		fmt.Print(iosHelp())
		if len(args) == 0 {
			return fmt.Errorf("ios install needs a project directory")
		}
		return nil
	}
	c := iosDefaults()
	src := args[0]
	scheme, bundle := "", ""
	launch := "1"
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--scheme":
			if i+1 < len(args) {
				scheme = args[i+1]
				i++
			}
		case "--bundle-id":
			if i+1 < len(args) {
				bundle = args[i+1]
				i++
			}
		case "--no-launch":
			launch = "0"
		default:
			return fmt.Errorf("unknown flag %q", args[i])
		}
	}
	abs, err := filepath.Abs(src)
	if err != nil {
		return err
	}
	if fi, err := os.Stat(abs); err != nil || !fi.IsDir() {
		return fmt.Errorf("%s is not a directory", src)
	}
	name := filepath.Base(abs)
	if scheme == "" {
		scheme = name
	}
	if bundle == "" {
		bundle = "me.viktorbarzin." + strings.ToLower(name)
	}
	remote := "ios-rig-builds/" + name

	fmt.Printf("copying %s to %s:%s\n", src, c.target(), remote)
	c.onMac("mkdir -p $HOME/" + remote)
	// --delete so a source file removed locally does not linger and get built.
	rsyncArgs := []string{"-az", "--delete", "-e", "ssh " + strings.Join(iosSSHOpts, " "),
		abs + "/", c.target() + ":" + remote + "/"}
	if err := runStreaming("rsync", rsyncArgs...); err != nil {
		return fmt.Errorf("rsync to the Mac failed: %w", err)
	}

	env := fmt.Sprintf("RIG_BUILD_DIR=$HOME/%s\nRIG_BUILD_SCHEME=%s\nRIG_BUILD_BUNDLE=%s\nRIG_BUILD_LAUNCH=%s\n",
		remote, scheme, bundle, launch)
	if _, err := c.onMac("cat > $HOME/.ios-rig-build.env <<'RIGEOF'\n" + env + "RIGEOF"); err != nil {
		return err
	}
	c.onMac("rm -f ~/.ios-rig-build-status.json")

	// The build runs in the Aqua session because codesign cannot reach the
	// login keychain over SSH; it fails with errSecInternalComponent there.
	fmt.Printf("building %s as %s\n", scheme, bundle)
	if _, err := c.onMac("launchctl kickstart gui/$(id -u)/me.viktorbarzin.ios-rig-build"); err != nil {
		return fmt.Errorf("could not start the build agent: %w", err)
	}

	deadline := time.Now().Add(15 * time.Minute)
	for time.Now().Before(deadline) {
		st, _ := c.onMac("cat ~/.ios-rig-build-status.json 2>/dev/null")
		if st != "" {
			fmt.Println(st)
			if strings.Contains(st, `"ok":true`) {
				return nil
			}
			log, _ := c.onMac("tail -25 /tmp/ios-rig-build.log")
			fmt.Fprintln(os.Stderr, log)
			return fmt.Errorf("build failed")
		}
		time.Sleep(5 * time.Second)
	}
	log, _ := c.onMac("tail -20 /tmp/ios-rig-build.log")
	fmt.Fprintln(os.Stderr, log)
	return fmt.Errorf("build did not finish within 15 minutes")
}

func iosApps(args []string) error {
	if iosHelpWanted(args) {
		fmt.Print(iosHelp())
		return nil
	}
	c := iosDefaults()
	out, err := c.onMac(fmt.Sprintf("%s/usr/bin/devicectl device info apps --device %s 2>/dev/null", c.DeveloperDir, c.UDID))
	if err != nil {
		return err
	}
	for _, line := range strings.Split(out, "\n") {
		// devicectl prefixes progress lines with a wall-clock timestamp.
		if len(line) > 8 && line[2] == ':' && line[5] == ':' {
			continue
		}
		fmt.Println(line)
	}
	return nil
}

func iosWdaURL(args []string) error {
	if iosHelpWanted(args) {
		fmt.Print(iosHelp())
		return nil
	}
	u, err := iosDefaults().wdaURL()
	if err != nil {
		return err
	}
	fmt.Println(u)
	return nil
}

// --- bootstrap --------------------------------------------------------------

func iosBootstrap(args []string) error {
	if iosHelpWanted(args) {
		fmt.Print(iosHelp())
		return nil
	}
	dry := false
	for _, a := range args {
		if a == "--dry-run" {
			dry = true
		} else {
			return fmt.Errorf("unknown flag %q", a)
		}
	}
	c := iosDefaults()

	if _, err := c.onMac("true"); err != nil {
		return fmt.Errorf("cannot ssh to %s. Your key needs to be in its authorized_keys; "+
			"that is the one step this cannot do for you: %w", c.target(), err)
	}
	fmt.Printf("==> %s reachable\n", c.target())

	step := func(label, script string) error {
		fmt.Printf("==> %s\n", label)
		if dry {
			fmt.Printf("    would run: %s\n", firstLine(script))
			return nil
		}
		out, err := c.onMac(script)
		if out != "" {
			fmt.Println("   ", strings.ReplaceAll(out, "\n", "\n    "))
		}
		return err
	}

	if err := step("Homebrew formulae", `export PATH=/opt/homebrew/bin:$PATH HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
for f in libimobiledevice ideviceinstaller socat xcodegen; do
  brew list --formula "$f" >/dev/null 2>&1 || brew install "$f"
done
brew list --versions libimobiledevice ideviceinstaller socat xcodegen`); err != nil {
		return err
	}

	if err := step("Node and Appium", `export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:$PATH"
command -v node >/dev/null || brew install node
command -v appium >/dev/null || npm install -g appium
appium driver list --installed 2>&1 | grep -q xcuitest || appium driver install xcuitest
echo "appium $(appium --version)"`); err != nil {
		return err
	}

	for _, s := range []struct{ asset, dest string }{
		{"ios_assets/resign-wda.sh", "bin/ios-rig-resign-wda.sh"},
		{"ios_assets/run-wda.sh", "bin/ios-rig-run-wda.sh"},
		{"ios_assets/build-install.sh", "bin/ios-rig-build-install.sh"},
	} {
		if err := c.putAsset(s.asset, s.dest, "0755", dry); err != nil {
			return err
		}
	}

	agents := []string{
		"me.viktorbarzin.appium",
		"me.viktorbarzin.ios-rig-awake",
		"me.viktorbarzin.wda-run",
		"me.viktorbarzin.wda-resign",
		"me.viktorbarzin.ios-rig-build",
	}
	for _, label := range agents {
		tmpl, err := iosAssets.ReadFile("ios_assets/launchagents/" + label + ".plist.tmpl")
		if err != nil {
			return err
		}
		rendered := strings.NewReplacer(
			"@DEVELOPER_DIR@", c.DeveloperDir,
			"@APPIUM_PORT@", c.AppiumPort,
		).Replace(string(tmpl))
		fmt.Printf("==> %s\n", label)
		if dry {
			continue
		}
		if _, err := c.onMac("mkdir -p $HOME/Library/LaunchAgents && cat > $HOME/Library/LaunchAgents/" +
			label + ".plist <<'PLISTEOF'\n" + rendered + "\nPLISTEOF"); err != nil {
			return err
		}
		if _, err := c.onMac("plutil -lint $HOME/Library/LaunchAgents/" + label + ".plist"); err != nil {
			return fmt.Errorf("%s rendered an invalid plist", label)
		}
		// bootout is asynchronous: bootstrapping before the old job finishes
		// unloading fails with "Input/output error" and leaves NOTHING loaded,
		// which is how a re-run once took Appium down.
		out, err := c.onMac(`L=` + label + `
launchctl bootout gui/$(id -u)/$L 2>/dev/null || true
for _ in $(seq 1 20); do launchctl list | grep -qF $L || break; sleep 0.5; done
for _ in 1 2 3 4 5; do launchctl bootstrap gui/$(id -u) $HOME/Library/LaunchAgents/$L.plist 2>/dev/null && break; sleep 1; done
launchctl list | grep -F $L || { echo "FAILED to load $L"; exit 1; }`)
		fmt.Println("   ", firstLine(out))
		if err != nil {
			return fmt.Errorf("%s did not load", label)
		}
	}

	fmt.Println("==> devvm units")
	if err := iosInstallUnits(dry); err != nil {
		return err
	}

	fmt.Println("\nDone. Next: homelab ios doctor")
	return nil
}

func (c iosConfig) putAsset(asset, dest, mode string, dry bool) error {
	body, err := iosAssets.ReadFile(asset)
	if err != nil {
		return err
	}
	fmt.Printf("==> %s\n", dest)
	if dry {
		return nil
	}
	_, err = c.onMac("mkdir -p $(dirname $HOME/" + dest + ") && cat > $HOME/" + dest +
		" <<'ASSETEOF'\n" + string(body) + "\nASSETEOF\nchmod " + mode + " $HOME/" + dest)
	return err
}

// iosInstallUnits writes the devvm-side systemd user units. They are user units
// rather than system ones because they run as whoever owns the SSH key that
// reaches the Mac.
func iosInstallUnits(dry bool) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(home, ".config", "systemd", "user")
	units := []string{"ios-rig-tunnel.service", "ios-rig-doctor.service", "ios-rig-doctor.timer"}
	if dry {
		fmt.Printf("    would write %v into %s\n", units, dir)
		return nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	for _, u := range units {
		body, err := iosAssets.ReadFile("ios_assets/" + u)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, u), body, 0o644); err != nil {
			return err
		}
	}
	if err := exec.Command("systemctl", "--user", "daemon-reload").Run(); err != nil {
		return err
	}
	return exec.Command("systemctl", "--user", "enable", "--now",
		"ios-rig-tunnel.service", "ios-rig-doctor.timer").Run()
}

// iosTestAppTo writes the embedded proof-of-life app into dir, so
// `homelab ios install` has something to verify the whole path against.
func iosTestAppTo(dir string) error {
	for _, f := range []string{"project.yml", "Sources/RigTestApp.swift"} {
		body, err := iosAssets.ReadFile("ios_assets/testapp/" + f)
		if err != nil {
			return err
		}
		dest := filepath.Join(dir, f)
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(dest, body, 0o644); err != nil {
			return err
		}
	}
	return nil
}

var _ = json.Marshal // keep encoding/json imported for future structured output
