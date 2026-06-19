package main

import (
	"fmt"
	"strings"
	"time"
)

func netCommands() []Command {
	return []Command{
		{Path: []string{"net", "check"}, Tier: TierRead,
			Summary: "reachability of <host>[/path]: external (public DNS→CF) vs internal (Traefik LB)", Run: netCheck},
		{Path: []string{"dns", "lookup"}, Tier: TierRead,
			Summary: "resolve <name> via Technitium (10.0.20.201) and public (1.1.1.1), diffed", Run: dnsLookup},
	}
}

func fmtProbe(code int, d time.Duration, err error) string {
	if err != nil {
		return "ERR " + err.Error()
	}
	return fmt.Sprintf("HTTP %d  %dms", code, d.Milliseconds())
}

func netCheck(args []string) error {
	host, rest := firstPositional(args)
	if host == "" {
		return fmt.Errorf("usage: homelab net check <host> [path]")
	}
	path := "/"
	if len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
		path = rest[0]
		if !strings.HasPrefix(path, "/") {
			path = "/" + path
		}
	}
	u := "https://" + host + path
	fmt.Printf("%s\n", u)

	// external leg: resolve via public DNS, dial the public IP (tests the real CF path)
	pubOut, _ := dig(hostOnly(host), "1.1.1.1", "")
	if pubIP := firstLine(pubOut); pubIP != "" {
		c, d, e := probeURL(clientDialingIP(pubIP, 10*time.Second), u)
		fmt.Printf("  external (public %-15s) %s\n", pubIP, fmtProbe(c, d, e))
	} else {
		fmt.Println("  external (public)            no public A record")
	}
	// internal leg: dial the Traefik LB directly
	c, d, e := probeURL(clientDialingIP(internalLBIP, 10*time.Second), u)
	fmt.Printf("  internal (LB %-15s)     %s\n", internalLBIP, fmtProbe(c, d, e))
	return nil
}

func dnsLookup(args []string) error {
	name, rest := firstPositional(args)
	if name == "" {
		return fmt.Errorf("usage: homelab dns lookup <name> [A|AAAA|TXT|MX|PTR]")
	}
	rr := ""
	if len(rest) > 0 {
		rr = rest[0]
	}
	tech, _ := dig(name, "10.0.20.201", rr)
	pub, _ := dig(name, "1.1.1.1", rr)
	fmt.Printf("technitium (10.0.20.201): %s\n", oneLineList(tech))
	fmt.Printf("public     (1.1.1.1)    : %s\n", oneLineList(pub))
	if strings.TrimSpace(tech) != strings.TrimSpace(pub) {
		fmt.Println("⚠ mismatch — split-horizon (expected for internal-only apps) or a propagation gap")
	}
	return nil
}

func hostOnly(h string) string { // strip any path accidentally included
	return strings.SplitN(h, "/", 2)[0]
}

func oneLineList(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return "(none)"
	}
	return strings.ReplaceAll(s, "\n", ", ")
}
