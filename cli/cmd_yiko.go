package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// `ha yiko` drives Yiko, the Ecovacs robot vacuum in the London flat, through
// HA London. It is a deliberate exception to ADR-0012 (no entity control in
// the CLI): Viktor asked on 2026-11-14 for one easy way for agents to control
// it. The verbs encode the procedure that is otherwise re-derived each time:
// the raw freeClean command HA's own spot_area cannot send on this firmware,
// how to tell that a job started (sensor.yiko_area_cleaned changes), and which
// photos belong to this run (Last-Modified at or after the script's trigger).
// The photo itself is the HA script script.yiko_photo; see
// docs/runbooks/london-yiko.md.

const (
	haLondonURL      = "https://ha-london.viktorbarzin.me"
	yikoVacuum       = "vacuum.yiko"
	yikoPhotoScript  = "script.yiko_photo"
	yikoAreaSensor   = "sensor.yiko_area_cleaned"
	yikoMaxShots     = 15
	yikoDefaultShots = 6
	yikoUsageText    = "usage: homelab ha yiko status [--json] | photo <room> [--shots N] [--out DIR] [--json] | clean <room> | dock"
)

// Poll interval and timeouts, variables so tests can shrink them.
var (
	yikoPoll         = 5 * time.Second
	yikoStartTimeout = 60 * time.Second // a job or run must visibly start within this
	yikoRunTimeout   = 8 * time.Minute  // the photo script takes about 2.5 min
)

func yikoCommands() []Command {
	return []Command{
		{Path: []string{"ha", "yiko", "status"}, Tier: TierRead,
			Summary: "London robot vacuum Yiko: state, battery, camera, photo script: ha yiko status [--json]", Run: yikoStatusCmd},
		{Path: []string{"ha", "yiko", "photo"}, Tier: TierWrite,
			Summary: "send Yiko to a room, take photos, download them: ha yiko photo <room> [--shots N] [--out DIR] [--json] [--night]", Run: yikoPhotoCmd},
		{Path: []string{"ha", "yiko", "clean"}, Tier: TierWrite,
			Summary: "start a clean of one room in the current work mode: ha yiko clean <room> [--night]", Run: yikoCleanCmd},
		{Path: []string{"ha", "yiko", "dock"}, Tier: TierWrite,
			Summary: "stop Yiko's job and send it to the dock: ha yiko dock", Run: yikoDockCmd},
	}
}

// haAPI is a small Home Assistant REST client.
type haAPI struct {
	base  string
	token string
	hc    *http.Client
}

type haEntityState struct {
	EntityID    string         `json:"entity_id"`
	State       string         `json:"state"`
	Attributes  map[string]any `json:"attributes"`
	LastChanged string         `json:"last_changed"`
}

// newYikoAPI resolves the HA London token from the cluster, like `ha token`.
var newYikoAPI = func() (haAPI, error) {
	inst, err := resolveHAInstance("london")
	if err != nil {
		return haAPI{}, err
	}
	tok, err := haTokenFor(inst)
	if err != nil {
		return haAPI{}, err
	}
	return haAPI{base: haLondonURL, token: tok, hc: &http.Client{Timeout: 30 * time.Second}}, nil
}

func (h haAPI) do(method, path string, body any) (*http.Response, error) {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, h.base+path, rd)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+h.token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return h.hc.Do(req)
}

func (h haAPI) state(entity string) (haEntityState, error) {
	resp, err := h.do(http.MethodGet, "/api/states/"+entity, nil)
	if err != nil {
		return haEntityState{}, fmt.Errorf("read %s: %w", entity, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return haEntityState{}, fmt.Errorf("read %s: HTTP %d", entity, resp.StatusCode)
	}
	var st haEntityState
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		return haEntityState{}, fmt.Errorf("decode %s: %w", entity, err)
	}
	return st, nil
}

func (h haAPI) call(domain, service string, body map[string]any) error {
	resp, err := h.do(http.MethodPost, "/api/services/"+domain+"/"+service, body)
	if err != nil {
		return fmt.Errorf("call %s.%s: %w", domain, service, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
		return fmt.Errorf("call %s.%s: HTTP %d %s", domain, service, resp.StatusCode, strings.TrimSpace(string(msg)))
	}
	return nil
}

// media fetches a file under HA's /media folder and its Last-Modified time.
// ok is false when the file does not exist.
func (h haAPI) media(rel string) (data []byte, modified time.Time, ok bool, err error) {
	resp, err := h.do(http.MethodGet, "/media/local/"+rel, nil)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, time.Time{}, false, nil
	}
	if resp.StatusCode != http.StatusOK {
		return nil, time.Time{}, false, fmt.Errorf("fetch /media/%s: HTTP %d", rel, resp.StatusCode)
	}
	data, err = io.ReadAll(resp.Body)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	modified, err = http.ParseTime(resp.Header.Get("Last-Modified"))
	if err != nil {
		return nil, time.Time{}, false, fmt.Errorf("fetch /media/%s: no usable Last-Modified header", rel)
	}
	return data, modified, true, nil
}

