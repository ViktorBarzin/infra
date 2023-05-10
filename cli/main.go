package main

import (
	"flag"
	"fmt"
	"io/ioutil"
	"net"
	"os"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/golang/glog"
	"github.com/pkg/errors"
)

const (
	useCaseFlagName         = "use-case"
	repoRootFlagName        = "repo-root"
	printResultOnlyFlagName = "result-only"
	dynamicDnsDomainDefault = "viktorbarzin.ddns.net"
	publicDomainDefault     = "viktorbarzin.me"
)

var (
	validUseCases = []string{vpnUseCaseFlagName, setupOpenWRTDNSFlagName, addEmailAliasUseCase}
)

func main() {
	err := run()
	if err != nil {
		glog.Errorf("run failed: %s", err.Error())
		os.Exit(255)
	}
}

func run() error {
	useCase := flag.String(useCaseFlagName, "", fmt.Sprintf("Use case to run. Available use cases are: %+v", validUseCases))
	printResultOnly := flag.Bool(printResultOnlyFlagName, false, "Whether or not to print only the result (allocated ip) or print full command logging")
	// repoRootParam := flag.String(repoRootFlagName, "", fmt.Sprintf("Path to the root of the infra repository."))

	// VPN flags
	vpnClientName := flag.String(vpnClientNameFlagName, "", fmt.Sprintf("Friendly VPN user name."))
	vpnClientPubKey := flag.String(vpnClientPubKeyFlagName, "", fmt.Sprintf("VPN client public key."))

	// OpenWRT DNS flags
	openWRTNewDNS := flag.String(setupOpenWRTNewDNSFlagName, "", fmt.Sprintf("New DNS server to set."))

	// add email alias flags
	emailToForwardTo := flag.String(emailAliasFlagName, "", "Email which is used to forward emails to.")
	fromDomain := flag.String(fromEmailDomainFlagName, "@viktorbarzin.me", "Domain name which will receive emails. Example @viktorbarzin.me")

	// settings for updating the main domain using the dyndns domain
	dynDnsDomain := flag.String(dynDnsDomainFlagName, dynamicDnsDomainDefault, "Dynamic DNS domain to check against - used to update the main domain")
	publicDomain := flag.String(publicDomainFlagName, publicDomainDefault, "Public domain to update")

	// Flag definitions above!
	flag.Parse()

	if !*printResultOnly {
		flag.Set("logtostderr", "true")
		flag.Set("stderrthreshold", "WARNING")
		flag.Set("v", "2")
	}

	// if *repoRootParam == "" {
	// 	return fmt.Errorf("'-%s' flag must not be empty", repoRootFlagName)
	// }
	if *useCase == "" {
		return fmt.Errorf("'-%s' flag must not be empty", useCaseFlagName)
	}
	// repoRoot, err := filepath.Abs(*repoRootParam)
	// if err != nil {
	// 	return errors.Wrapf(err, "failed to create absolute path from %s", repoRoot)
	// }

	glog.Infof("Use case is: %s", *useCase)
	// glog.Infof("Repo root is: %s", repoRoot)
	var err error

	switch *useCase {
	case vpnUseCaseFlagName:
		gitFs, err := NewGitFS(repository)
		if err != nil {
			return errors.Wrapf(err, "failed to initialize git fs")
		}
		worktree, err := gitFs.repo.Worktree()
		if err != nil {
			return errors.Wrapf(err, "failed to get worktree")
		}

		// get last used ip and increment
		ip, err := getAndUpdateIP(gitFs, vpnLastIPConfFileRelative)
		if err != nil {
			return errors.Wrapf(err, "failed to get valid last ip from file %s", vpnLastIPConfFileRelative)
		}
		// insert new vpn client config
		err = addVPNClient(gitFs, *vpnClientName, *vpnClientPubKey, vpnClientsConfFileRelative, ip)
		if err != nil {
			return errors.Wrapf(err, "failed to add vpn client")
		}
		// commit changes
		if _, err = worktree.Commit("Added new VPN client config", &git.CommitOptions{All: true, Author: &object.Signature{Name: "Webhook Handler Bot"}}); err != nil {
			return errors.Wrapf(err, "failed to commit")
		}
		if *printResultOnly {
			println(ip)
		}
		if err = gitFs.Push(); err != nil {
			return errors.Wrapf(err, "failed to push changes")
		}
	case setupOpenWRTDNSFlagName:
		if *openWRTNewDNS == "" {
			return fmt.Errorf("New DNS cannot be empty")
		}
		if sshKeyPath == "" {
			return fmt.Errorf("Env variable %s must be set to the location of the private key to use", sshKeyPath)
		}
		key, err := ioutil.ReadFile(sshKeyPath)
		if err != nil {
			return errors.Wrapf(err, "unable to read private key")
		}
		output, err := SetOpenWRTDNS(key, *openWRTNewDNS)
		if err != nil {
			return errors.Wrapf(err, fmt.Sprintf("cmd output: %s", output))
		}
		if *printResultOnly {
			println(fmt.Sprintf("Successfully set DNS server to '%s'", *openWRTNewDNS))
		}
	case addEmailAliasUseCase:
		if *emailToForwardTo == "" {
			return fmt.Errorf("%s must not be empty when using %s use case", emailAliasFlagName, addEmailAliasUseCase)
		}
		glog.Infof("Trying to add %s email alias", *emailToForwardTo)
		gitFs, err := NewGitFS(repository)
		if err != nil {
			return errors.Wrapf(err, "failed to initialize git fs")
		}
		worktree, err := gitFs.repo.Worktree()
		if err != nil {
			return errors.Wrapf(err, "failed to get worktree")
		}
		emailAlias, err := addEmailAlias(gitFs, *emailToForwardTo, *fromDomain)
		if err != nil {
			return errors.Wrapf(err, "failed to add email alias")
		}
		glog.Infof("generated %s email alias", emailAlias)
		// commit changes
		if _, err = worktree.Commit("Added new email alias", &git.CommitOptions{All: true, Author: &object.Signature{Name: "Webhook Handler Bot"}}); err != nil {
			return errors.Wrapf(err, "failed to commit")
		}
		if *printResultOnly {
			fmt.Printf("Successfully created '%s' -> '%s' forwarding", emailAlias, *emailToForwardTo)
			// println(ip)
		}
		if err = gitFs.Push(); err != nil {
			return errors.Wrapf(err, "failed to push changes")
		}
		glog.Infof("successfully added %s -> %s email aliasing", emailAlias, *emailToForwardTo)
	case updatePublicIPUseCaseFlagName:
		// Resolve the dynamic dns record
		publicDNSIps, err := net.LookupIP(*publicDomain)
		if err != nil {
			return errors.Wrapf(err, "failed to resolve IP addresses")
		}
		if len(publicDNSIps) < 1 {
			return fmt.Errorf("no ips found for %s", *dynDnsDomain)
		}

		// Resolve the dynamic dns record
		dynamicDNSIps, err := net.LookupIP(*dynDnsDomain)
		if err != nil {
			return errors.Wrap(err, "failed to resolve IP addresses")
		}
		if len(dynamicDNSIps) < 1 {
			return fmt.Errorf("no ips found for %s", *dynDnsDomain)
		}

		currIP, newIP := publicDNSIps[0], dynamicDNSIps[0]
		if currIP.Equal(newIP) {
			glog.Infof("IPs of dyndns and current ip match, nothing to do: current=%s, dyndns=%s", currIP, newIP)
			return nil
		}
		// Send notification as glue records can't be modified programatically for godaddy :/
		err = notifyForIPChange(currIP, newIP)
		if err != nil {
			return errors.Wrapf(err, "failed to notify for ip change. this must succeed otherwise the glue records won't be updated")
		}
		// setup git repo
		gitFs, err := NewGitFS(repository)
		if err != nil {
			return errors.Wrapf(err, "failed to initialize git fs")
		}
		worktree, err := gitFs.repo.Worktree()
		if err != nil {
			return errors.Wrapf(err, "failed to get worktree")
		}
		err = updatePublicIP(gitFs, currIP, newIP)
		if err != nil {
			return fmt.Errorf("failed to update public ip: %w", err)
		}
		// // commit changes
		if _, err = worktree.Commit("Update public ip and ns records", &git.CommitOptions{All: true, Author: &object.Signature{Name: "Webhook Handler Bot"}}); err != nil {
			return errors.Wrapf(err, "failed to commit")
		}
		if err = gitFs.Push(); err != nil {
			return errors.Wrapf(err, "failed to push changes")
		}
	default:
		err = errors.New(fmt.Sprintf("unsupported use case: %s", *useCase))
	}
	if err != nil {
		return err
	}
	return nil
}
