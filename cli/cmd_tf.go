package main

import (
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
)

func tfCommands() []Command {
	return []Command{
		{Path: []string{"tf", "plan"}, Tier: TierRead,
			Summary: "terragrunt plan a stack (via scripts/tg)", Run: tfPassthrough("plan")},
		{Path: []string{"tf", "validate"}, Tier: TierRead,
			Summary: "terragrunt validate a stack", Run: tfPassthrough("validate")},
		{Path: []string{"tf", "fmt"}, Tier: TierRead,
			Summary: "terraform fmt a stack's files", Run: tfFmt},
		{Path: []string{"tf", "force-unlock"}, Tier: TierWrite,
			Summary: "release a stuck terraform state lock (needs <stack> <lock-id>)", Run: tfForceUnlock},
		{Path: []string{"tf", "apply"}, Tier: TierWrite,
			Summary: "terragrunt apply a stack — presence-coupled, out-of-band", Run: tfApply},
	}
}

// firstPositional returns the first non-flag arg and the remaining args with it removed.
func firstPositional(args []string) (string, []string) {
	for i, a := range args {
		if !strings.HasPrefix(a, "-") {
			rest := append(append([]string{}, args[:i]...), args[i+1:]...)
			return a, rest
		}
	}
	return "", args
}

// resolveTfStack finds the infra root (from cwd) and the stack directory named
// by the first positional arg, returning the remaining args.
func resolveTfStack(args []string) (infraRoot, stackName, stackDir string, rest []string, err error) {
	stackName, rest = firstPositional(args)
	if stackName == "" {
		err = fmt.Errorf("missing <stack> argument")
		return
	}
	cwd, e := os.Getwd()
	if e != nil {
		err = e
		return
	}
	infraRoot, err = findInfraRoot(cwd)
	if err != nil {
		return
	}
	stackDir, err = resolveStack(infraRoot, stackName)
	return
}

func tgPath(infraRoot string) string { return filepath.Join(infraRoot, "scripts", "tg") }

// tfPassthrough runs `scripts/tg <verb> [extra]` in the stack directory.
func tfPassthrough(verb string) func([]string) error {
	return func(args []string) error {
		infraRoot, _, stackDir, rest, err := resolveTfStack(args)
		if err != nil {
			return err
		}
		return runStreamingIn(stackDir, tgPath(infraRoot), append([]string{verb}, rest...)...)
	}
}

func tfFmt(args []string) error {
	_, _, stackDir, _, err := resolveTfStack(args)
	if err != nil {
		return err
	}
	return runStreamingIn(stackDir, "terraform", "fmt", "-recursive", ".")
}

func tfForceUnlock(args []string) error {
	infraRoot, _, stackDir, rest, err := resolveTfStack(args)
	if err != nil {
		return err
	}
	if len(rest) < 1 {
		return fmt.Errorf("usage: homelab tf force-unlock <stack> <lock-id>")
	}
	return runStreamingIn(stackDir, tgPath(infraRoot), "force-unlock", "-force", rest[0])
}

// tfApply applies a stack out-of-band: claim the stack on the presence board,
// ALWAYS release on exit (normal, error, or signal — fixing the claim leak),
// and warn that CI applies canonically on push.
func tfApply(args []string) error {
	infraRoot, stackName, stackDir, _, err := resolveTfStack(args)
	if err != nil {
		return err
	}
	label := "stack:" + stackName
	fmt.Fprintf(os.Stderr,
		"homelab: out-of-band apply of %q — CI applies canonically on push to master.\n", stackName)

	if err := presenceClaim(label, "homelab tf apply "+stackName); err != nil {
		return fmt.Errorf("presence claim failed (run `vault login -method=oidc`?): %w", err)
	}
	// Release exactly once, whether we exit normally, on error, or on signal —
	// sync.Once makes the defer and the signal goroutine safe to both call it.
	var once sync.Once
	release := func() { once.Do(func() { _ = presenceRelease(label) }) }
	defer release()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sig
		release()
		os.Exit(130)
	}()

	return runStreamingIn(stackDir, tgPath(infraRoot), "apply", "--non-interactive")
}
