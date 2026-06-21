package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Home Assistant verbs cover the two things the `ha` MCP server can't: resolving
// the long-lived API token out of the cluster, and SSH to the HA host for
// host-level work (config files, docker, add-ons). Entity state/control stays
// with the MCP — see docs/adr/0012.
//
// The token lives in the dedicated k8s Secret openclaw/ha-tokens (one key per
// instance), split out of openclaw-secrets so non-admin operators (emo / "Home
// Server Admins") can read JUST the HA token, not the full skill_secrets blob.
// `ha token` resolves it on demand via the ambient kubeconfig, so it never
// depends on a pre-set env var (the gap that made agents re-derive the
// kubectl|base64|jq pipeline every session).

type haInstance struct {
	name      string // sofia | london
	sshUser   string // SSH login on the HA host
	sshHost   string // host reachable from the devvm (Sofia LAN)
	secretKey string // key inside the openclaw/ha-tokens Secret holding this token
}

const (
	haDefaultInstance = "sofia"
	haSecretNamespace = "openclaw"
	haSecretName      = "ha-tokens" // dedicated, least-privilege; see stacks/openclaw/ha_tokens.tf
)

// haInstances maps instance name → connection/secret facts. sofia is the default
// because the devvm is on the Sofia LAN; london is documented but its host
// (192.168.8.x) is only reachable remotely, so `ha ssh --instance london`
// generally won't connect from here (token resolution still works).
var haInstances = map[string]haInstance{
	"sofia":  {name: "sofia", sshUser: "vbarzin", sshHost: "192.168.1.8", secretKey: "sofia"},
	"london": {name: "london", sshUser: "hassio", sshHost: "192.168.8.103", secretKey: "london"},
}

func haCommands() []Command {
	return []Command{
		{Path: []string{"ha", "token"}, Tier: TierRead,
			Summary: "reveal the HA long-lived API token from the cluster: ha token [--instance sofia|london]", Run: haToken},
		{Path: []string{"ha", "ssh"}, Tier: TierWrite,
			Summary: "run a command on the HA host over ssh: ha ssh [--instance sofia|london] [-i KEY] -- <cmd>", Run: haSSH},
	}
}

// resolveHAInstance looks up an instance by name; "" yields the default (sofia).
func resolveHAInstance(name string) (haInstance, error) {
	if name == "" {
		name = haDefaultInstance
	}
	inst, ok := haInstances[name]
	if !ok {
		return haInstance{}, fmt.Errorf("unknown HA instance %q (want sofia or london)", name)
	}
	return inst, nil
}

// decodeSecretValue base64-decodes a k8s Secret `.data.<key>` value as returned
// by kubectl jsonpath (trailing whitespace tolerated).
func decodeSecretValue(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		return "", fmt.Errorf("base64-decode secret value: %w", err)
	}
	return string(raw), nil
}

func haToken(args []string) error {
	name, _ := firstPositional(args) // accept `ha token sofia` as well as `--instance sofia`
	for i := 0; i < len(args); i++ {
		if args[i] == "--instance" && i+1 < len(args) {
			name = args[i+1]
		} else if strings.HasPrefix(args[i], "--instance=") {
			name = strings.TrimPrefix(args[i], "--instance=")
		}
	}
	inst, err := resolveHAInstance(name)
	if err != nil {
		return err
	}
	b64, err := kubectlCapture(haSecretNamespace, "get", "secret", haSecretName,
		"-o", "jsonpath={.data."+inst.secretKey+"}")
	if err != nil {
		return fmt.Errorf("read secret %s/%s (kubeconfig set? RBAC?): %w", haSecretNamespace, haSecretName, err)
	}
	if b64 == "" {
		return fmt.Errorf("secret %s/%s has no %q key", haSecretNamespace, haSecretName, inst.secretKey)
	}
	tok, err := decodeSecretValue(b64)
	if err != nil {
		return err
	}
	fmt.Println(tok)
	return nil
}

// defaultHAKeyPath is the invoking user's ed25519 key, so the verb is per-user
// rather than tied to whoever first wrote the workflow.
func defaultHAKeyPath() string {
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return filepath.Join(home, ".ssh", "id_ed25519")
	}
	return filepath.Join("~", ".ssh", "id_ed25519")
}

// parseHASSH reads `[--instance X] [-i|--key PATH] [-- ] <cmd...>`. Tokens after
// `--` are taken verbatim; bare tokens before it are also the remote command.
func parseHASSH(args []string) (inst haInstance, keyPath string, remote []string, err error) {
	name := haDefaultInstance
	keyPath = defaultHAKeyPath()
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--":
			remote = append(remote, args[i+1:]...)
			i = len(args)
		case a == "--instance":
			if i+1 < len(args) {
				name = args[i+1]
				i++
			}
		case strings.HasPrefix(a, "--instance="):
			name = strings.TrimPrefix(a, "--instance=")
		case a == "--key" || a == "-i":
			if i+1 < len(args) {
				keyPath = args[i+1]
				i++
			}
		case strings.HasPrefix(a, "--key="):
			keyPath = strings.TrimPrefix(a, "--key=")
		default:
			remote = append(remote, a)
		}
	}
	inst, err = resolveHAInstance(name)
	return inst, keyPath, remote, err
}

// buildHASSHArgs assembles deterministic, non-interactive ssh args: an explicit
// key, no user ssh config, and no known_hosts prompt/record — so it runs
// unattended in an agent session without hanging on a host-key prompt.
func buildHASSHArgs(inst haInstance, keyPath string, remote []string) []string {
	args := []string{
		"-F", "/dev/null",
		"-o", "IdentityFile=" + keyPath,
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=10",
		"-o", "BatchMode=yes",
		inst.sshUser + "@" + inst.sshHost,
	}
	return append(args, remote...)
}

func haSSH(args []string) error {
	inst, keyPath, remote, err := parseHASSH(args)
	if err != nil {
		return err
	}
	if len(remote) == 0 {
		return fmt.Errorf(`usage: homelab ha ssh [--instance sofia|london] [-i KEY] -- <command>`)
	}
	return runStreaming("ssh", buildHASSHArgs(inst, keyPath, remote)...)
}
