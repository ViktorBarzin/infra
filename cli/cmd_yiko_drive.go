package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Manual driving of Yiko, the same way the Ecovacs app's joystick does it.
// The app (com.eco.global.app 3.17, common_video_manager Move) sends the raw
// command `move` with {"act": <dir>, "a": 0} for forward/backward and
// {"act": "spinLeft"|"spinRight", "a": 90} for turns, re-sends it every 3 s
// while the button is held, and sends {"act": "stop"} on release. `a` is not
// an angle: a=10 and a=30 turned as far as a=90, and a>90 is ignored
// (turnLeft/turnRight are U-turns). Speeds measured on 2026-11-14 in the
// London flat: about 20 cm/s forward, and 40-57 deg/s turning across runs,
// because start and stop each cross HA and the Ecovacs cloud; 50 deg/s is
// used, so a turn lands within about 25 deg. Re-sending a spin while it turns
// cut a 180 deg turn to about 100 deg, and a new spin 0.4 s after a stop was
// ignored, so long moves run as start-wait-stop chunks 1.5 s apart. The robot
// stops by itself at obstacles. See docs/runbooks/london-yiko.md.

const (
	yikoCmPerSec      = 20.0
	yikoDegPerSec     = 50.0
	yikoMaxCm         = 300
	yikoDriveChunk    = 2500 * time.Millisecond // longest straight run per command
	yikoChunkPause    = 1500 * time.Millisecond // the robot ignored a new spin 0.4 s after a stop
	yikoDriveUsage    = "usage: homelab ha yiko drive forward|backward <cm> [--night] | turn left|right [deg] [--night] | stop | look [--out FILE] [--night]"
	yikoCameraEntity  = "camera.yiko"
	yikoCameraSwitch  = "input_boolean.yiko_camera"
	yikoCameraReadyID = "binary_sensor.yiko_camera_ready"
)

// yikoSleep is time.Sleep, a variable so tests can record the waits.
var yikoSleep = time.Sleep

func yikoDriveCommands() []Command {
	return []Command{
		{Path: []string{"ha", "yiko", "drive"}, Tier: TierWrite,
			Summary: "drive Yiko straight without cleaning, ~20 cm/s: ha yiko drive forward|backward <cm> [--night]", Run: yikoDriveCmd},
		{Path: []string{"ha", "yiko", "turn"}, Tier: TierWrite,
			Summary: "turn Yiko on the spot, about +-25 deg: ha yiko turn left|right [deg, default 90] [--night]", Run: yikoTurnCmd},
		{Path: []string{"ha", "yiko", "stop"}, Tier: TierWrite,
			Summary: "stop Yiko's wheels now: ha yiko stop", Run: yikoStopCmd},
		{Path: []string{"ha", "yiko", "look"}, Tier: TierWrite,
			Summary: "photo from Yiko's camera where it is now (turns the camera on): ha yiko look [--out FILE] [--night]", Run: yikoLookCmd},
	}
}

type yikoDrive struct {
	act   string
	a     int
	dur   time.Duration
	chunk time.Duration // longest single start-wait-stop run
	night bool
	out   string
}

// parseYikoDrive reads drive/turn/look args and fails closed on anything else.
func parseYikoDrive(verb string, args []string) (yikoDrive, error) {
	var d yikoDrive
	var pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-h" || a == "--help":
			return d, fmt.Errorf("%s", yikoDriveUsage)
		case a == "--night" && verb != "stop":
			d.night = true
		case a == "--out" && verb == "look":
			if i+1 >= len(args) {
				return d, fmt.Errorf("--out needs a value; %s", yikoDriveUsage)
			}
			d.out = args[i+1]
			i++
		case strings.HasPrefix(a, "-"):
			return d, fmt.Errorf("unknown flag %q for `ha yiko %s`; %s", a, verb, yikoDriveUsage)
		default:
			pos = append(pos, a)
		}
	}
	number := func(s string, lo, hi int, what string) (int, error) {
		n, err := strconv.Atoi(s)
		if err != nil || n < lo || n > hi {
			return 0, fmt.Errorf("%s must be %d-%d, got %q", what, lo, hi, s)
		}
		return n, nil
	}
	switch verb {
	case "drive":
		if len(pos) != 2 || (pos[0] != "forward" && pos[0] != "backward") {
			return d, fmt.Errorf("ha yiko drive needs forward|backward and a distance in cm; %s", yikoDriveUsage)
		}
		cm, err := number(pos[1], 1, yikoMaxCm, "distance (cm)")
		if err != nil {
			return d, err
		}
		d.act, d.a = pos[0], 0
		d.dur = time.Duration(float64(cm) / yikoCmPerSec * float64(time.Second))
		d.chunk = yikoDriveChunk
	case "turn":
		if len(pos) < 1 || len(pos) > 2 || (pos[0] != "left" && pos[0] != "right") {
			return d, fmt.Errorf("ha yiko turn needs left|right and optional degrees; %s", yikoDriveUsage)
		}
		deg := 90
		if len(pos) == 2 {
			n, err := number(pos[1], 1, 360, "angle (deg)")
			if err != nil {
				return d, err
			}
			deg = n
		}
		d.act = map[string]string{"left": "spinLeft", "right": "spinRight"}[pos[0]]
		d.a = 90
		d.dur = time.Duration(float64(deg) / yikoDegPerSec * float64(time.Second)).Round(time.Millisecond)
		quarter := 90.0 // one 90 deg turn per chunk
		d.chunk = time.Duration(quarter / yikoDegPerSec * float64(time.Second)).Round(time.Millisecond)
	case "stop", "look":
		if len(pos) != 0 {
			return d, fmt.Errorf("unexpected argument %q for `ha yiko %s`; %s", pos[0], verb, yikoDriveUsage)
		}
	}
	return d, nil
}

