package main

import (
	"fmt"
	"os"
	"strings"
)

func k8sCommands() []Command {
	return []Command{
		{Path: []string{"k8s", "status"}, Tier: TierRead,
			Summary: "pods (wide) + recent non-Normal events for a namespace (or -A)", Run: k8sStatus},
		{Path: []string{"k8s", "get"}, Tier: TierRead,
			Summary: "kubectl get in a namespace: k8s get <ns> <resource> [args]", Run: k8sGet},
		{Path: []string{"k8s", "logs"}, Tier: TierRead,
			Summary: "logs for <app> (deploy/<app>; --tail/-c/--previous/--since/-l)", Run: k8sLogs},
		{Path: []string{"k8s", "describe"}, Tier: TierRead,
			Summary: "describe <app>'s deployment (or an explicit resource)", Run: k8sDescribe},
		{Path: []string{"k8s", "debug"}, Tier: TierRead,
			Summary: "one-shot triage for <app>: pods+deploy+describe+logs+events", Run: k8sDebug},
		{Path: []string{"k8s", "pf"}, Tier: TierRead,
			Summary: "port-forward: k8s pf <app> <local:remote> [svc/pod target]", Run: k8sPortForward},
		{Path: []string{"k8s", "db"}, Tier: TierWrite,
			Summary: `query a dbaas DB: k8s db <app> [--mysql] [--db N] -- "<SQL>"`, Run: k8sDB},
		{Path: []string{"k8s", "exec"}, Tier: TierWrite,
			Summary: "exec in <app>'s pod: k8s exec <app> [--tty] -- <cmd>", Run: k8sExec},
		{Path: []string{"k8s", "rm-pod"}, Tier: TierWrite,
			Summary: "delete a stuck pod/job ONLY: k8s rm-pod <name> -n <ns> [--job] [--force]", Run: k8sRmPod},
		{Path: []string{"k8s", "rollout-status"}, Tier: TierRead,
			Summary: "rollout status of deploy/<app>", Run: k8sRolloutStatus},
		{Path: []string{"k8s", "restart"}, Tier: TierWrite,
			Summary: "rollout restart deploy/<app> then wait for status", Run: k8sRestart},
		{Path: []string{"k8s", "probe"}, Tier: TierRead,
			Summary: "in-cluster reachability: ephemeral curl pod to <app>.<ns>.svc", Run: k8sProbe},
	}
}

func k8sStatus(args []string) error {
	t := parseK8sTarget(args)
	ns := t.namespace() // "" when no app/ns given → cluster-wide
	get := []string{"get", "pods", "-o", "wide"}
	ev := []string{"get", "events", "--field-selector", "type!=Normal", "--sort-by=.lastTimestamp"}
	if ns == "" {
		get = append(get, "-A")
		ev = append(ev, "-A")
	}
	if err := kubectlStream(ns, get...); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "\n--- recent events (type!=Normal) ---")
	_ = kubectlStream(ns, ev...) // best-effort
	return nil
}

func k8sGet(args []string) error {
	t := parseK8sTarget(args)
	if t.app == "" || len(t.rest) == 0 {
		return fmt.Errorf("usage: homelab k8s get <ns> <resource> [args]")
	}
	return kubectlStream(t.app, append([]string{"get"}, t.rest...)...)
}

func k8sLogs(args []string) error {
	t := parseK8sTarget(args)
	if t.app == "" {
		return fmt.Errorf("usage: homelab k8s logs <app> [--tail N] [-c ctr] [--previous] [--since 1h] [-l sel]")
	}
	a := []string{"logs"}
	if t.selector != "" {
		a = append(a, "-l", t.selector)
	} else {
		a = append(a, t.objectRef())
	}
	if t.container != "" {
		a = append(a, "-c", t.container)
	}
	if !containsPrefix(t.rest, "--tail") {
		a = append(a, "--tail=200")
	}
	a = append(a, t.rest...)
	return kubectlStream(t.namespace(), a...)
}

func k8sDescribe(args []string) error {
	t := parseK8sTarget(args)
	if t.app == "" {
		return fmt.Errorf("usage: homelab k8s describe <app> [resource]")
	}
	if len(t.rest) > 0 {
		return kubectlStream(t.namespace(), append([]string{"describe"}, t.rest...)...)
	}
	return kubectlStream(t.namespace(), "describe", t.objectRef())
}

func k8sDebug(args []string) error {
	t := parseK8sTarget(args)
	if t.app == "" {
		return fmt.Errorf("usage: homelab k8s debug <app>")
	}
	ns := t.namespace()
	sec := func(title string) { fmt.Fprintf(os.Stderr, "\n=== %s ===\n", title) }
	sec("pods")
	_ = kubectlStream(ns, "get", "pods", "-o", "wide")
	sec("workloads")
	_ = kubectlStream(ns, "get", "deploy,sts,ds", "-o", "wide")
	sec("describe "+t.objectRef())
	_ = kubectlStream(ns, "describe", t.objectRef())
	sec("recent logs (--tail=50)")
	_ = kubectlStream(ns, "logs", t.objectRef(), "--tail=50")
	sec("events (type!=Normal)")
	_ = kubectlStream(ns, "get", "events", "--field-selector", "type!=Normal", "--sort-by=.lastTimestamp")
	return nil
}

