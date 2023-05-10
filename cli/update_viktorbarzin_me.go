package main

import (
	"bytes"
	"fmt"
	"io/ioutil"
	"net"
	"net/http"
	"os"
	"strings"

	"github.com/golang/glog"
	"github.com/pkg/errors"
)

const (
	dynDnsDomainFlagName          = "dynamic-domain"
	publicDomainFlagName          = "public-domain"
	updatePublicIPUseCaseFlagName = "update-public-ip"

	maintfFileRelative = "/main.tf"
)

func updatePublicIP(gitFs *GitFS, currIp, newIp net.IP) error {
	/* Steps to update:
	1. Read main.tf where we update the bind config with the public ip (replace all occurrences of the public ip)
		1.1) read the line where the variable is specified i.e
			bind_db_viktorbarzin_me  = replace(var.bind_db_viktorbarzin_me, "<current_ip>", "<new_ip>")
		1.2) switch <new_ip> and <currenct_ip>
		1.3) replace second ip (<new_ip> or after the switch <current_ip>) with the new_ip
	2. Update godaddy glue record

	*/
	newMainTfContents, err := getNewContent(gitFs, currIp, newIp)
	if err != nil {
		return errors.Wrapf(err, "failed to get updated main.tf contents")
	}
	f, err := (*gitFs.fs).OpenFile(maintfFileRelative, os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		return errors.Wrapf(err, "failed to open file %s for writing", maintfFileRelative)
	}
	if _, err = f.Write([]byte(newMainTfContents)); err != nil {
		return errors.Wrapf(err, "failed to write back new contents to %s:\n %s", maintfFileRelative, newMainTfContents)
	}
	return nil
}

// Get updated contents of main.tf
func getNewContent(gitFs *GitFS, currIp, newIp net.IP) (string, error) {
	f, err := (*gitFs.fs).OpenFile(maintfFileRelative, os.O_RDONLY, 0644)
	defer f.Close()
	if err != nil {
		return "", errors.Wrapf(err, "failed to open tfvars file: %s", maintfFileRelative)
	}
	bytes, err := ioutil.ReadAll(f)
	contents := string(bytes)

	newLines := []string{}
	for _, line := range strings.Split(contents, "\n") {
		lineToAdd := line
		// if line is the one that sets un the bind config
		if strings.HasPrefix(line, "  bind_db_viktorbarzin_me") {
			// extract old and new ip
			// line example:
			//  bind_db_viktorbarzin_me  = replace(var.bind_db_viktorbarzin_me, "<current_ip>", "<new_ip>")
			lineToAdd = strings.Replace(lineToAdd, "\"", "", -1) // remove all quotes
			lineToAdd = strings.Replace(lineToAdd, ")", "", -1)  // remove the trailing closing bracket
			splitByComma := strings.Split(lineToAdd, ",")
			if len(splitByComma) != 3 {
				return "", fmt.Errorf("invalid line; got: %s", line)
			}
			newIpStr := strings.ReplaceAll(splitByComma[2], " ", "")
			lineToAdd = fmt.Sprintf("  bind_db_viktorbarzin_me  = replace(var.bind_db_viktorbarzin_me, \"%s\", \"%s\")", newIpStr, newIp.String())
		}
		newLines = append(newLines, lineToAdd)
	}
	return strings.Join(newLines, "\n"), nil
}

func notifyForIPChange(oldIP, newIP net.IP) error {
	// Notify if dyndns ip is different to public
	// Currently send a message to Viktor via the webhook handler
	const url = "https://webhook.viktorbarzin.me/fb/message-viktor"
	body := []byte(fmt.Sprintf("Public IP (%s) is different than dynamic dns IP (%s)", oldIP.String(), newIP.String()))

	// Send the HTTP request
	resp, err := http.Post(url, "application/json", bytes.NewBuffer(body))
	if err != nil {
		return errors.Wrapf(err, "Error sending request")
	}
	defer resp.Body.Close()

	// Check the response status code
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("Request failed. Status code: %d", resp.StatusCode)
	}

	// Read the response body
	responseBody, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return errors.Wrapf(err, "Error reading response")
	}
	glog.Infof("Response:", string(responseBody))
	return nil
}