func yikoSendMove(api haAPI, params map[string]any) error {
	return api.call("vacuum", "send_command", map[string]any{
		"entity_id": yikoVacuum, "command": "move", "params": params,
	})
}

func yikoStop(api haAPI) error {
	return yikoSendMove(api, map[string]any{"act": "stop"})
}

// yikoMove runs a direction for d.dur as start-wait-stop chunks of at most
// d.chunk. A failed send still tries to stop the wheels.
func yikoMove(api haAPI, d yikoDrive) error {
	chunk := d.chunk
	if chunk <= 0 {
		chunk = d.dur
	}
	for left := d.dur; left > 0; {
		step := left
		if step > chunk {
			step = chunk
		}
		if err := yikoSendMove(api, map[string]any{"act": d.act, "a": d.a}); err != nil {
			_ = yikoStop(api)
			return err
		}
		yikoSleep(step)
		if err := yikoStop(api); err != nil {
			return err
		}
		left -= step
		if left > 0 {
			yikoSleep(yikoChunkPause)
		}
	}
	return nil
}

// yikoLook turns the camera on if needed, waits for the stream, and saves one
// frame. The robot refuses video while it is idle on the dock.
func yikoLook(api haAPI, out string) (string, error) {
	ready, err := api.state(yikoCameraReadyID)
	if err != nil {
		return "", err
	}
	if ready.State != "on" {
		if err := yikoCameraStart(api); err != nil {
			return "", err
		}
	}
	img, err := yikoSnapshot(api)
	if err != nil {
		// HA switches the camera off after 10 min, and the ready sensor can
		// still say on for a while: restart the camera once and retry.
		if err := api.call("input_boolean", "turn_off", map[string]any{"entity_id": yikoCameraSwitch}); err != nil {
			return "", err
		}
		yikoSleep(2 * time.Second)
		if err := yikoCameraStart(api); err != nil {
			return "", err
		}
		if img, err = yikoSnapshot(api); err != nil {
			return "", err
		}
	}
	if out == "" {
		home, _ := os.UserHomeDir()
		out = filepath.Join(home, "pictures", "yiko", "look-"+time.Now().Format("20060102-150405")+".jpg")
	}
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return "", err
	}
	return out, os.WriteFile(out, img, 0o644)
}

// yikoCameraStart turns the camera on and waits for the stream.
func yikoCameraStart(api haAPI) error {
	if err := yikoTakeBudget(yikoBudgetPath(), "camera start", 1, yikoCameraBudget, time.Now()); err != nil {
		return err
	}
	if err := api.call("input_boolean", "turn_on", map[string]any{"entity_id": yikoCameraSwitch}); err != nil {
		return err
	}
	ok, err := waitFor(3*yikoStartTimeout, func() (bool, error) {
		st, err := api.state(yikoCameraReadyID)
		return err == nil && st.State == "on", err
	})
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("the camera did not start within %s. Yiko refuses video while it sits idle on the dock: "+
			"drive it off first (homelab ha yiko drive forward 30) and run look again", 3*yikoStartTimeout)
	}
	return nil
}

func yikoSnapshot(api haAPI) ([]byte, error) {
	resp, err := api.do(http.MethodGet, "/api/camera_proxy/"+yikoCameraEntity, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("camera snapshot: HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

func yikoDriveSetup(verb string, args []string) (haAPI, yikoDrive, error) {
	d, err := parseYikoDrive(verb, args)
	if err != nil {
		return haAPI{}, d, err
	}
	if verb != "stop" {
		if err := yikoCheckHours(yikoOpts{night: d.night}); err != nil {
			return haAPI{}, d, err
		}
	}
	api, err := newYikoAPI()
	return api, d, err
}

func yikoDriveCmd(args []string) error {
	api, d, err := yikoDriveSetup("drive", args)
	if err != nil {
		return err
	}
	if err := yikoManual(api, d); err != nil {
		return err
	}
	fmt.Printf("Yiko drove %s for %.1f s (about %.0f cm unless something blocked it). See where it is: homelab ha yiko look\n",
		d.act, d.dur.Seconds(), d.dur.Seconds()*yikoCmPerSec)
	return nil
}

func yikoTurnCmd(args []string) error {
	api, d, err := yikoDriveSetup("turn", args)
	if err != nil {
		return err
	}
	if err := yikoManual(api, d); err != nil {
		return err
	}
	fmt.Printf("Yiko turned %s for %.1f s (about %.0f deg, +-25). See where it faces: homelab ha yiko look\n",
		strings.TrimPrefix(d.act, "spin"), d.dur.Seconds(), d.dur.Seconds()*yikoDegPerSec)
	return nil
}

func yikoStopCmd(args []string) error {
	api, _, err := yikoDriveSetup("stop", args)
	if err != nil {
		return err
	}
	if err := yikoStop(api); err != nil {
		return err
	}
	fmt.Println("Yiko stopped.")
	return nil
}

func yikoLookCmd(args []string) error {
	api, d, err := yikoDriveSetup("look", args)
	if err != nil {
		return err
	}
	path, err := yikoLook(api, d.out)
	if err != nil {
		return err
	}
	fmt.Println(path)
	return nil
}
