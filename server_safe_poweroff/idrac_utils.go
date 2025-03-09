package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"net/http"

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

func checkPowerState(idractCredentials idracCredentials) (string, error) {
	// Construct the full URL for the Redfish Systems endpoint
	redfishURL := fmt.Sprintf("%s/redfish/v1/Systems/System.Embedded.1", idractCredentials.url)

	// Create an HTTP client
	client := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	// Create a new GET request
	req, err := http.NewRequest("GET", redfishURL, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create request: %v", err)
	}

	// Set basic authentication
	req.SetBasicAuth(idractCredentials.username, idractCredentials.password)

	// Set the Accept header to request JSON
	req.Header.Set("Accept", "application/json")

	// Send the request
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to send request: %v", err)
	}
	defer resp.Body.Close()

	// Check the HTTP status code
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("unexpected status code: %d, response: %s", resp.StatusCode, string(body))
	}

	// Read the response body
	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response body: %v", err)
	}

	// return string(body), nil
	// Parse the JSON response
	var powerStateResponse PowerStateResponse
	err = json.Unmarshal(body, &powerStateResponse)
	if err != nil {
		return "", fmt.Errorf("failed to parse JSON response: %v", err)
	}

	// Return the power state
	return powerStateResponse.PowerState, nil
}

func performGracefulShutdown(idracCredentials idracCredentials) error {
	return performResetType(idracCredentials, GracefulShutdown)
}

func performPowerOn(idracCredentials idracCredentials) error {
	return performResetType(idracCredentials, On)
}

func performResetType(idracCredentials idracCredentials, resetType ResetType) error {
	glog.Warningf("Starting graceful reset type %s!\n", resetType)
	// Define the payload for the shutdown request
	payload := map[string]string{
		"ResetType": string(resetType), // Only ResetType is needed
	}
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("failed to marshal payload: %v", err)
	}

	// Create a new HTTP request
	req, err := http.NewRequest("POST", idracCredentials.url, bytes.NewBuffer(payloadBytes))
	if err != nil {
		return fmt.Errorf("failed to create request: %v", err)
	}

	// Set headers
	req.Header.Set("Content-Type", "application/json")
	req.SetBasicAuth(idracCredentials.username, idracCredentials.password)

	// Send the request
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to send request: %v", err)
	}
	defer resp.Body.Close()

	// Check the response status code
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusAccepted {
		body, _ := ioutil.ReadAll(resp.Body)
		return fmt.Errorf("unexpected status code: %d, response: %s", resp.StatusCode, string(body))
	}

	glog.Infof("Reset type %s initiated successfully.\n")
	return nil

}
