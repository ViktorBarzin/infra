package main

import "testing"

func TestRunVerifyRefusesWhenNothingToVerify(t *testing.T) {
	dir := t.TempDir() // no go.mod, no verify cmd
	if err := runVerify(dir, "", false); err == nil {
		t.Fatal("runVerify must refuse (error) when nothing to verify and --no-verify absent")
	}
	if err := runVerify(dir, "", true); err != nil {
		t.Fatalf("runVerify must skip when --no-verify set, got: %v", err)
	}
}

func TestFlagValue(t *testing.T) {
	cases := []struct {
		args []string
		name string
		want string
	}{
		{[]string{"--verify-cmd", "go test ./..."}, "--verify-cmd", "go test ./..."},
		{[]string{"--verify-cmd=make test"}, "--verify-cmd", "make test"},
		{[]string{"topic", "--verify-cmd", "x"}, "--verify-cmd", "x"},
		{[]string{"topic"}, "--verify-cmd", ""},
		{[]string{"--verify-cmd"}, "--verify-cmd", ""}, // no value
	}
	for _, c := range cases {
		if got := flagValue(c.args, c.name); got != c.want {
			t.Errorf("flagValue(%v, %q) = %q, want %q", c.args, c.name, got, c.want)
		}
	}
}
