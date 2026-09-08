package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/golang/glog"
	"github.com/nightlyone/lockfile"
)

// idracCredentials carries the iDRAC base URL ("https://<host>") plus basic-auth
// creds. idrac_utils.go derives the Redfish system + reset-action URLs from url.
type idracCredentials = struct {
	url      string
	username string
	password string
}

// config is the fully-resolved runtime configuration (flag defaults, then env
// override — env wins so secrets can be sourced out-of-band, e.g. from Vault).
type config struct {
	idrac                idracCredentials
	snmpTarget           string
	snmpCommunity        string
	pushgatewayURL       string
	stateFile            string
	disableFile          string
	shutdownMinMinutes   int   // shut down when UPS minutes-remaining < this while on battery
	powerOnMinChargePct  int   // only power on when UPS charge% >= this
	mainsStableDwellSecs int64 // and mains has been continuously on-line >= this
}

// watchdogState persists between the 10-minute runs (the process is stateless
// otherwise). It backs both the mains-stability dwell timer and the latched
// "last actuation attempt + outcome" observability signals.
type watchdogState struct {
	MainsOnlineSince    int64 `json:"mains_online_since"`    // unix s; 0 = on battery / unknown
	LastShutdownAttempt int64 `json:"last_shutdown_attempt"` // unix s; 0 = never
	LastShutdownError   bool  `json:"last_shutdown_error"`
	LastPowerOnAttempt  int64 `json:"last_power_on_attempt"` // unix s; 0 = never
	LastPowerOnError    bool  `json:"last_power_on_error"`
}

// metrics is the snapshot pushed to the Prometheus Pushgateway at the end of
// every run (best-effort; a failed push never fails the run).
type metrics struct {
	up                int // 1 iff iDRAC power-state AND UPS SNMP were both read OK
	actuationDisabled int
	haveServer        bool
	serverOn          int
	haveUPS           bool
	onMains           int
	chargePct         int64
	minutesRemaining  int64
	secondsOnBattery  int64
	batteryStatus     int64
	mainsStableSecs   int64

	// latched from state; always pushed so the alerts survive across runs
	lastShutdownAttempt int64
	lastShutdownError   int
	lastPowerOnAttempt  int64
	lastPowerOnError    int
}

func main() {
	cfg := loadConfig()

	m := &metrics{}
	runErr := run(cfg, m)
	if runErr != nil {
		glog.Errorf("watchdog run error: %v", runErr)
	}
	pushMetrics(cfg, m) // best-effort; must run even after a run error
	glog.Flush()
	if runErr != nil {
		os.Exit(1)
	}
}

func loadConfig() config {
	idracUsername := flag.String("idracUsername", "root", "iDRAC username (env IDRAC_USERNAME)")
	idracPassword := flag.String("idracPassword", "calvin", "iDRAC password (env IDRAC_PASSWORD)")
	idracHost := flag.String("idracHost", "192.168.1.4", "iDRAC host (env IDRAC_HOST)")
	snmpTarget := flag.String("snmpTarget", "192.168.1.5", "UPS SNMP target (env SNMP_TARGET)")
	snmpCommunity := flag.String("snmpCommunity", "Public0", "UPS SNMP community (env SNMP_COMMUNITY)")
	pushgateway := flag.String("pushgateway", "http://10.0.20.100:30091", "Prometheus Pushgateway base URL; empty disables (env PUSHGATEWAY_URL)")
	stateFile := flag.String("stateFile", "powercheck-state.json", "watchdog state file (env STATE_FILE)")
	disableFile := flag.String("disableFile", "powercheck.disable", "if this file exists, run in DRY-RUN: log decisions, issue no iDRAC reset (env DISABLE_FILE)")
	shutdownMinMinutes := flag.Int("shutdownMinMinutes", 20, "shut down when UPS minutes-remaining drops below this while on battery (env SHUTDOWN_MIN_MINUTES)")
	powerOnMinChargePct := flag.Int("powerOnMinChargePct", 50, "only power on when UPS charge percentage is at least this (env POWERON_MIN_CHARGE_PCT)")
	mainsStableDwellMinutes := flag.Int("mainsStableDwellMinutes", 10, "only power on after mains has been continuously on-line for this many minutes (env MAINS_STABLE_DWELL_MINUTES)")
	flag.Parse()

	host := envStr("IDRAC_HOST", *idracHost)
	return config{
		idrac: idracCredentials{
			url:      "https://" + host,
			username: envStr("IDRAC_USERNAME", *idracUsername),
			password: envStr("IDRAC_PASSWORD", *idracPassword),
		},
		snmpTarget:           envStr("SNMP_TARGET", *snmpTarget),
		snmpCommunity:        envStr("SNMP_COMMUNITY", *snmpCommunity),
		pushgatewayURL:       envStr("PUSHGATEWAY_URL", *pushgateway),
		stateFile:            envStr("STATE_FILE", *stateFile),
		disableFile:          envStr("DISABLE_FILE", *disableFile),
		shutdownMinMinutes:   int(envInt("SHUTDOWN_MIN_MINUTES", int64(*shutdownMinMinutes))),
		powerOnMinChargePct:  int(envInt("POWERON_MIN_CHARGE_PCT", int64(*powerOnMinChargePct))),
		mainsStableDwellSecs: envInt("MAINS_STABLE_DWELL_MINUTES", int64(*mainsStableDwellMinutes)) * 60,
	}
}

