package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNetsecConnPrefersEnvironment(t *testing.T) {
	t.Setenv("NETSEC_URL", "http://example.test")
	t.Setenv("NETSEC_USER", "netsec_reader")
	t.Setenv("NETSEC_PASSWORD", "pw")
	c, err := netsecConnFrom(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if c.URL != "http://example.test" || c.User != "netsec_reader" || c.Password != "pw" {
		t.Fatalf("got %+v", c)
	}
}

func TestNetsecConnReadsReaderEnvFile(t *testing.T) {
	t.Setenv("NETSEC_URL", "")
	t.Setenv("NETSEC_USER", "")
	t.Setenv("NETSEC_PASSWORD", "")
	dir := t.TempDir()
	body := "# managed\nNETSEC_USER=netsec_reader\nNETSEC_PASSWORD=secret\n"
	if err := os.WriteFile(filepath.Join(dir, "reader.env"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := netsecConnFrom(dir)
	if err != nil {
		t.Fatal(err)
	}
	if c.User != "netsec_reader" || c.Password != "secret" {
		t.Fatalf("got %+v", c)
	}
	if c.URL != claudeSessionsURL {
		t.Fatalf("default URL should be the claude-sessions ClickHouse, got %q", c.URL)
	}
}

func TestNetsecConnMissingCredentials(t *testing.T) {
	t.Setenv("NETSEC_USER", "")
	t.Setenv("NETSEC_PASSWORD", "")
	_, err := netsecConnFrom(t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "netsec") {
		t.Fatalf("want an error naming netsec, got %v", err)
	}
}

func TestParseNetsecSQLArgs(t *testing.T) {
	format, q, err := parseNetsecSQLArgs([]string{"--format", "TSVWithNames", "SELECT", "1"})
	if err != nil {
		t.Fatal(err)
	}
	if format != "TSVWithNames" || q != "SELECT 1" {
		t.Fatalf("got %q %q", format, q)
	}
	format, _, err = parseNetsecSQLArgs([]string{"SELECT 1"})
	if err != nil || format != "PrettyCompactMonoBlock" {
		t.Fatalf("default format: got %q %v", format, err)
	}
	if _, _, err := parseNetsecSQLArgs([]string{"--format"}); err == nil {
		t.Fatal("want an error for --format without a value")
	}
	if _, _, err := parseNetsecSQLArgs(nil); err == nil {
		t.Fatal("want a usage error for an empty query")
	}
}

func TestNetsecSQLSendsReaderCredentials(t *testing.T) {
	var gotUser, gotQuery, gotFormat string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotUser = r.Header.Get("X-ClickHouse-User")
		gotQuery = r.URL.Query().Get("query")
		gotFormat = r.URL.Query().Get("default_format")
		w.Write([]byte("42\n"))
	}))
	defer srv.Close()
	t.Setenv("NETSEC_URL", srv.URL)
	t.Setenv("NETSEC_USER", "netsec_reader")
	t.Setenv("NETSEC_PASSWORD", "pw")
	out, err := runNetsecQuery(t.TempDir(), "TSV", "SELECT count() FROM netsec.flows")
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != "42\n" || gotUser != "netsec_reader" || gotFormat != "TSV" || gotQuery != "SELECT count() FROM netsec.flows" {
		t.Fatalf("out=%q user=%q format=%q query=%q", out, gotUser, gotFormat, gotQuery)
	}
}
