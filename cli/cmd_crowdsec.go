package main

import (
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"
)

// The `crowdsec` verbs wrap `cscli decisions add/delete` on the LAPI pod so a
// manual ban carries a bounded lifetime and a written reason.
//
// Why the cap exists: on 2026-08-16 our own London WAN egress IP
// (137.220.71.46) was banned by hand for 8717h — 363 days. A Linkwarden
// /api/v1/search 401 retry loop was traced to the address, and its reverse DNS
// (71.220.137.46.bcube.co.uk) read as an unrelated third party rather than as
// our own ISP's PTR domain; the traffic was in fact our own Mac. Because every
// LAPI decision is also pushed to the Cloudflare edge list, the ban eventually
// locked Viktor out of every proxied host, and a year-long expiry meant nothing
// would have cleared it on its own.
//
// A short ban costs little when it is right and expires on its own when it is
// wrong, so `ban` defaults to 24h and refuses anything beyond 7d. Deliberately
// long-lived blocks belong in the external blocklist import (stacks/crowdsec),
// which is reviewable in git, rather than in an ad-hoc cscli invocation.

const (
	// crowdsecDefaultBan is the duration used when --duration is omitted.
	crowdsecDefaultBan = 24 * time.Hour
	// crowdsecMaxBan is the longest ban this CLI will create (7 days).
	crowdsecMaxBan = 168 * time.Hour

	crowdsecNamespace    = "crowdsec"
	crowdsecLapiSelector = "k8s-app=crowdsec,type=lapi"
)

func crowdsecCommands() []Command {
	return []Command{
		{Path: []string{"crowdsec", "ban"}, Tier: TierWrite,
			Summary: "ban an IP/CIDR with a bounded expiry: crowdsec ban <ip|cidr> --reason \"why\" [--duration 24h, max 168h]", Run: crowdsecBan},
		{Path: []string{"crowdsec", "unban"}, Tier: TierWrite,
			Summary: "remove every decision for an IP/CIDR: crowdsec unban <ip|cidr>", Run: crowdsecUnban},
		{Path: []string{"crowdsec", "decisions"}, Tier: TierRead,
			Summary: "list local CrowdSec decisions (add --all to include the community blocklist)", Run: crowdsecDecisions},
		{Path: []string{"crowdsec"}, Tier: TierRead,
			Summary: "CrowdSec decisions with a bounded manual-ban lifetime (run `homelab crowdsec` for help)",
			Run:     func([]string) error { fmt.Print(crowdsecHelp()); return nil }},
	}
}

func crowdsecHelp() string {
	return `homelab crowdsec — manual CrowdSec decisions with a bounded lifetime

  homelab crowdsec ban <ip|cidr> --reason "why" [--duration 24h]
        Ban with an expiry. Default 24h, hard cap 168h (7d). A reason is
        required — it is the only record of why the block exists.
  homelab crowdsec unban <ip|cidr>    delete every decision for the address
  homelab crowdsec decisions [--all]  list decisions (--all includes CAPI)

Bans are enforced in two places: the node firewall bouncer (all traffic) and
the Cloudflare edge IP list for proxied hosts. The edge list is slow to
correct — Cloudflare rate-limits Lists writes hard — so prefer a short expiry
over trusting that you can undo a long one quickly.

Blocks meant to be permanent belong in the reviewable external blocklist
import (stacks/crowdsec), not in a manual decision.
`
}

// --- pure, tested helpers --------------------------------------------------

// humanDuration renders a duration without Go's trailing zero components, so
// the cap reads as "168h" rather than "168h0m0s". Only whole-zero trailing
// components are dropped, which keeps short durations like "10s" intact.
func humanDuration(d time.Duration) string {
	s := d.String()
	if strings.HasSuffix(s, "m0s") {
		s = strings.TrimSuffix(s, "0s")
	}
	if strings.HasSuffix(s, "h0m") {
		s = strings.TrimSuffix(s, "0m")
	}
	return s
}

// parseBanDuration accepts Go durations plus a `d` (days) suffix, defaults to
// crowdsecDefaultBan when empty, and refuses anything non-positive or beyond
// crowdsecMaxBan.
func parseBanDuration(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return crowdsecDefaultBan, nil
	}
	var d time.Duration
	if days, ok := strings.CutSuffix(s, "d"); ok {
		n, err := strconv.ParseFloat(days, 64)
		if err != nil {
			return 0, fmt.Errorf("invalid duration %q: want something like 30m, 4h or 3d", s)
		}
		d = time.Duration(n * float64(24*time.Hour))
	} else {
		parsed, err := time.ParseDuration(s)
		if err != nil {
			return 0, fmt.Errorf("invalid duration %q: want something like 30m, 4h or 3d", s)
		}
		d = parsed
	}
	if d <= 0 {
		return 0, fmt.Errorf("duration %q must be positive", s)
	}
	if d > crowdsecMaxBan {
		return 0, fmt.Errorf("duration %s exceeds the %s cap for a manual ban; use a shorter expiry, or add the address to the reviewable blocklist import in stacks/crowdsec if it should be blocked indefinitely", humanDuration(d), humanDuration(crowdsecMaxBan))
	}
	return d, nil
}