func run(cfg config, m *metrics) error {
	st := loadState(cfg.stateFile)
	syncMetricsFromState(m, st) // so latched signals are pushed even on early return

	glog.Info("Checking server power state via iDRAC Redfish")
	powerState, err := checkPowerState(cfg.idrac)
	if err != nil {
		return fmt.Errorf("check power state: %w", err)
	}
	m.haveServer = true
	if powerState == "On" {
		m.serverOn = 1
	}
	glog.Infof("Server power state: %s", powerState)

	glog.Info("Checking UPS state via SNMP")
	snmp := getSNMPClient(cfg.snmpTarget, cfg.snmpCommunity)
	if err := snmp.Connect(); err != nil {
		st.MainsOnlineSince = 0 // unknown mains -> restart the dwell (fail-safe)
		saveState(cfg.stateFile, st)
		return fmt.Errorf("connect UPS SNMP %s: %w", cfg.snmpTarget, err)
	}
	defer snmp.Conn.Close()

	ups, err := getPowerState(snmp)
	if err != nil {
		st.MainsOnlineSince = 0
		saveState(cfg.stateFile, st)
		return fmt.Errorf("read UPS SNMP: %w", err)
	}
	m.haveUPS = true
	m.chargePct = int64(ups.chargePercent)
	m.minutesRemaining = int64(ups.minutesRemaining)
	m.secondsOnBattery = ups.secondsOnBattery
	m.batteryStatus = int64(ups.batteryStatus)

	// On mains iff line voltage present AND the UPS reports zero elapsed time on
	// battery. Both together avoid acting during the transfer transient.
	onMains := ups.inputVoltage > 0 && ups.secondsOnBattery == 0
	if onMains {
		m.onMains = 1
	}

	// Mains-stability dwell tracking (persisted; the process itself is stateless).
	now := time.Now().Unix()
	if onMains {
		if st.MainsOnlineSince == 0 {
			st.MainsOnlineSince = now // first observation of mains back
		}
	} else {
		st.MainsOnlineSince = 0 // on battery -> reset the dwell
	}
	var mainsStableSecs int64
	if onMains && st.MainsOnlineSince > 0 && now >= st.MainsOnlineSince {
		mainsStableSecs = now - st.MainsOnlineSince
	}
	m.mainsStableSecs = mainsStableSecs
	m.up = 1

	dryRun := fileExists(cfg.disableFile)
	if dryRun {
		m.actuationDisabled = 1
		glog.Warningf("Actuation DISABLED (%s present) — decisions logged as [DRY-RUN], no iDRAC reset will be issued.", cfg.disableFile)
	}

	switch powerState {
	case "On":
		handleWhenServerOn(cfg, ups, onMains, dryRun, &st)
	case "Off":
		handleWhenServerOff(cfg, ups, onMains, mainsStableSecs, dryRun, &st)
	default:
		saveState(cfg.stateFile, st)
		return fmt.Errorf("unknown server power state %q", powerState)
	}

	saveState(cfg.stateFile, st)
	syncMetricsFromState(m, st)
	return nil
}

// powerAction is the decision the watchdog algorithm reaches for a given
// (server power state, UPS state). Extracted as pure functions (decideWhenOn /
// decideWhenOff) so the algorithm is unit-testable — a power outage can be
// SIMULATED with fabricated UPS inputs without touching the real iDRAC/UPS/host.
type powerAction int

const (
	actNone              powerAction = iota // server On, on mains — nothing to do
	actWaitOnBattery                        // server On, on battery, runtime still above threshold
	actShutdown                             // server On, on battery, runtime below threshold — shut down
	actHoldOnBattery                        // server Off, still on battery — do NOT power on
	actHoldLowCharge                        // server Off, on mains, charge below threshold — hold
	actHoldMainsUnstable                    // server Off, on mains, charge OK, mains not stable long enough — hold
	actPowerOn                              // server Off, on mains, charge OK, mains stable — power on
)

