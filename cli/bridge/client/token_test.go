package client

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTokenFromEnv(t *testing.T) {
	t.Setenv(EnvToken, "  from-the-environment\n")
	got, err := TokenFromEnvOrFile()
	if err != nil {
		t.Fatalf("TokenFromEnvOrFile: %v", err)
	}
	if got != "from-the-environment" {
		t.Fatalf("token = %q", got)
	}
}

func TestTokenFromFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv(EnvToken, "")
	t.Setenv("XDG_CONFIG_HOME", dir)

	path := filepath.Join(dir, "browser-bridge", "token")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte("from-the-file\n"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if got := TokenPath(); got != path {
		t.Fatalf("TokenPath = %q, want %q", got, path)
	}
	got, err := TokenFromEnvOrFile()
	if err != nil {
		t.Fatalf("TokenFromEnvOrFile: %v", err)
	}
	if got != "from-the-file" {
		t.Fatalf("token = %q", got)
	}
}

func TestTokenFileMissing(t *testing.T) {
	dir := t.TempDir()
	t.Setenv(EnvToken, "")
	t.Setenv("XDG_CONFIG_HOME", dir)

	_, err := TokenFromEnvOrFile()
	if err == nil {
		t.Fatal("want an error when the token file is absent")
	}
	msg := err.Error()
	for _, want := range []string{filepath.Join(dir, "browser-bridge", "token"), EnvToken} {
		if !strings.Contains(msg, want) {
			t.Fatalf("the error does not name %q:\n%s", want, msg)
		}
	}
	if ExitCode(err) != 2 {
		t.Fatalf("ExitCode = %d, want 2", ExitCode(err))
	}
}

func TestTokenFileMustNotBeReadableByOthers(t *testing.T) {
	dir := t.TempDir()
	t.Setenv(EnvToken, "")
	t.Setenv("XDG_CONFIG_HOME", dir)

	path := filepath.Join(dir, "browser-bridge", "token")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte("secret"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	_, err := TokenFromEnvOrFile()
	if err == nil {
		t.Fatal("want an error for a world-readable token on a shared box")
	}
	if !strings.Contains(err.Error(), "chmod 600") {
		t.Fatalf("the error does not name the fix:\n%s", err.Error())
	}
}

func TestBaseURLFromEnv(t *testing.T) {
	t.Setenv(EnvServer, "")
	if got := BaseURLFromEnv(); got != DefaultBaseURL {
		t.Fatalf("BaseURLFromEnv = %q, want the default", got)
	}
	t.Setenv(EnvServer, "http://127.0.0.1:8080/")
	if got := BaseURLFromEnv(); got != "http://127.0.0.1:8080/" {
		t.Fatalf("BaseURLFromEnv = %q", got)
	}
}

func TestBrowserFromEnv(t *testing.T) {
	t.Setenv(EnvBrowser, "")
	if got := BrowserFromEnv(); got != "" {
		t.Fatalf("BrowserFromEnv = %q, want empty", got)
	}
	t.Setenv(EnvBrowser, "b_9Qw8ErTyUiOpAsDfGhJkLm")
	if got := BrowserFromEnv(); got != "b_9Qw8ErTyUiOpAsDfGhJkLm" {
		t.Fatalf("BrowserFromEnv = %q", got)
	}
}
