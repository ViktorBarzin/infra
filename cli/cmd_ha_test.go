package main

import (
	"encoding/base64"
	"reflect"
	"strings"
	"testing"
)

func TestResolveHAInstance(t *testing.T) {
	// empty defaults to sofia (the devvm sits on the Sofia LAN)
	if got, err := resolveHAInstance(""); err != nil || got.name != "sofia" {
		t.Fatalf(`resolveHAInstance("") = %+v, %v; want sofia`, got, err)
	}
	if got, err := resolveHAInstance("sofia"); err != nil || got.secretKey != "sofia" {
		t.Fatalf("sofia secretKey = %q, %v", got.secretKey, err)
	}
	if got, err := resolveHAInstance("london"); err != nil || got.secretKey != "london" || got.sshUser != "hassio" {
		t.Fatalf("london = %+v, %v", got, err)
	}
	if _, err := resolveHAInstance("paris"); err == nil {
		t.Fatalf("resolveHAInstance(paris) should error on unknown instance")
	}
}

func TestDecodeSecretValue(t *testing.T) {
	// k8s stores Secret values base64-encoded; `kubectl -o jsonpath={.data.<k>}`
	// returns that base64, which decodeSecretValue turns back into the raw token.
	enc := base64.StdEncoding.EncodeToString([]byte("tok-sofia"))
	if got, err := decodeSecretValue(enc); err != nil || got != "tok-sofia" {
		t.Fatalf("decodeSecretValue = %q, %v; want tok-sofia", got, err)
	}
	// trailing whitespace/newline from jsonpath output must be tolerated
	if got, err := decodeSecretValue(enc + "\n"); err != nil || got != "tok-sofia" {
		t.Fatalf("decodeSecretValue (trailing ws) = %q, %v; want tok-sofia", got, err)
	}
	if _, err := decodeSecretValue("not-base64!!"); err == nil {
		t.Fatalf("decodeSecretValue should error on undecodable base64")
	}
}

func TestBuildHASSHArgs(t *testing.T) {
	inst, _ := resolveHAInstance("sofia")
	got := buildHASSHArgs(inst, "/home/u/.ssh/id_ed25519", []string{"cat", "/config/configuration.yaml"})
	want := []string{
		"-F", "/dev/null",
		"-o", "IdentityFile=/home/u/.ssh/id_ed25519",
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=10",
		"-o", "BatchMode=yes",
		"vbarzin@192.168.1.8",
		"cat", "/config/configuration.yaml",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("buildHASSHArgs =\n %v\nwant\n %v", got, want)
	}
}

func TestParseHASSH(t *testing.T) {
	// instance flag + everything after `--` is the verbatim remote command
	inst, key, remote, err := parseHASSH([]string{"--instance", "sofia", "--", "docker", "ps", "-a"})
	if err != nil {
		t.Fatalf("parseHASSH err: %v", err)
	}
	if inst.name != "sofia" {
		t.Errorf("instance = %q, want sofia", inst.name)
	}
	if !strings.HasSuffix(key, "/.ssh/id_ed25519") {
		t.Errorf("default key = %q, want it to end in /.ssh/id_ed25519", key)
	}
	if !reflect.DeepEqual(remote, []string{"docker", "ps", "-a"}) {
		t.Errorf("remote = %v, want [docker ps -a]", remote)
	}

	// bare args (no `--`) are also taken as the remote command; -i overrides the key
	_, key2, remote2, err := parseHASSH([]string{"-i", "/tmp/k", "uptime"})
	if err != nil {
		t.Fatalf("parseHASSH err: %v", err)
	}
	if key2 != "/tmp/k" {
		t.Errorf("key = %q, want /tmp/k", key2)
	}
	if !reflect.DeepEqual(remote2, []string{"uptime"}) {
		t.Errorf("remote = %v, want [uptime]", remote2)
	}

	// unknown instance surfaces as an error
	if _, _, _, err := parseHASSH([]string{"--instance", "paris", "--", "ls"}); err == nil {
		t.Errorf("parseHASSH should error on unknown instance")
	}
}