// decideWhenOn is the shutdown-side algorithm (server power state == On).
func decideWhenOn(ups UPSPowerState, onMains bool, shutdownMinMinutes int) powerAction {
	if onMains {
		return actNone
	}
	if ups.minutesRemaining >= shutdownMinMinutes {
		return actWaitOnBattery
	}
	return actShutdown
}

// decideWhenOff is the UPS-safe-gated power-on algorithm (server power state ==
// Off). Power-on requires BOTH a recharged battery (>= minChargePct) AND stable
// mains for a dwell period — the two gates that prevent a power-cycle loop
// across repeated short outages that never let the UPS recharge.
func decideWhenOff(ups UPSPowerState, onMains bool, mainsStableSecs int64, minChargePct int, dwellSecs int64) powerAction {
	if !onMains {
		return actHoldOnBattery
	}
	if ups.chargePercent < minChargePct {
		return actHoldLowCharge
	}
	if mainsStableSecs < dwellSecs {
		return actHoldMainsUnstable
	}
	return actPowerOn
}

func handleWhenServerOn(cfg config, ups UPSPowerState, onMains, dryRun bool, st *watchdogState) {
	switch decideWhenOn(ups, onMains, cfg.shutdownMinMinutes) {
	case actNone:
		glog.Infof("Server On, UPS on mains (input %dV, charge %d%%). Nothing to do.", ups.inputVoltage, ups.chargePercent)
	case actWaitOnBattery:
		glog.Warningf("Server On, UPS on BATTERY (%ds, charge %d%%, ~%d min remaining) — %d min >= threshold %d, not shutting down yet.",
			ups.secondsOnBattery, ups.chargePercent, ups.minutesRemaining, ups.minutesRemaining, cfg.shutdownMinMinutes)
	case actShutdown:
		if dryRun {
			glog.Warningf("[DRY-RUN] Server On, on BATTERY, minutes %d < %d — WOULD issue GracefulShutdown.", ups.minutesRemaining, cfg.shutdownMinMinutes)
			return
		}
		glog.Warningf("Server On, on BATTERY, minutes %d < threshold %d. Issuing iDRAC GracefulShutdown.", ups.minutesRemaining, cfg.shutdownMinMinutes)
		st.LastShutdownAttempt = time.Now().Unix()
		if err := performGracefulShutdown(cfg.idrac); err != nil {
			st.LastShutdownError = true
			glog.Errorf("GRACEFUL SHUTDOWN FAILED: %v", err)
			return
		}
		st.LastShutdownError = false
		glog.Warning("Graceful shutdown request accepted by iDRAC.")
	}
}

func handleWhenServerOff(cfg config, ups UPSPowerState, onMains bool, mainsStableSecs int64, dryRun bool, st *watchdogState) {
	// UPS-safe power-on gate: power on ONLY when the battery has recharged AND
	// mains has been stable for a dwell — else we risk a power-cycle loop that
	// drains a UPS which never recharges (Viktor 2026-07-19).
	switch decideWhenOff(ups, onMains, mainsStableSecs, cfg.powerOnMinChargePct, cfg.mainsStableDwellSecs) {
	case actHoldOnBattery:
		glog.Warningf("Server Off, UPS still on BATTERY (%ds, charge %d%%). Not powering on.", ups.secondsOnBattery, ups.chargePercent)
	case actHoldLowCharge:
		glog.Infof("Server Off, on mains but charge %d%% < %d%% threshold. Holding power-on until the battery recovers.",
			ups.chargePercent, cfg.powerOnMinChargePct)
	case actHoldMainsUnstable:
		glog.Infof("Server Off, on mains and charge %d%% OK, but mains only stable for %ds < %ds dwell. Waiting (anti power-cycle-loop).",
			ups.chargePercent, mainsStableSecs, cfg.mainsStableDwellSecs)
	case actPowerOn:
		if dryRun {
			glog.Warningf("[DRY-RUN] Server Off, mains stable %ds, charge %d%% >= %d%% — WOULD issue power ON.",
				mainsStableSecs, ups.chargePercent, cfg.powerOnMinChargePct)
			return
		}
		glog.Warningf("Server Off, mains stable for %ds and charge %d%% >= %d%%. Issuing iDRAC power ON.",
			mainsStableSecs, ups.chargePercent, cfg.powerOnMinChargePct)
		st.LastPowerOnAttempt = time.Now().Unix()
		if err := performPowerOn(cfg.idrac); err != nil {
			st.LastPowerOnError = true
			glog.Errorf("POWER-ON FAILED: %v", err)
			return
		}
		st.LastPowerOnError = false
		glog.Warning("Power-on request accepted by iDRAC.")
	}
}

// ---- state ----