// validateBanRequest checks the ban target is a literal IP or CIDR and that a
// reason was given.
func validateBanRequest(target, reason string) error {
	target = strings.TrimSpace(target)
	if target == "" {
		return fmt.Errorf("an IP or CIDR to ban is required")
	}
	if strings.Contains(target, "/") {
		if _, _, err := net.ParseCIDR(target); err != nil {
			return fmt.Errorf("%q is not a valid CIDR", target)
		}
	} else if net.ParseIP(target) == nil {
		return fmt.Errorf("%q is not a valid IP address (hostnames are not bannable — resolve it first, and check the address is not our own egress)", target)
	}
	if strings.TrimSpace(reason) == "" {
		return fmt.Errorf("--reason is required: a ban with no stated reason cannot be reviewed or safely undone later")
	}
	return nil
}

// parseCrowdsecBanArgs pulls the target, --reason and --duration out of argv.
func parseCrowdsecBanArgs(args []string) (target, reason, duration string, err error) {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--reason", "-r":
			if i+1 >= len(args) {
				return "", "", "", fmt.Errorf("--reason needs a value")
			}
			reason = args[i+1]
			i++
		case "--duration", "-d":
			if i+1 >= len(args) {
				return "", "", "", fmt.Errorf("--duration needs a value")
			}
			duration = args[i+1]
			i++
		default:
			if strings.HasPrefix(args[i], "-") {
				return "", "", "", fmt.Errorf("unknown flag %q", args[i])
			}
			if target != "" {
				return "", "", "", fmt.Errorf("expected one target, got %q and %q", target, args[i])
			}
			target = args[i]
		}
	}
	return target, reason, duration, nil
}

// --- runners ---------------------------------------------------------------

func crowdsecLapiPod() (string, error) {
	out, err := kubectlCapture(crowdsecNamespace, "get", "pods", "-l", crowdsecLapiSelector,
		"--field-selector=status.phase=Running", "-o", "name")
	if err != nil {
		return "", fmt.Errorf("could not find the CrowdSec LAPI pod: %w", err)
	}
	for _, line := range strings.Split(out, "\n") {
		if p := strings.TrimPrefix(strings.TrimSpace(line), "pod/"); p != "" {
			return p, nil
		}
	}
	return "", fmt.Errorf("no running CrowdSec LAPI pod in namespace %s", crowdsecNamespace)
}

func crowdsecBan(args []string) error {
	target, reason, durationArg, err := parseCrowdsecBanArgs(args)
	if err != nil {
		return err
	}
	if err := validateBanRequest(target, reason); err != nil {
		return err
	}
	d, err := parseBanDuration(durationArg)
	if err != nil {
		return err
	}
	pod, err := crowdsecLapiPod()
	if err != nil {
		return err
	}
	if err := kubectlStream(crowdsecNamespace, "exec", pod, "--",
		"cscli", "decisions", "add", "--ip", target, "--duration", humanDuration(d), "--reason", reason); err != nil {
		return fmt.Errorf("cscli decisions add failed: %w", err)
	}
	fmt.Printf("banned %s for %s — expires on its own; `homelab crowdsec unban %s` to lift it sooner\n", target, humanDuration(d), target)
	fmt.Println("note: proxied hosts are enforced via the Cloudflare edge list, which can lag by hours (Cloudflare rate-limits Lists writes)")
	return nil
}

func crowdsecUnban(args []string) error {
	if len(args) != 1 || strings.HasPrefix(args[0], "-") {
		return fmt.Errorf("usage: homelab crowdsec unban <ip|cidr>")
	}
	target := strings.TrimSpace(args[0])
	if err := validateBanRequest(target, "unban needs no reason"); err != nil {
		return err
	}
	pod, err := crowdsecLapiPod()
	if err != nil {
		return err
	}
	if err := kubectlStream(crowdsecNamespace, "exec", pod, "--",
		"cscli", "decisions", "delete", "--ip", target); err != nil {
		return fmt.Errorf("cscli decisions delete failed: %w", err)
	}
	fmt.Printf("removed local decisions for %s\n", target)
	fmt.Println("note: the Cloudflare edge list is reconciled by the crowdsec-cf-sync CronJob and may lag; check `homelab crowdsec decisions` plus the list itself if a proxied host still blocks")
	return nil
}

func crowdsecDecisions(args []string) error {
	pod, err := crowdsecLapiPod()
	if err != nil {
		return err
	}
	cmd := []string{"exec", pod, "--", "cscli", "decisions", "list"}
	if containsArg(args, "--all") {
		cmd = append(cmd, "-a")
	}
	return kubectlStream(crowdsecNamespace, cmd...)
}
