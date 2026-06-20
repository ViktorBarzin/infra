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
	if got, err := resolveHAInstance("sofia"); err != nil || got.secretKey != "home_assistant_sofia_token" {
		t.Fatalf("sofia secretKey = %q, %v", got.secretKey, err)
	}
	if got, err := resolveHAInstance("london"); err != nil || got.secretKey != "home_assistant_token" || got.sshUser != "hassio" {
		t.Fatalf("london = %+v, %v", got, err)
	}
	if _, err := resolveHAInstance("paris"); err == nil {
		t.Fatalf("resolveHAInstance(paris) should error on unknown instance")
	}
}

func TestParseSkillSecret(t *testing.T) {
	blob := base64.StdEncoding.EncodeToString([]byte(
		`{"home_assistant_sofia_token":"tok-sofia","home_assistant_token":"tok-london","slack_webhook":"https://x"}`))

	if got, err := parseSkillSecret(blob, "home_assistant_sofia_token"); err != nil || got != "tok-sofia" {
		t.Fatalf("parseSkillSecret sofia = %q, %v; want tok-sofia", got, err)
	}
	// kubectl jsonpath output can carry trailing whitespace/newline — must tolerate it
	if got, err := parseSkillSecret(blob+"\n", "home_assistant_token"); err != nil || got != "tok-london" {
		t.Fatalf("parseSkillSecret london (trailing ws) = %q, %v; want tok-london", got, err)
	}
	if _, err := parseSkillSecret(blob, "missing_key"); err == nil {
		t.Fatalf("parseSkillSecret should error on a key absent from the blob")
	}
	if _, err := parseSkillSecret("not-base64!!", "home_assistant_sofia_token"); err == nil {
		t.Fatalf("parseSkillSecret should error on undecodable base64")
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