func loadState(path string) watchdogState {
	var s watchdogState
	b, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			glog.Warningf("state read %s: %v (using empty state)", path, err)
		}
		return s
	}
	if err := json.Unmarshal(b, &s); err != nil {
		glog.Warningf("state parse %s: %v (using empty state)", path, err)
		return watchdogState{}
	}
	return s
}

func saveState(path string, s watchdogState) {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		glog.Errorf("state marshal: %v", err)
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		glog.Errorf("state write %s: %v", tmp, err)
		return
	}
	if err := os.Rename(tmp, path); err != nil { // atomic replace
		glog.Errorf("state rename %s -> %s: %v", tmp, path, err)
	}
}

func syncMetricsFromState(m *metrics, st watchdogState) {
	m.lastShutdownAttempt = st.LastShutdownAttempt
	m.lastShutdownError = b2i(st.LastShutdownError)
	m.lastPowerOnAttempt = st.LastPowerOnAttempt
	m.lastPowerOnError = b2i(st.LastPowerOnError)
}

// ---- metrics push (best-effort) ----

func pushMetrics(cfg config, m *metrics) {
	if cfg.pushgatewayURL == "" {
		return
	}
	var b strings.Builder
	writeGauge(&b, "powercheck_last_run_timestamp_seconds", "Unix time of the last watchdog run that reached the push step.", time.Now().Unix())
	writeGauge(&b, "powercheck_up", "1 iff this run read iDRAC power-state AND UPS SNMP successfully.", int64(m.up))
	writeGauge(&b, "powercheck_actuation_disabled", "1 if the disable-file was present and actuation was skipped (dry-run).", int64(m.actuationDisabled))
	if m.haveServer {
		writeGauge(&b, "powercheck_server_power_on", "1 if iDRAC reports PowerState=On, 0 if Off.", int64(m.serverOn))
	}
	if m.haveUPS {
		writeGauge(&b, "powercheck_ups_on_mains", "1 if UPS is on utility/mains power, 0 on battery.", int64(m.onMains))
		writeGauge(&b, "powercheck_ups_charge_percent", "UPS estimated battery charge remaining (percent).", m.chargePct)
		writeGauge(&b, "powercheck_ups_minutes_remaining", "UPS estimated runtime remaining (minutes).", m.minutesRemaining)
		writeGauge(&b, "powercheck_ups_seconds_on_battery", "Elapsed seconds on battery (0 on mains).", m.secondsOnBattery)
		writeGauge(&b, "powercheck_ups_battery_status", "UPS battery status (2=normal, 3=low, 0=unknown).", m.batteryStatus)
		writeGauge(&b, "powercheck_mains_stable_seconds", "Seconds mains has been continuously on-line (0 on battery).", m.mainsStableSecs)
	}
	writeGauge(&b, "powercheck_last_shutdown_attempt_timestamp_seconds", "Unix time of the last GracefulShutdown POST attempt (0=never).", m.lastShutdownAttempt)
	writeGauge(&b, "powercheck_last_shutdown_error", "1 if the last shutdown POST failed, 0 if it succeeded.", int64(m.lastShutdownError))
	writeGauge(&b, "powercheck_last_poweron_attempt_timestamp_seconds", "Unix time of the last power-On POST attempt (0=never).", m.lastPowerOnAttempt)
	writeGauge(&b, "powercheck_last_poweron_error", "1 if the last power-on POST failed, 0 if it succeeded.", int64(m.lastPowerOnError))

	url := strings.TrimRight(cfg.pushgatewayURL, "/") + "/metrics/job/powercheck"
	req, err := http.NewRequest(http.MethodPut, url, strings.NewReader(b.String()))
	if err != nil {
		glog.Warningf("pushgateway build request: %v", err)
		return
	}
	req.Header.Set("Content-Type", "text/plain")
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		glog.Warningf("pushgateway push failed (best-effort): %v", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		glog.Warningf("pushgateway push HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
		return
	}
	glog.Infof("Pushed watchdog metrics to %s", url)
}

func writeGauge(b *strings.Builder, name, help string, value int64) {
	fmt.Fprintf(b, "# HELP %s %s\n# TYPE %s gauge\n%s %d\n", name, help, name, name, value)
}

// ---- small helpers ----

func envStr(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func envInt(key string, def int64) int64 {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
		glog.Warningf("env %s=%q is not an integer; using default %d", key, v, def)
	}
	return def
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// tryGetLock is retained (currently unused) for a future single-flight guard.
func tryGetLock() (*lockfile.Lockfile, error) {
	lock, err := lockfile.New("/tmp/server_safe_poweroff.pid")
	if err != nil {
		log.Fatalf("Failed to create lock file: %v", err)
	}
	if err := lock.TryLock(); err != nil {
		return nil, err
	}
	return &lock, nil
}
