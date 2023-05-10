package main

import (
	"io/ioutil"
	"net"
	"os"

	"github.com/pkg/errors"
)

const (
	dynDnsDomainFlagName          = "dynamic-domain"
	publicDomainFlagName          = "public-domain"
	updatePublicIPUseCaseFlagName = "kek"

	tfvarsFileRelative = "/terraform.tfvars"
)

func updatePublicIP(gitFs *GitFS, currIp, newIp net.IP) error {
	println(currIp.String())
	println(newIp.String())

	f, err := (*gitFs.fs).OpenFile(tfvarsFileRelative, os.O_RDONLY, 0644)
	defer f.Close()
	if err != nil {
		return errors.Wrapf(err, "failed to open tfvars file: %s", tfvarsFileRelative)
	}
	bytes, err := ioutil.ReadAll(f)
	println(string(bytes))

	return errors.New("test")
}
