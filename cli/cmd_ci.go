package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

func ciCommands() []Command {
	return []Command{
		{Path: []string{"ci", "status"}, Tier: TierRead,
			Summary: "pipeline status for HEAD/a commit: ci status [commit]", Run: ciStatus},
		{Path: []string{"ci", "watch"}, Tier: TierRead,
			Summary: "poll the pipeline for HEAD (or a commit) to terminal; non-zero on failure", Run: ciWatch},
	}
}

func short(s string) string {
	if len(s) > 8 {
		return s[:8]
	}
	return s
}

func firstLine(s string) string { return strings.SplitN(s, "\n", 2)[0] }

// currentHEAD returns the full HEAD sha of the cwd repo (empty if not a repo).
func currentHEAD() string {
	cwd, _ := os.Getwd()
	root, err := gitRepoRoot(cwd)
	if err != nil {
		return ""
	}
	sha, _ := gitOutput(root, "rev-parse", "HEAD")
	return sha
}

func ciStatus(args []string) error {
	commit, _ := firstPositional(args)
	c, err := newWPClient()
	if err != nil {
		return err
	}
	id, err := c.repoID()
	if err != nil {
		return err
	}
	p, err := c.findPipeline(id, commit)
	if err != nil {
		return err
	}
	fmt.Printf("#%d %s event=%s %s %s\n", p.Number, p.Status, p.Event, short(p.Commit), firstLine(p.Message))
	return nil
}

func ciWatch(args []string) error {
	commit, _ := firstPositional(args)
	if commit == "" {
		commit = currentHEAD()
	}
	if commit == "" {
		return fmt.Errorf("no commit given and not in a git repo")
	}
	c, err := newWPClient()
	if err != nil {
		return err
	}
	id, err := c.repoID()
	if err != nil {
		return err
	}
	timeout := 20 * time.Minute
	deadline := time.Now().Add(timeout)
	last := ""
	for time.Now().Before(deadline) {
		p, err := c.findPipeline(id, commit)
		if err != nil {
			if last != "waiting" {
				fmt.Fprintf(os.Stderr, "homelab: waiting for pipeline (%s)...\n", short(commit))
				last = "waiting"
			}
		} else {
			if p.Status != last {
				fmt.Fprintf(os.Stderr, "homelab: #%d %s\n", p.Number, p.Status)
				last = p.Status
			}
			if isTerminalStatus(p.Status) {
				fmt.Printf("#%d %s %s\n", p.Number, p.Status, short(commit))
				if isFailureStatus(p.Status) {
					return fmt.Errorf("pipeline #%d %s (woodpecker repo, see UI/DB for the failing step)", p.Number, p.Status)
				}
				return nil
			}
		}
		time.Sleep(15 * time.Second)
	}
	return fmt.Errorf("timed out after %s waiting for CI on %s", timeout, short(commit))
}
