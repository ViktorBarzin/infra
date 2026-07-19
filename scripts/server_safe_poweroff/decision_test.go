package main

import "testing"

// ups builds a UPSPowerState for the decision tests. Only chargePercent and
// minutesRemaining drive the decision functions; the rest are set for realism.
func ups(chargePercent, minutesRemaining, secondsOnBattery, inputVoltage int) UPSPowerState {
	return UPSPowerState{
		inputVoltage:     inputVoltage,
		minutesRemaining: minutesRemaining,
		chargePercent:    chargePercent,
		secondsOnBattery: int64(secondsOnBattery),
		batteryStatus:    2,
	}
}

func (a powerAction) String() string {
	return [...]string{
		"None", "WaitOnBattery", "Shutdown",
		"HoldOnBattery", "HoldLowCharge", "HoldMainsUnstable", "PowerOn",
	}[a]
}

// TestDecideWhenOn simulates the shutdown-side algorithm (server is On).
func TestDecideWhenOn(t *testing.T) {
	const shutdownMin = 20
	cases := []struct {
		name    string
		ups     UPSPowerState
		onMains bool
		want    powerAction
	}{
		{"on mains — nothing to do", ups(100, 600, 0, 237), true, actNone},
		{"OUTAGE, plenty of runtime — wait", ups(90, 45, 120, 0), false, actWaitOnBattery},
		{"OUTAGE, runtime below threshold — SHUT DOWN", ups(30, 10, 900, 0), false, actShutdown},
		{"OUTAGE, runtime exactly at threshold — wait (>=)", ups(50, 20, 300, 0), false, actWaitOnBattery},
		{"OUTAGE, runtime one below threshold — SHUT DOWN", ups(45, 19, 400, 0), false, actShutdown},
	}
	for _, c := range cases {
		if got := decideWhenOn(c.ups, c.onMains, shutdownMin); got != c.want {
			t.Errorf("%s: decideWhenOn = %s, want %s", c.name, got, c.want)
		}
	}
}

// TestDecideWhenOff simulates the UPS-safe-gated power-on algorithm (server is Off).
func TestDecideWhenOff(t *testing.T) {
	const minCharge = 50
	const dwell int64 = 600
	cases := []struct {
		name        string
		ups         UPSPowerState
		onMains     bool
		mainsStable int64
		want        powerAction
	}{
		{"still on battery — do not power on", ups(80, 30, 300, 0), false, 0, actHoldOnBattery},
		{"mains back but charge too low — HOLD", ups(40, 20, 0, 237), true, 30, actHoldLowCharge},
		{"charge OK but mains just returned — HOLD (dwell)", ups(60, 40, 0, 237), true, 120, actHoldMainsUnstable},
		{"charge at threshold + dwell met — POWER ON", ups(50, 30, 0, 237), true, 600, actPowerOn},
		{"fully recovered — POWER ON", ups(100, 600, 0, 237), true, 3600, actPowerOn},
	}
	for _, c := range cases {
		if got := decideWhenOff(c.ups, c.onMains, c.mainsStable, minCharge, dwell); got != c.want {
			t.Errorf("%s: decideWhenOff = %s, want %s", c.name, got, c.want)
		}
	}
}

// TestPowerCycleLoopPrevention simulates the exact 2026-07-19 concern: repeated
// SHORT outages where the UPS never recharges must NOT let the host power-cycle
// in a loop. Every brief mains return with a still-depleted battery (or too
// little dwell) must HOLD; only a genuinely recovered UPS + stable mains powers on.
func TestPowerCycleLoopPrevention(t *testing.T) {
	const minCharge = 50
	const dwell int64 = 600

	steps := []struct {
		name        string
		ups         UPSPowerState
		mainsStable int64
		want        powerAction
	}{
		{"outage 1 ends, mains back 30s, battery 20% (not recharged)", ups(20, 8, 0, 237), 30, actHoldLowCharge},
		{"mains stable 15m but battery only 45% (still recharging)", ups(45, 22, 0, 237), 900, actHoldLowCharge},
		{"battery 60% but mains only stable 2m", ups(60, 35, 0, 237), 120, actHoldMainsUnstable},
		{"battery 60% AND mains stable 12m — safe to power on", ups(60, 35, 0, 237), 720, actPowerOn},
	}
	for _, s := range steps {
		got := decideWhenOff(s.ups, true, s.mainsStable, minCharge, dwell)
		if got != s.want {
			t.Fatalf("power-cycle-loop step %q: got %s, want %s", s.name, got, s.want)
		}
	}
}
