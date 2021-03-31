package main

import (
	"bytes"
	"fmt"
	"log"
	"os"

	"golang.org/x/crypto/ssh"
)

const (
	sshKeyPathEnvVarName       = "SSH_KEY"
	setupOpenWRTDNSFlagName    = "setup-openwrt-dns"
	setupOpenWRTNewDNSFlagName = "new-dns"

	openWRTUser = "root"
	openWRTHost = "192.168.1.1:22" // Using IP because assuming DNS is down
)

var (
	sshKeyPath, _ = os.LookupEnv(sshKeyPathEnvVarName)
)

// SetOpenWRTDNS ssh-es into `host` and sets `dns` as it's primary dns for dnsmasq
func SetOpenWRTDNS(privateKey []byte, dns string) (string, error) {
	signer, err := ssh.ParsePrivateKey(privateKey)
	if err != nil {
		log.Fatalf("unable to parse private key: %v", err)
	}

	config := &ssh.ClientConfig{
		User: openWRTUser,
		Auth: []ssh.AuthMethod{
			ssh.PublicKeys(signer),
		},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
	}
	client, err := ssh.Dial("tcp", openWRTHost, config)
	if err != nil {
		log.Fatal("Failed to dial: ", err)
	}
	defer client.Close()

	session, err := client.NewSession()
	if err != nil {
		log.Fatal("Failed to create session: ", err)
	}
	defer session.Close()

	cmd := openwrtDNSUpdateCmd(dns)
	var b bytes.Buffer
	session.Stdout = &b
	if err := session.Run(cmd); err != nil {
		log.Fatal("Failed to run: " + err.Error())
	}
	fmt.Println(b.String())
	return "", nil
}

func openwrtDNSUpdateCmd(newDNS string) string {
	return fmt.Sprintf("sed -i \"s/\\slist server.*/ list server '%s'/\" /etc/config/dhcp && /etc/init.d/dnsmasq reload", newDNS)
}
