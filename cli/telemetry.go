package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// usageJob is the Loki stream job label for homelab usage telemetry.
const usageJob = "homelab-usage"

// emitUsage best-effort records one verb invocation to Loki for cross-user
// usage analytics. Labels are low-cardinality (job/user/verb); the line carries
// only exit code + CLI version. NEVER args, paths, flags, or secrets. It must
// never affect the command: all errors are swallowed and a tight timeout bounds
// the cost. Opt out with HOMELAB_TELEMETRY=0.
func emitUsage(verb string, runErr error) {
	switch os.Getenv("HOMELAB_TELEMETRY") {
	case "0", "off", "false", "no":
		return
	}
	if verb == "" || strings.HasPrefix(verb, "usage") {
		return // don't self-record the analytics reader
	}
	exit := 0
	if runErr != nil {
		exit = 1
	}
	body, err := json.Marshal(lokiPush{Streams: []lokiStream{{
		Stream: map[string]string{"job": usageJob, "user": currentUser(), "verb": verb},
		Values: [][2]string{{
			strconv.FormatInt(time.Now().UnixNano(), 10),
			"exit=" + strconv.Itoa(exit) + " ver=" + version,
		}},
	}}})
	if err != nil {
		return
	}
	req, err := http.NewRequest("POST", "https://"+lokiHost+"/loki/api/v1/push", bytes.NewReader(body))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := clientDialingIP(internalLBIP, 800*time.Millisecond).Do(req)
	if err != nil {
		return
	}
	resp.Body.Close()
}

type lokiPush struct {
	Streams []lokiStream `json:"streams"`
}

type lokiStream struct {
	Stream map[string]string `json:"stream"`
	Values [][2]string       `json:"values"`
}