func k8sPortForward(args []string) error {
	t := parseK8sTarget(args)
	if t.app == "" || len(t.rest) == 0 {
		return fmt.Errorf("usage: homelab k8s pf <app> <local:remote> [svc/pod target]")
	}
	ports := t.rest[0]
	target := "svc/" + t.app
	if len(t.rest) > 1 {
		target = t.rest[1]
	}
	return kubectlStream(t.namespace(), "port-forward", target, ports)
}

func k8sDB(args []string) error {
	var app, dbName, sql string
	mysql := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			sql = strings.Join(args[i+1:], " ")
			break
		}
		switch {
		case a == "--mysql":
			mysql = true
		case a == "--db":
			if i+1 < len(args) {
				dbName = args[i+1]
				i++
			}
		case strings.HasPrefix(a, "--db="):
			dbName = strings.TrimPrefix(a, "--db=")
		case !strings.HasPrefix(a, "-") && app == "":
			app = a
		}
	}
	if app == "" {
		return fmt.Errorf(`usage: homelab k8s db <app> [--mysql] [--db NAME] -- "<SQL>"`)
	}
	p := planDBExec(app, dbName, sql, mysql)
	pod := p.pod
	if pod == "" && p.selector != "" {
		resolved, err := kubectlCapture(p.ns, "get", "pod", "-l", p.selector, "-o", "jsonpath={.items[0].metadata.name}")
		if err != nil || resolved == "" {
			return fmt.Errorf("could not resolve db pod in %s (selector %q): %v", p.ns, p.selector, err)
		}
		pod = resolved
	}
	exec := []string{"exec"}
	if sql == "" {
		exec = append(exec, "-it") // interactive client when no SQL given
	}
	exec = append(exec, pod)
	if p.container != "" {
		exec = append(exec, "-c", p.container)
	}
	exec = append(exec, "--")
	exec = append(exec, p.argv...)
	return kubectlStream(p.ns, exec...)
}

func k8sExec(args []string) error {
	t := parseK8sTarget(args)
	if t.app == "" {
		return fmt.Errorf("usage: homelab k8s exec <app> [--pod p] [-c ctr] [--tty] -- <cmd>")
	}
	if len(t.rest) == 0 {
		return fmt.Errorf("provide a command after --, e.g. homelab k8s exec %s -- env", t.app)
	}
	a := []string{"exec"}
	if t.tty {
		a = append(a, "-it")
	}
	a = append(a, t.objectRef())
	if t.container != "" {
		a = append(a, "-c", t.container)
	}
	a = append(a, "--")
	a = append(a, t.rest...)
	return kubectlStream(t.namespace(), a...)
}

func k8sRmPod(args []string) error {
	var pod, ns, grace string
	force, job := false, false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-n" || a == "--namespace":
			if i+1 < len(args) {
				ns = args[i+1]
				i++
			}
		case a == "--force":
			force = true
		case a == "--job":
			job = true
		case a == "--grace":
			if i+1 < len(args) {
				grace = args[i+1]
				i++
			}
		case !strings.HasPrefix(a, "-") && pod == "":
			pod = a
		}
	}
	if pod == "" || ns == "" {
		return fmt.Errorf("usage: homelab k8s rm-pod <name> -n <ns> [--job] [--force] [--grace N] (pods/jobs only)")
	}
	kind := "pod"
	if job {
		kind = "job"
	}
	a := []string{"delete", kind, pod}
	if grace != "" {
		a = append(a, "--grace-period="+grace)
	}
	if force {
		a = append(a, "--force")
	}
	return kubectlStream(ns, a...)
}

func k8sRolloutStatus(args []string) error {
	t := parseK8sTarget(args)
	if t.app == "" {
		return fmt.Errorf("usage: homelab k8s rollout-status <app>")
	}
	return kubectlStream(t.namespace(), "rollout", "status", "deploy/"+t.app)
}

func k8sRestart(args []string) error {
	t := parseK8sTarget(args)
	if t.app == "" {
		return fmt.Errorf("usage: homelab k8s restart <app>")
	}
	ns := t.namespace()
	if err := kubectlStream(ns, "rollout", "restart", "deploy/"+t.app); err != nil {
		return err
	}
	return kubectlStream(ns, "rollout", "status", "deploy/"+t.app)
}

func k8sProbe(args []string) error {
	t := parseK8sTarget(args)
	if t.app == "" {
		return fmt.Errorf("usage: homelab k8s probe <app> [path] [--port N]")
	}
	ns := t.namespace()
	url := "http://" + t.app + "." + ns + ".svc.cluster.local"
	if port := flagValue(args, "--port"); port != "" {
		url += ":" + port
	}
	if len(t.rest) > 0 {
		p := t.rest[0]
		if !strings.HasPrefix(p, "/") {
			p = "/" + p
		}
		url += p
	}
	return kubectlStream(ns, "run", "homelab-probe", "--rm", "-i", "--restart=Never",
		"--image=curlimages/curl:latest", "--",
		"curl", "-sS", "--max-time", "10", "-w", "\n[%{http_code}] %{time_total}s\n", url)
}

// containsPrefix reports whether any arg starts with prefix.
func containsPrefix(args []string, prefix string) bool {
	for _, a := range args {
		if strings.HasPrefix(a, prefix) {
			return true
		}
	}
	return false
}
