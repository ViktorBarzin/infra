package main

import (
	"os"
	"os/exec"
)

// runStreaming executes name with args, wiring std streams to this process so
// the caller sees live output, and returns the command's error (non-nil on
// non-zero exit — preserved so homelab's own exit code reflects the child's).
func runStreaming(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	return cmd.Run()
}
