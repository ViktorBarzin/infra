package main

import (
	"flag"
	"fmt"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/golang/glog"
	"github.com/pkg/errors"
)

const (
	useCaseFlagName         = "use-case"
	repoRootFlagName        = "repo-root"
	printResultOnlyFlagName = "result-only"
)

var (
	validUseCases = []string{"setup-vpn"}
)

func main() {
	err := run()
	if err != nil {
		glog.Errorf("run failed: %s", err.Error())
	}
}

func run() error {
	useCase := flag.String(useCaseFlagName, "", fmt.Sprintf("Use case to run. Available use cases are: %+v", validUseCases))
	printResultOnly := flag.Bool(printResultOnlyFlagName, false, "Whether or not to print only the result (allocated ip) or print full command logging")
	// repoRootParam := flag.String(repoRootFlagName, "", fmt.Sprintf("Path to the root of the infra repository."))

	// VPN flags
	vpnClientName := flag.String(vpnClientNameFlagName, "", fmt.Sprintf("Friendly VPN user name."))
	vpnClientPubKey := flag.String(vpnClientPubKeyFlagName, "", fmt.Sprintf("VPN client public key."))

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

	gitFs, err := NewGitFS(repository)
	if err != nil {
		return errors.Wrapf(err, "failed to initialize git fs")
	}
	worktree, err := gitFs.repo.Worktree()
	if err != nil {
		return errors.Wrapf(err, "failed to get worktree")
	}

	switch *useCase {
	case vpnUseCaseFlagName:
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
	default:
		err = errors.New(fmt.Sprintf("unsupported use case: %s", *useCase))
	}
	if err != nil {
		return err
	}
	if err = gitFs.Push(); err != nil {
		return errors.Wrapf(err, "failed to push changes")
	}
	return nil
}
