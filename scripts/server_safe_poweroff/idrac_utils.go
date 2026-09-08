package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/golang/glog"
)

type PowerStateResponse struct {
	PowerState string `json:"PowerState"`
}
type ResetType string

const (
	On               ResetType = "On"
	GracefulShutdown ResetType = "GracefulShutdown"
)

// idracHTTPClient trusts the iDRAC self-signed certificate (without
// InsecureSkipVerify the POST fails TLS verification — a latent bug alongside
// the wrong URL) and applies a hard timeout so a hung iDRAC cannot wedge the
// watchdog between its 10-minute runs.
func idracHTTPClient() *http.Client {
	return &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}
}

func checkPowerState(cred idracCredentials) (string, error) {
	redfishURL := fmt.Sprintf("%s/redfish/v1/Systems/System.Embedded.1", cred.url)

	req, err := http.NewRequest("GET", redfishURL, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create request: %v", err)
	}
	req.SetBasicAuth(cred.username, cred.password)
	req.Header.Set("Accept", "application/json")

	resp, err := idracHTTPClient().Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to send request: %v", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response body: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("unexpected status code: %d, response: %s", resp.StatusCode, string(body))
	}

	var psr PowerStateResponse
	if err := json.Unmarshal(body, &psr); err != nil {
		return "", fmt.Errorf("failed to parse JSON response: %v", err)
	}
	return psr.PowerState, nil
}

func performGracefulShutdown(cred idracCredentials) error {
	return performResetType(cred, GracefulShutdown)
}

func performPowerOn(cred idracCredentials) error {
	return performResetType(cred, On)
}

// performResetType POSTs a Redfish ComputerSystem.Reset action. The error is
// meaningful and MUST be checked by the caller (see main.go) — the 2026-07-18
// unclean shutdown was this returning an error into a bare `https://192.168.1.4`
// that main() then discarded.
func performResetType(cred idracCredentials, resetType ResetType) error {
	// The reset ACTION endpoint — NOT the iDRAC web root. POSTing to cred.url
	// hits the root and silently does nothing.
	resetURL := fmt.Sprintf("%s/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset", cred.url)
	glog.Warningf("Issuing Redfish reset %q to %s", resetType, resetURL)

	payloadBytes, err := json.Marshal(map[string]string{"ResetType": string(resetType)})
	if err != nil {
		return fmt.Errorf("failed to marshal payload: %v", err)
	}

	req, err := http.NewRequest("POST", resetURL, bytes.NewBuffer(payloadBytes))
	if err != nil {
		return fmt.Errorf("failed to create request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.SetBasicAuth(cred.username, cred.password)

	resp, err := idracHTTPClient().Do(req)
	if err != nil {
		return fmt.Errorf("reset %q POST failed: %v", resetType, err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	// Redfish reset actions return 200, 202 or 204 on success.
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusAccepted && resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("reset %q unexpected status %d: %s", resetType, resp.StatusCode, string(body))
	}
	glog.Warningf("Reset %q accepted by iDRAC (HTTP %d).", resetType, resp.StatusCode)
	return nil
}
