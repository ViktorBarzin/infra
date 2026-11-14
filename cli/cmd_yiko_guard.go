package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// Guardrails for driving Yiko, added on 2026-11-14 at Viktor's request: do
// not break the robot, and do not get the Ecovacs account flagged.
//
// Robot: refuse to move below 20% battery or while the robot reports an
// error, refuse manual moves while the photo script drives it, and arm HA's
// script.yiko_auto_dock before every manual move, which sends Yiko home 15
// minutes after the last one unless it started cleaning.
//
// Account: Ecovacs publishes no limits, so stay near what one person with the
// app does. Holding the app's joystick sends a command every 3 s (20 a
// minute); the budget is 120 move commands an hour. Each camera start is a
// new Ecovacs login by the bridge; the budget is 10 an hour. Budgets are per
// devvm user, in the user's cache folder.

const (
	yikoMinBattery     = 20
	yikoMoveBudget     = 120 // move commands per hour
	yikoCameraBudget   = 10  // camera starts per hour
	yikoAutoDockScript = "script.yiko_auto_dock"
)

// yikoBudgetPath is the budget file, a variable so tests can use a temp dir.
var yikoBudgetPath = func() string {
	dir, err := os.UserCacheDir()
	if err != nil {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "homelab", "yiko-budget.json")
}

// yikoPreflight refuses a move that could strand or strain the robot.
// needIdle also refuses while script.yiko_photo is driving it.
func yikoPreflight(api haAPI, needIdle bool) error {
	bat, err := api.state("sensor.yiko_battery")
	if err != nil {
		return err
	}
	if n, convErr := strconv.Atoi(bat.State); convErr == nil && n < yikoMinBattery {
		return fmt.Errorf("Yiko's battery is at %d%%, under %d%%: send it to charge (homelab ha yiko dock) instead of driving it", n, yikoMinBattery)
	}
	e, err := api.state("sensor.yiko_error")
	if err != nil {
		return err
	}
	if e.State != "0" && e.State != "unknown" && e.State != "unavailable" && e.State != "" {
		desc, _ := e.Attributes["description"].(string)
		return fmt.Errorf("Yiko reports error %s (%s): fix that first; moving a stuck robot can strain its wheels", e.State, desc)
	}
	if needIdle {
		s, err := api.state(yikoPhotoScript)
		if err != nil {
			return err
		}
		if s.State == "on" {
			return fmt.Errorf("%s is driving Yiko right now; wait for it to finish", yikoPhotoScript)
		}
	}
	return nil
}

type yikoBudgetFile map[string][]int64 // kind -> unix times of recent uses

// yikoTakeBudget records n uses of kind at now, or fails if that would pass
// limit uses within the last hour. Nothing is recorded on failure.
func yikoTakeBudget(path, kind string, n, limit int, now time.Time) error {
	b := yikoBudgetFile{}
	raw, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &b); err != nil {
			b = yikoBudgetFile{} // a corrupt file only resets the budget
		}
	}
	cutoff := now.Add(-time.Hour).Unix()
	for k, ts := range b {
		kept := ts[:0]
		for _, t := range ts {
			if t > cutoff {
				kept = append(kept, t)
			}
		}
		b[k] = kept
	}
	if len(b[kind])+n > limit {
		wait := time.Unix(b[kind][0], 0).Add(time.Hour).Sub(now).Round(time.Minute)
		return fmt.Errorf("Yiko %s limit reached: %d in the last hour (limit %d), to stay near what one person with the Ecovacs app sends. Try again in about %s",
			kind, len(b[kind]), limit, wait)
	}
	for i := 0; i < n; i++ {
		b[kind] = append(b[kind], now.Unix())
	}
	out, err := json.Marshal(b)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, out, 0o600)
}

// yikoMoveCount is the number of commands yikoMove sends: start and stop per chunk.
func yikoMoveCount(d yikoDrive) int {
	chunk := d.chunk
	if chunk <= 0 {
		chunk = d.dur
	}
	chunks := int((d.dur + chunk - 1) / chunk)
	return 2 * chunks
}

// yikoManual runs a drive or turn with every guard: preflight, budget, and
// the auto-dock dead-man armed before the first wheel turns.
func yikoManual(api haAPI, d yikoDrive) error {
	if err := yikoPreflight(api, true); err != nil {
		return err
	}
	if err := yikoTakeBudget(yikoBudgetPath(), "move", yikoMoveCount(d), yikoMoveBudget, time.Now()); err != nil {
		return err
	}
	if err := api.call("script", "turn_on", map[string]any{"entity_id": yikoAutoDockScript}); err != nil {
		return fmt.Errorf("could not arm %s, so not moving: %w", yikoAutoDockScript, err)
	}
	return yikoMove(api, d)
}
