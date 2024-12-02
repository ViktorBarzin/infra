package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"

	"github.com/pkg/errors"
)

type CreateTokenResponse struct {
	Username     string `json:"username"`
	TokenName    string `json:"tokenName"`
	Token        string `json:"token"`
	Status       string `json:"status"`
	ErrorMessage string `json:"errorMessage"`
}

type GetRecordsResponse struct {
	Response struct {
		Zone struct {
			Name         string `json:"name"`
			Type         string `json:"type"`
			Internal     bool   `json:"internal"`
			DnssecStatus string `json:"dnssecStatus"`
			Disabled     bool   `json:"disabled"`
		} `json:"zone"`
		Records []struct {
			Disabled bool   `json:"disabled"`
			Name     string `json:"name"`
			Type     string `json:"type"`
			Ttl      int64  `json:"ttl"`
			RData    struct {
				IpAddress string `json:"ipAddress"`
				// there's more fields that we don't use atm
			} `json:"rData"`
			// RData        interface{} `json:"rData"`
			DnsSecStatus string `json:"dnsSecStatus"`
		} `json:"records"`
	} `json:"response"`
}
type UpdateRecordResponse struct {
	Status       string `json:"status"`
	ErrorMessage string `json:"errorMessage"`
}

const TECHNITIUM_HOST = "technitium-web.technitium"

// const TECHNITIUM_HOST = "localhost"

func UpdatePublicIPViaTechnitiumAPI(newIp net.IP, username string, password string) error {
	token, err := createTechnitiumToken(username, password)
	if err != nil {
		return errors.Wrap(err, "failed to get technitium token")
	}
	for _, ns := range []string{"ns1", "ns2"} {
		nsRecordName := ns + ".viktorbarzin.me"
		currIpStr, err := getRecordValue(token, nsRecordName, "A")
		if err != nil {
			return errors.Wrap(err, "failed to get A record for ns server")
		}
		currIp := net.ParseIP(currIpStr)
		fmt.Printf("updating record %s to %s\n", nsRecordName, newIp.String())
		err = UpdateTechnitiumNSARecord(token, nsRecordName, currIp, newIp)
		if err != nil {
			return errors.Wrap(err, "failed to update NS A record")
		}
	}
	return nil
}

func UpdateTechnitiumNSARecord(token, domain string, currIp, newIp net.IP) error {
	baseURL := fmt.Sprintf("http://%s:5380/api/zones/records/update", TECHNITIUM_HOST)
	params := map[string]string{
		"token":        token,
		"domain":       domain,
		"type":         "A",
		"newIpAddress": newIp.String(),
		"ipAddress":    currIp.String(),
	}
	resp, err := sendTechnitiumAPIRequest(baseURL, params)
	if err != nil {
		return errors.Wrap(err, "failed to update record")
	}
	var parsedResponse UpdateRecordResponse
	err = json.NewDecoder(strings.NewReader(resp)).Decode(&parsedResponse)
	if err != nil {
		return errors.Wrap(err, "failed to decode json response when updating record")
	}
	if parsedResponse.Status == "error" {
		return fmt.Errorf("received error status when updating record: %s", parsedResponse.ErrorMessage)
	}
	return nil
}

func createTechnitiumToken(username string, password string) (string, error) {
	baseURL := fmt.Sprintf("http://%s:5380/api/user/createToken", TECHNITIUM_HOST)
	params := map[string]string{
		"user":      username,
		"pass":      password,
		"tokenName": "infra-cli-token",
	}
	resp, err := sendTechnitiumAPIRequest(baseURL, params)
	if err != nil {
		return "", errors.Wrap(err, "failed to fetch token")
	}
	var tokenResponse CreateTokenResponse
	// println(resp)
	err = json.NewDecoder(strings.NewReader(resp)).Decode(&tokenResponse)
	if err != nil {
		return "", errors.Wrap(err, "failed to decode json response")
	}
	if tokenResponse.Status != "ok" {
		return "", fmt.Errorf("received error status when fetching token: %s, error: %s", tokenResponse.Status, tokenResponse.ErrorMessage)
	}
	return tokenResponse.Token, nil
}

func getRecordValue(token, domain, recordType string) (string, error) {
	baseURL := fmt.Sprintf("http://%s:5380/api/zones/records/get", TECHNITIUM_HOST)
	params := map[string]string{
		"token":  token,
		"domain": domain,
	}
	resp, err := sendTechnitiumAPIRequest(baseURL, params)
	if err != nil {
		return "", errors.Wrapf(err, "failed to fetch record values for domain %s", domain)
	}

	var response GetRecordsResponse
	err = json.NewDecoder(strings.NewReader(resp)).Decode(&response)
	if err != nil {
		return "", errors.Wrap(err, "failed to decode json response when getting all zone records")
	}
	for _, record := range response.Response.Records {
		if record.Type == recordType {
			return record.RData.IpAddress, nil
		}
	}
	return "", fmt.Errorf("failed to find record for name %s and type %s", domain, recordType)
}

func sendTechnitiumAPIRequest(baseURL string, params map[string]string) (string, error) {
	url, err := url.Parse(baseURL)
	if err != nil {
		return "", errors.Wrapf(err, "failed to create base url")
	}
	// Encode the URL parameters
	query := url.Query()
	for key, value := range params {
		query.Add(key, value)
	}
	url.RawQuery = query.Encode()

	resp, err := http.Get(url.String())
	if err != nil {
		return "", errors.Wrap(err, "failed to create token")
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	return string(body), err
}