type yikoOpts struct {
	room  string
	shots int
	out   string
	json  bool
	night bool
}

// yikoNow is the clock, a variable so tests can set the time.
var yikoNow = time.Now

// yikoQuietHours is 22:00-08:00 London time, the same window as the
// do-not-disturb block set on the robot (getBlock start 22:0, end 8:0).
// People sleep in the flat then, and the camera lights Yiko's headlights.
func yikoQuietHours(t time.Time) bool {
	h := t.In(londonLoc()).Hour()
	return h >= 22 || h < 8
}

// yikoCheckHours refuses a moving verb in quiet hours unless --night is set.
func yikoCheckHours(o yikoOpts) error {
	if o.night || !yikoQuietHours(yikoNow()) {
		return nil
	}
	return fmt.Errorf("it is %s in London, inside Yiko's quiet hours (22:00-08:00), and people may be asleep. "+
		"Ask Viktor first, then add --night", yikoNow().In(londonLoc()).Format("15:04"))
}

func londonLoc() *time.Location {
	if loc, err := time.LoadLocation("Europe/London"); err == nil {
		return loc
	}
	return time.UTC
}

// parseYikoArgs fails closed: unknown flags, extra positionals and --help are
// errors, so a typo never runs the robot with defaults.
func parseYikoArgs(verb string, args []string) (yikoOpts, error) {
	o := yikoOpts{shots: yikoDefaultShots}
	takesRoom := verb == "photo" || verb == "clean"
	value := func(i int, flag string) (string, error) {
		if i+1 >= len(args) {
			return "", fmt.Errorf("%s needs a value; %s", flag, yikoUsageText)
		}
		return args[i+1], nil
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-h" || a == "--help":
			return o, fmt.Errorf("%s", yikoUsageText)
		case a == "--json" && (verb == "photo" || verb == "status"):
			o.json = true
		case a == "--night" && takesRoom:
			o.night = true
		case a == "--shots" && verb == "photo":
			v, err := value(i, a)
			if err != nil {
				return o, err
			}
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 || n > yikoMaxShots {
				return o, fmt.Errorf("--shots must be 1-%d, got %q", yikoMaxShots, v)
			}
			o.shots = n
			i++
		case a == "--out" && verb == "photo":
			v, err := value(i, a)
			if err != nil {
				return o, err
			}
			o.out = v
			i++
		case strings.HasPrefix(a, "-"):
			return o, fmt.Errorf("unknown flag %q for `ha yiko %s`; %s", a, verb, yikoUsageText)
		case takesRoom && o.room == "":
			o.room = a
		default:
			return o, fmt.Errorf("unexpected argument %q for `ha yiko %s`; %s", a, verb, yikoUsageText)
		}
	}
	if takesRoom && o.room == "" {
		return o, fmt.Errorf("ha yiko %s needs a room; %s", verb, yikoUsageText)
	}
	return o, nil
}

