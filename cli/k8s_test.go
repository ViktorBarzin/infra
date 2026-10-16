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
	// The pod is the one the apps' own Service selects. On 2026-10-15 the
	// cutover to pg-cluster-v18 left the frozen PG16 primary running, and a
	// bare instanceRole=primary label picked it, so every read was stale.
	if p.ns != "dbaas" || p.service != "postgresql" || p.container != "postgres" {
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
	// Same rule as Postgres: follow the `mysql` Service, which moved to
	// mysql-v26 on 2026-10-15 while mysql-standalone-0 kept running.
	if p.ns != "dbaas" || p.service != "mysql" {
		t.Fatalf("unexpected mysql target: %+v", p)
	}
	inner := strings.Join(p.argv, " ")
	// password must come from the env var, never inline
	if !strings.Contains(inner, `-p"$MYSQL_ROOT_PASSWORD"`) {
		t.Fatalf("mysql must use env password wrapper: %v", p.argv)
	}
}

func TestLabelSelectorFromService(t *testing.T) {
	cases := []struct {
		raw, want string
		ok        bool
	}{
		{`{"cnpg.io/instanceRole":"primary","cnpg.io/cluster":"pg-cluster-v18"}`,
			"cnpg.io/cluster=pg-cluster-v18,cnpg.io/instanceRole=primary", true},
		{`{"app.kubernetes.io/component":"primary","app.kubernetes.io/instance":"mysql-v26"}`,
			"app.kubernetes.io/component=primary,app.kubernetes.io/instance=mysql-v26", true},
		{``, "", false},   // a Service with no selector names no pod
		{`{}`, "", false}, // same, spelled as an empty map
		{`not json`, "", false},
	}
	for _, c := range cases {
		got, err := labelSelectorFromService(c.raw)
		if (err == nil) != c.ok || got != c.want {
			t.Errorf("labelSelectorFromService(%q) = %q, %v; want %q, ok=%v", c.raw, got, err, c.want, c.ok)
		}
	}
}

func TestOnlyPod(t *testing.T) {
	if pod, err := onlyPod("pg-cluster-v18-1"); err != nil || pod != "pg-cluster-v18-1" {
		t.Fatalf("onlyPod(one) = %q, %v", pod, err)
	}
	// Two pods behind one primary Service means a selector we cannot trust:
	// refuse rather than pick one, which is how the stale reads happened.
	if _, err := onlyPod("pg-cluster-1 pg-cluster-v18-1"); err == nil || !strings.Contains(err.Error(), "pg-cluster-1") {
		t.Fatalf("onlyPod(two) should fail naming both, got %v", err)
	}
	if _, err := onlyPod("  "); err == nil {
		t.Fatal("onlyPod(none) should fail")
	}
}

func TestShellQuoteEscapes(t *testing.T) {
	if got := shellQuote("a'b"); got != `'a'\''b'` {
		t.Fatalf("shellQuote = %q", got)
	}
}
