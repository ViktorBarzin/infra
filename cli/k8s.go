package main

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
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
	service   string   // the Service the apps connect through; its selector names the pod
	container string   // "" = default container
	argv      []string // command + args to run inside the pod
}

// planDBExec builds the in-pod command to run sql against app's database.
// The pod is the one behind the Service the apps themselves use: `postgresql`
// for Postgres, `mysql` for MySQL. A major-version cutover is a blue-green
// swap of that Service's selector, with the old cluster left running frozen,
// so following the Service is what keeps reads on the live data. (On
// 2026-10-15 the label cnpg.io/instanceRole=primary matched both pg-cluster-1
// and pg-cluster-v18-1, and the frozen one came first.)
// PG: psql -U postgres -d <db>. MySQL: password from env (never on the
// command line). dbName defaults to app. sql empty => interactive client.
func planDBExec(app, dbName, sql string, mysql bool) dbPlan {
	if dbName == "" {
		dbName = app
	}
	if mysql {
		inner := fmt.Sprintf(`mysql -u root -p"$MYSQL_ROOT_PASSWORD" %s`, shellQuote(dbName))
		if sql != "" {
			inner += " -e " + shellQuote(sql)
		}
		return dbPlan{ns: "dbaas", service: "mysql", argv: []string{"bash", "-c", inner}}
	}
	argv := []string{"psql", "-U", "postgres", "-d", dbName}
	if sql != "" {
		argv = append(argv, "-tAc", sql)
	}
	return dbPlan{ns: "dbaas", service: "postgresql", container: "postgres", argv: argv}
}

// labelSelectorFromService turns a Service's `.spec.selector` (as JSON) into
// a `-l` label selector, keys sorted. An empty selector is an error: it
// would match every pod in the namespace.
func labelSelectorFromService(raw string) (string, error) {
	var sel map[string]string
	if err := json.Unmarshal([]byte(raw), &sel); err != nil {
		return "", fmt.Errorf("service selector %q is not a label map: %v", raw, err)
	}
	if len(sel) == 0 {
		return "", fmt.Errorf("service has no selector")
	}
	keys := make([]string, 0, len(sel))
	for k := range sel {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = k + "=" + sel[k]
	}
	return strings.Join(parts, ","), nil
}

// onlyPod returns the single pod name in a space-separated list, or an error
// naming what was found. A primary Service backed by two pods is a cutover in
// flight or a broken selector, and picking either would be a guess.
func onlyPod(names string) (string, error) {
	pods := strings.Fields(names)
	if len(pods) != 1 {
		return "", fmt.Errorf("expected exactly one pod, found %d: %v", len(pods), pods)
	}
	return pods[0], nil
}

// resolveServicePod finds the one running pod behind ns/service.
func resolveServicePod(ns, service string) (string, error) {
	raw, err := kubectlCapture(ns, "get", "service", service, "-o", "jsonpath={.spec.selector}")
	if err != nil {
		return "", fmt.Errorf("could not read service %s/%s: %v", ns, service, err)
	}
	sel, err := labelSelectorFromService(raw)
	if err != nil {
		return "", fmt.Errorf("service %s/%s: %v", ns, service, err)
	}
	names, err := kubectlCapture(ns, "get", "pod", "-l", sel,
		"--field-selector=status.phase=Running", "-o", "jsonpath={.items[*].metadata.name}")
	if err != nil {
		return "", fmt.Errorf("could not list pods for %s/%s (%s): %v", ns, service, sel, err)
	}
	pod, err := onlyPod(names)
	if err != nil {
		return "", fmt.Errorf("service %s/%s (%s): %v", ns, service, sel, err)
	}
	return pod, nil
}

// shellQuote single-quotes s for safe embedding in a bash -c string.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
