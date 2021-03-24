package main

import (
	"fmt"
	"io/ioutil"
	"net"
	"os"
	"regexp"
	"strings"

	"github.com/golang/glog"
	"github.com/pkg/errors"
)

const (
	vpnUseCaseFlagName         = "vpn"
	vpnClientNameFlagName      = "vpn-client-name"
	vpnClientPubKeyFlagName    = "vpn-pub-key"
	vpnClientsConfFileRelative = "/modules/kubernetes/wireguard/extra/clients.conf"
	vpnLastIPConfFileRelative  = "/modules/kubernetes/wireguard/extra/last_ip.txt"
)

var (
	allowedClientName = regexp.MustCompile(`^[a-zA-Z0-9 ]+$`)
	allowedPubKey     = regexp.MustCompile(`^[a-zA-Z0-9=]+$`)
)

// addVPNClient inserts new client config
func addVPNClient(gitFs *GitFS, clientName, publicKey, clientsConfPath, ip string) error {
	if clientName == "" {
		return fmt.Errorf("client name must not be empty when creating a new vpn config")
	}
	if publicKey == "" {
		return fmt.Errorf("public key cannot be empty when creating new vpn config")
	}
	if !allowedClientName.Match([]byte(clientName)) {
		return fmt.Errorf("client key must match '%s', got %s", allowedClientName.String(), clientName)
	}
	if !allowedPubKey.Match([]byte(publicKey)) {
		return fmt.Errorf("client public key must match '%s', got '%s'", allowedPubKey.String(), publicKey)
	}

	contents := "[Peer]\n# friendly_name = " + clientName + "\nPublicKey = " + publicKey + "\nAllowedIPs = " + ip + "\n\n"
	glog.Infof("adding the following config: \n%s", contents)
	f, err := (*gitFs.fs).OpenFile(clientsConfPath, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		return errors.Wrapf(err, "failed to open client configs file to add new vpn client")
	}
	defer f.Close()

	if _, err = f.Write([]byte(contents)); err != nil {
		return errors.Wrapf(err, "failed to write config to file")
	}

	glog.Infof("successfully added new vpn client config for %s with interface ip %s", clientName, ip)
	return nil
}

func incrementIP(origIP, cidr string) (string, error) {
	ip := net.ParseIP(origIP)
	_, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		return origIP, err
	}
	for i := len(ip) - 1; i >= 0; i-- {
		ip[i]++
		if ip[i] != 0 {
			break
		}
	}
	if !ipNet.Contains(ip) {
		return origIP, errors.New("overflowed CIDR while incrementing IP")
	}
	return ip.String(), nil
}

// getAndUpdateIP Reads `fileName`, tries to get the ip, increments it, tries to write it back and returns the new address
func getAndUpdateIP(gitFs *GitFS, fileName string) (string, error) {
	f, err := (*gitFs.fs).Open(fileName)
	bytes, err := ioutil.ReadAll(f)
	if err != nil {
		return "", errors.Wrapf(err, "filed to read file %s", fileName)
	}
	errPrefix := "file has incorrect format: "
	content := strings.TrimSpace(string(bytes))
	lines := strings.Split(content, "\n")
	if len(lines) != 1 {
		return "", fmt.Errorf(errPrefix + fmt.Sprintf("expected 1 line got %d", len(lines)))
	}
	lineSplit := strings.Split(lines[0], " ")
	if len(lineSplit) < 1 {
		return "", fmt.Errorf("expected non empty line")
	}
	ipcidr := strings.Split(lineSplit[len(lineSplit)-1], "/")
	ipAddr := ipcidr[0]
	cidr := ipcidr[1]
	incrementedIP, err := incrementIP(ipAddr, strings.Join(ipcidr, "/"))
	if err != nil {
		return "", errors.Wrapf(err, "failed to increment ip for string '%s'", ipcidr)
	}

	// Write back updated ip
	fileContents := fmt.Sprintf("# DO NOT MANUALLY EDIT THIS LINE. Last IP: %s", incrementedIP+"/"+cidr)
	f, err = (*gitFs.fs).OpenFile(fileName, os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		return "", errors.Wrapf(err, "failed to open file %s for writing", fileName)
	}
	if _, err = f.Write([]byte(fileContents)); err != nil {
		return "", errors.Wrapf(err, "failed to write back new ip to file %s contents %s", fileName, fileContents)
	}
	glog.Infof("new ip: %s", incrementedIP)
	return incrementedIP + "/32", nil
}