// yikoRoomID reads the room id from vacuum.yiko's rooms attribute. A name can
// map to a list of ids when two rooms share it; the first one is used.
func yikoRoomID(api haAPI, room string) (int, error) {
	st, err := api.state(yikoVacuum)
	if err != nil {
		return 0, err
	}
	rooms, _ := st.Attributes["rooms"].(map[string]any)
	var names []string
	for name := range rooms {
		if name != "" {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	v, ok := rooms[room]
	if !ok || room == "" {
		return 0, fmt.Errorf("unknown room %q; Yiko's map has: %s", room, strings.Join(names, ", "))
	}
	if list, isList := v.([]any); isList && len(list) > 0 {
		v = list[0]
	}
	f, isNum := v.(float64)
	if !isNum {
		if i, isInt := v.(int); isInt {
			return i, nil
		}
		return 0, fmt.Errorf("room %q has an unexpected id %v", room, v)
	}
	return int(f), nil
}

// waitFor polls cond until it returns true, an error, or the timeout passes.
func waitFor(timeout time.Duration, cond func() (bool, error)) (bool, error) {
	deadline := time.Now().Add(timeout)
	for {
		ok, err := cond()
		if err != nil || ok {
			return ok, err
		}
		if time.Now().After(deadline) {
			return false, nil
		}
		time.Sleep(yikoPoll)
	}
}

func yikoClean(api haAPI, room string) error {
	id, err := yikoRoomID(api, room)
	if err != nil {
		return err
	}
	if err := yikoPreflight(api, true); err != nil {
		return err
	}
	before, err := api.state(yikoAreaSensor)
	if err != nil {
		return err
	}
	// The params go as JSON, so value stays the string "1,<id>". The robot
	// answers 20011 to HA's spot_area (spotArea type) on firmware 1.134.0.
	err = api.call("vacuum", "send_command", map[string]any{
		"entity_id": yikoVacuum,
		"command":   "clean_V2",
		"params": map[string]any{"act": "start",
			"content": map[string]any{"type": "freeClean", "value": fmt.Sprintf("1,%d", id)}},
	})
	if err != nil {
		return err
	}
	// A new job resets the area counter to 0, which changes last_changed.
	started, err := waitFor(yikoStartTimeout, func() (bool, error) {
		st, err := api.state(yikoAreaSensor)
		return err == nil && st.LastChanged != before.LastChanged, err
	})
	if err != nil {
		return err
	}
	if !started {
		return fmt.Errorf("Yiko did not start the %s job within %s. If it has just docked it empties its bin first: wait 30 s and retry", room, yikoStartTimeout)
	}
	return nil
}

func yikoDock(api haAPI) error {
	err := api.call("vacuum", "send_command", map[string]any{
		"entity_id": yikoVacuum, "command": "clean_V2",
		"params": map[string]any{"act": "stop", "content": map[string]any{"type": ""}},
	})
	if err != nil {
		return err
	}
	return api.call("vacuum", "return_to_base", map[string]any{"entity_id": yikoVacuum})
}

type yikoPhotoResult struct {
	Room  string   `json:"room"`
	Files []string `json:"files"`
}

func yikoPhoto(api haAPI, o yikoOpts) (yikoPhotoResult, error) {
	res := yikoPhotoResult{Room: o.room, Files: []string{}}
	before, err := api.state(yikoPhotoScript)
	if err != nil {
		return res, err
	}
	if before.State == "on" {
		return res, fmt.Errorf("%s is already running; wait for it to finish", yikoPhotoScript)
	}
	if _, err := yikoRoomID(api, o.room); err != nil {
		return res, err
	}
	if err := yikoPreflight(api, false); err != nil {
		return res, err
	}
	// The script starts the camera once and sends start, pause/resume per
	// photo, stop and dock: count them against the same hourly budgets.
	if err := yikoTakeBudget(yikoBudgetPath(), "camera start", 1, yikoCameraBudget, time.Now()); err != nil {
		return res, err
	}
	if err := yikoTakeBudget(yikoBudgetPath(), "move", 2*o.shots+3, yikoMoveBudget, time.Now()); err != nil {
		return res, err
	}
	prevTrigger, _ := before.Attributes["last_triggered"].(string)
	err = api.call("script", "turn_on", map[string]any{
		"entity_id": yikoPhotoScript,
		"variables": map[string]any{"room": o.room, "shots": o.shots},
	})
	if err != nil {
		return res, err
	}
	var trigger string
	started, err := waitFor(yikoStartTimeout, func() (bool, error) {
		st, err := api.state(yikoPhotoScript)
		if err != nil {
			return false, err
		}
		trigger, _ = st.Attributes["last_triggered"].(string)
		return trigger != "" && trigger != prevTrigger, nil
	})
	if err != nil {
		return res, err
	}
	if !started {
		return res, fmt.Errorf("%s did not start within %s", yikoPhotoScript, yikoStartTimeout)
	}
	done, err := waitFor(yikoRunTimeout, func() (bool, error) {
		st, err := api.state(yikoPhotoScript)
		return err == nil && st.State == "off", err
	})
	if err != nil {
		return res, err
	}
	if !done {
		return res, fmt.Errorf("%s still running after %s", yikoPhotoScript, yikoRunTimeout)
	}
	// Photos written by this run are at or after the trigger time, both on
	// HA's clock. Last-Modified has whole seconds, so truncate the trigger.
	runAt, err := time.Parse(time.RFC3339Nano, trigger)
	if err != nil {
		return res, fmt.Errorf("parse last_triggered %q: %w", trigger, err)
	}
	runAt = runAt.Truncate(time.Second)
	out := o.out
	if out == "" {
		home, _ := os.UserHomeDir()
		out = filepath.Join(home, "pictures", "yiko", o.room+"-"+time.Now().Format("20060102-150405"))
	}
	for n := 1; n <= o.shots; n++ {
		name := fmt.Sprintf("%s-%d.jpg", o.room, n)
		data, mod, ok, err := api.media("yiko/" + name)
		if err != nil {
			return res, err
		}
		if !ok || mod.Before(runAt) {
			continue
		}
		if err := os.MkdirAll(out, 0o755); err != nil {
			return res, err
		}
		path := filepath.Join(out, name)
		if err := os.WriteFile(path, data, 0o644); err != nil {
			return res, err
		}
		res.Files = append(res.Files, path)
	}
	if len(res.Files) == 0 {
		return res, fmt.Errorf("no new photos: Yiko did not reach the %s or the camera did not start. "+
			"The run's trace in HA (script.yiko_photo, Traces) shows job_started, arrived and camera_ready", o.room)
	}
	return res, nil
}

func yikoStatus(api haAPI) (map[string]string, error) {
	fields := []struct{ key, entity string }{
		{"vacuum", yikoVacuum},
		{"battery", "sensor.yiko_battery"},
		{"station", "sensor.yiko_station_state"},
		{"work_mode", "select.yiko_work_mode"},
		{"area_cleaned_m2", yikoAreaSensor},
		{"camera", "input_boolean.yiko_camera"},
		{"camera_ready", "binary_sensor.yiko_camera_ready"},
		{"photo_script", yikoPhotoScript},
	}
	st := map[string]string{}
	for _, f := range fields {
		s, err := api.state(f.entity)
		if err != nil {
			return nil, err
		}
		st[f.key] = s.State
	}
	return st, nil
}

func yikoAPIAndOpts(verb string, args []string) (haAPI, yikoOpts, error) {
	o, err := parseYikoArgs(verb, args)
	if err != nil {
		return haAPI{}, o, err
	}
	if verb == "photo" || verb == "clean" {
		if err := yikoCheckHours(o); err != nil {
			return haAPI{}, o, err
		}
	}
	api, err := newYikoAPI()
	return api, o, err
}

func yikoStatusCmd(args []string) error {
	api, o, err := yikoAPIAndOpts("status", args)
	if err != nil {
		return err
	}
	st, err := yikoStatus(api)
	if err != nil {
		return err
	}
	if o.json {
		b, _ := json.MarshalIndent(st, "", "  ")
		fmt.Println(string(b))
		return nil
	}
	keys := make([]string, 0, len(st))
	for k := range st {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Printf("%-16s %s\n", k, st[k])
	}
	fmt.Println("note: during a room job HA can still show the vacuum as docked or idle; area_cleaned_m2 counting up is the live signal")
	return nil
}

func yikoPhotoCmd(args []string) error {
	api, o, err := yikoAPIAndOpts("photo", args)
	if err != nil {
		return err
	}
	if !o.json {
		fmt.Fprintf(os.Stderr, "Yiko is going to the %s for %d photos; this takes about 2-3 minutes...\n", o.room, o.shots)
	}
	res, err := yikoPhoto(api, o)
	if err != nil {
		return err
	}
	if o.json {
		b, _ := json.MarshalIndent(res, "", "  ")
		fmt.Println(string(b))
		return nil
	}
	for _, f := range res.Files {
		fmt.Println(f)
	}
	fmt.Fprintln(os.Stderr, "Yiko is going back to the dock. Look at every photo: its heading at each stop is random.")
	return nil
}

func yikoCleanCmd(args []string) error {
	api, o, err := yikoAPIAndOpts("clean", args)
	if err != nil {
		return err
	}
	if err := yikoClean(api, o.room); err != nil {
		return err
	}
	fmt.Printf("Yiko started cleaning the %s (work mode unchanged). Stop it with: homelab ha yiko dock\n", o.room)
	return nil
}

func yikoDockCmd(args []string) error {
	api, _, err := yikoAPIAndOpts("dock", args)
	if err != nil {
		return err
	}
	if err := yikoDock(api); err != nil {
		return err
	}
	fmt.Println("Yiko stopped its job and is going back to the dock.")
	return nil
}
