package main

import (
	"fmt"
	"os/exec"
	"strings"
)

// kubectl helpers use the ambient kubeconfig (no per-call auth flags).

func kubectlBase(ns string, args ...string) []string {
	var full []string
	if ns != "" {
		full = append(full, "-n", ns)
	}
	return append(full, args...)
}

func kubectlStream(ns string, args ...string) error {
	return runStreamingIn("", "kubectl", kubectlBase(ns, args...)...)
}

// kubectlCapture runs kubectl and returns trimmed stdout (for resolving pods).
func kubectlCapture(ns string, args ...string) (string, error) {
	out, err := exec.Command("kubectl", kubectlBase(ns, args...)...).Output()
	return strings.TrimSpace(string(out)), err
}

// k8sTarget is the parsed `<app>` + selectors shared by the k8s verbs.
type k8sTarget struct {
	app       string
	ns        string
	pod       string
	container string
	selector  string
	tty       bool
	rest      []string // passthrough flags and, after `--`, the exec command
}

// parseK8sTarget reads `<app> [-n ns] [--pod p] [-c ctr] [-l sel] [flags] [-- cmd]`.
// The first bare token is the app; unknown flags pass through in rest.
func parseK8sTarget(args []string) k8sTarget {
	t := k8sTarget{}
	i := 0
	take := func() string {
		if i+1 < len(args) {
			i++
			return args[i]
		}
		return ""
	}
	for i = 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--":
			t.rest = append(t.rest, args[i+1:]...)
			return t
		case a == "-n" || a == "--namespace":
			t.ns = take()
		case strings.HasPrefix(a, "--namespace="):
			t.ns = strings.TrimPrefix(a, "--namespace=")
		case a == "--pod":
			t.pod = take()
		case strings.HasPrefix(a, "--pod="):
			t.pod = strings.TrimPrefix(a, "--pod=")
		case a == "-c" || a == "--container":
			t.container = take()
		case strings.HasPrefix(a, "--container="):
			t.container = strings.TrimPrefix(a, "--container=")
		case a == "-l" || a == "--selector":
			t.selector = take()
		case strings.HasPrefix(a, "--selector="):
			t.selector = strings.TrimPrefix(a, "--selector=")
		case a == "--tty" || a == "-it" || a == "-ti":
			t.tty = true
		case !strings.HasPrefix(a, "-") && t.app == "":
			t.app = a
		default:
			t.rest = append(t.rest, a)
		}
	}
	return t
}

// namespace defaults to the app name (most namespaces hold exactly one app).
func (t k8sTarget) namespace() string {
	if t.ns != "" {
		return t.ns
	}
	return t.app
}

// objectRef is the kubectl object for logs/exec: an explicit pod, else
// deploy/<app> (kubectl resolves a pod from the Deployment).
func (t k8sTarget) objectRef() string {
	if t.pod != "" {
		return "pod/" + t.pod
	}
	return "deploy/" + t.app
}

// --- database access (the dbaas exec pattern) ---

type dbPlan struct {
	ns        string
	pod       string   // explicit pod (e.g. mysql-standalone-0)
	selector  string   // resolve the pod by this label when pod == "" (CNPG primary)
	container string   // "" = default container
	argv      []string // command + args to run inside the pod
}

// planDBExec builds the in-pod command to run sql against app's database.
// PG (default): CNPG primary POD (resolved by label — pg-cluster-rw is a
// Service, not an exec target), psql -U postgres -d <db>.
// MySQL: mysql-standalone-0, password from env (never on the command line).
// dbName defaults to app. sql empty => interactive client.
func planDBExec(app, dbName, sql string, mysql bool) dbPlan {
	if dbName == "" {
		dbName = app
	}
	if mysql {
		inner := fmt.Sprintf(`mysql -u root -p"$MYSQL_ROOT_PASSWORD" %s`, shellQuote(dbName))
		if sql != "" {
			inner += " -e " + shellQuote(sql)
		}
		return dbPlan{ns: "dbaas", pod: "mysql-standalone-0", argv: []string{"bash", "-c", inner}}
	}
	argv := []string{"psql", "-U", "postgres", "-d", dbName}
	if sql != "" {
		argv = append(argv, "-tAc", sql)
	}
	return dbPlan{ns: "dbaas", selector: "cnpg.io/instanceRole=primary", container: "postgres", argv: argv}
}

// shellQuote single-quotes s for safe embedding in a bash -c string.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
