package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

func deployCommands() []Command {
	return []Command{
		{Path: []string{"deploy"}, Tier: TierWrite,
			Summary: "build an app's landed master here and put it live as its CI would: deploy f1-stream [--server] [--tv] [--sha SHA] [--check]", Run: deployRelease},
		{Path: []string{"deploy", "wait"}, Tier: TierRead,
			Summary: "wait for <ns>/<deploy> to roll out the current (or --sha) image: deploy wait <ns>/<deploy> [--sha SHA] [--timeout 10m]", Run: deployWait},
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
	timeout := 10 * time.Minute
	if t := flagValue(args, "--timeout"); t != "" {
		d, err := time.ParseDuration(t)
		if err != nil {
			return fmt.Errorf("bad --timeout %q: %v", t, err)
		}
		timeout = d
	}
	return waitDeployImage(ns, deploy, sha, timeout)
}

// waitDeployImage waits up to timeout for ns/deploy's image to reference sha
// (when sha is set), then for its rollout to finish.
func waitDeployImage(ns, deploy, sha string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)

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
	rollout := time.Until(deadline)
	if rollout < 3*time.Minute {
		rollout = 3 * time.Minute
	}
	fmt.Fprintf(os.Stderr, "homelab: rollout status %s/%s...\n", ns, deploy)
	return kubectlStream(ns, "rollout", "status", "deploy/"+deploy, fmt.Sprintf("--timeout=%ds", int(rollout.Seconds())))
}
