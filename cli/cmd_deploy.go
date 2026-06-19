package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

func deployCommands() []Command {
	return []Command{
		{Path: []string{"deploy", "wait"}, Tier: TierRead,
			Summary: "wait for <ns>/<deploy> to roll out the current (or --sha) image: deploy wait <ns>/<deploy> [--sha SHA]", Run: deployWait},
	}
}

// deployWait closes the "did the NEW code land" gap: rollout status alone returns
// success on the OLD ReplicaSet, so we first wait for the deployment image to
// reference the expected sha, THEN block on rollout status.
func deployWait(args []string) error {
	target, _ := firstPositional(args)
	if target == "" || !strings.Contains(target, "/") {
		return fmt.Errorf("usage: homelab deploy wait <ns>/<deploy> [--sha SHA] [--timeout 10m]")
	}
	parts := strings.SplitN(target, "/", 2)
	ns, deploy := parts[0], parts[1]

	sha := flagValue(args, "--sha")
	if sha == "" {
		sha = short(currentHEAD())
	}
	deadline := time.Now().Add(10 * time.Minute)

	if sha != "" {
		fmt.Fprintf(os.Stderr, "homelab: waiting for %s/%s image to match %s...\n", ns, deploy, sha)
		matched := false
		for time.Now().Before(deadline) {
			img, _ := kubectlCapture(ns, "get", "deploy", deploy, "-o", "jsonpath={.spec.template.spec.containers[*].image}")
			if strings.Contains(img, sha) {
				matched = true
				break
			}
			time.Sleep(10 * time.Second)
		}
		if !matched {
			return fmt.Errorf("timed out: %s/%s image never matched %q", ns, deploy, sha)
		}
	}
	fmt.Fprintf(os.Stderr, "homelab: rollout status %s/%s...\n", ns, deploy)
	return kubectlStream(ns, "rollout", "status", "deploy/"+deploy, "--timeout=180s")
}
