package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestParseK8sTarget(t *testing.T) {
	got := parseK8sTarget([]string{"tripit", "-n", "prod", "--pod", "x-123", "-c", "app", "-l", "k=v", "--tail=50", "--", "ls", "-la"})
	want := k8sTarget{app: "tripit", ns: "prod", pod: "x-123", container: "app", selector: "k=v", rest: []string{"--tail=50", "ls", "-la"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseK8sTarget =\n %+v\nwant\n %+v", got, want)
	}
}

func TestK8sTargetNamespaceDefaultsToApp(t *testing.T) {
	if ns := parseK8sTarget([]string{"immich"}).namespace(); ns != "immich" {
		t.Errorf("namespace() = %q, want immich", ns)
	}
	if ns := parseK8sTarget([]string{"immich", "-n", "dbaas"}).namespace(); ns != "dbaas" {
		t.Errorf("namespace() = %q, want dbaas", ns)
	}
}

func TestK8sTargetObjectRef(t *testing.T) {
	if r := parseK8sTarget([]string{"tripit"}).objectRef(); r != "deploy/tripit" {
		t.Errorf("objectRef() = %q, want deploy/tripit", r)
	}
	if r := parseK8sTarget([]string{"tripit", "--pod", "tripit-abc"}).objectRef(); r != "pod/tripit-abc" {
		t.Errorf("objectRef() = %q, want pod/tripit-abc", r)
	}
}

func TestPlanDBExecPostgresDefault(t *testing.T) {
	p := planDBExec("fire-planner", "", "SELECT 1", false)
	// pg-cluster-rw is a Service, so the PG plan resolves the primary POD by
	// label rather than naming an (un-exec-able) Service.
	if p.ns != "dbaas" || p.pod != "" || p.selector != "cnpg.io/instanceRole=primary" || p.container != "postgres" {
		t.Fatalf("unexpected pg target: %+v", p)
	}
	// db name defaults to the app; SQL passed via -tAc
	joined := strings.Join(p.argv, " ")
	if !strings.Contains(joined, "-d fire-planner") || !strings.Contains(joined, "-tAc") {
		t.Fatalf("pg argv missing db/sql: %v", p.argv)
	}
}

func TestPlanDBExecMysqlEnvPassword(t *testing.T) {
	p := planDBExec("wrongmove", "wrongmove", "SHOW TABLES", true)
	if p.pod != "mysql-standalone-0" {
		t.Fatalf("unexpected mysql pod: %+v", p)
	}
	inner := strings.Join(p.argv, " ")
	// password must come from the env var, never inline
	if !strings.Contains(inner, `-p"$MYSQL_ROOT_PASSWORD"`) {
		t.Fatalf("mysql must use env password wrapper: %v", p.argv)
	}
}

func TestShellQuoteEscapes(t *testing.T) {
	if got := shellQuote("a'b"); got != `'a'\''b'` {
		t.Fatalf("shellQuote = %q", got)
	}
}
