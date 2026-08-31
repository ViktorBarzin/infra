package main

import (
	"fmt"
	"sort"
	"strings"
)

// capability is one row of the task-keyed index: what someone is trying to do,
// what to reach for, and which built-in it has to beat.
//
// Why this exists. The 2026-08-31 session study
// (docs/agents/2026-08-31-session-reflection.md) measured 175 sessions and found
// that `homelab services` already listed every capability that got missed — the
// shared Android emulator among them — and was consulted 85 times in 30 days,
// while `logs query` ran 3,037 times. The difference between those two numbers
// is not the inventory. It is that the logs rule names the moment AND the
// built-in it beats ("reach for these BEFORE kubectl logs, journalctl, or
// writing your own client"), and the services rule names only "before reaching
// for an external tool or publishing".
//
// So the index is keyed by the task, in the words people use, and every row that
// exists to beat a built-in says which one. Hand-curated on purpose: a trigger
// is a judgement, and an annotation cannot express one.
type capability struct {
	// Intent is the task in the user's words, not ours.
	Intent string
	// Use is the command or endpoint to reach for. Concrete enough to run.
	Use string
	// Instead names the built-in competitor this has to beat. Empty when there
	// is no rival sitting in the prompt already.
	Instead string
	// Synonyms are the other words someone might use for this task. These are
	// what make `homelab how` and `services --search` find the row without the
	// asker already knowing the answer.
	Synonyms []string
	// Detail carries what the answer needs to be actionable: the wake command,
	// the address, and the limits. A capability's limits belong here, because
	// sending every mobile question at the Android emulator would recreate the
	// wrong-tool problem in the other direction.
	Detail []string
}

// capabilities is the index. Ordered roughly by how often the study saw the
// corresponding miss, which is also a reasonable reading order for a human.
func capabilities() []capability {
	return []capability{
		{
			Intent:  "reproduce or verify a bug someone saw on a phone or tablet",
			Use:     "android-emulator.viktorbarzin.me (shared Android + real Chrome, adb + noVNC)",
			Instead: "a resized desktop browser (Playwright/Chromium at a mobile viewport)",
			Synonyms: []string{"mobile", "phone", "tablet", "android", "touch", "viewport",
				"soft keyboard", "keyboard", "scroll", "device", "reproduce", "repro",
				"real device", "pwa", "responsive", "layout", "his phone", "her phone",
				"my phone", "on the phone", "friend"},
			Detail: []string{
				"claim:  ~/code/scripts/presence claim service:android-emulator --purpose \"...\"",
				"adb:    adb connect 10.0.20.200:5555",
				"why:    a resized desktop browser has no browser chrome, reports pointer:fine",
				"        and cannot raise a soft keyboard, so it cannot verify a phone-only",
				"        layout, scroll-chaining or keyboard bug",
				"NOT:    iOS, Safari or WebKit defects — the Android emulator cannot reproduce",
				"        them and there is no iOS instrument yet. Say which platform you are",
				"        reproducing ON; if the report does not say, ask in one line.",
			},
		},
		{
			Intent:  "reproduce a bug that happens in one browser and not another",
			Use:     "android-emulator.viktorbarzin.me for Chrome/Firefox ON ANDROID (sideload the APK); homelab browser run for a real desktop Chrome",
			Instead: "installing a desktop browser locally via Playwright and calling it the same thing",
			Synonyms: []string{"browser", "firefox", "chrome", "safari", "webkit", "edge",
				"works in chrome", "fails in firefox", "browser-specific", "differential",
				"cross-browser", "one browser", "another browser", "only fails in"},
			Detail: []string{
				"FIRST say which browser ON WHICH PLATFORM you are reproducing. Desktop",
				"        Firefox and mobile Firefox are different bugs, and a report saying",
				"        \"firefox\" rarely says which. Ask in one line rather than guessing.",
				"Android: the emulator runs real Chrome, and Fenix (Firefox) sideloads —",
				"        archive.mozilla.org/pub/fenix/releases/<ver>/android/",
				"NO INSTRUMENT for Safari or any iOS browser: every iOS browser uses the",
				"        system WebKit, the Android emulator cannot reproduce it, and",
				"        Playwright WebKit on Linux is not Safari. Say so plainly instead of",
				"        substituting a browser that is not the one in the report.",
			},
		},
		{
			Intent:  "read logs, metrics, or a systemd journal",
			Use:     "homelab logs query \"<logql>\" --since 24h  /  homelab metrics query \"<promql>\"",
			Instead: "kubectl logs, journalctl, ssh+journalctl, dmesg, or a hand-written Loki client",
			Synonyms: []string{"logs", "log", "journal", "journalctl", "metrics", "prometheus",
				"loki", "dmesg", "errors", "oom", "killed", "why did this box", "syslog"},
			Detail: []string{
				"Loki holds 30 days cluster-wide, Prometheus 26 weeks.",
				"Host journals are in Loki too, not only on the box:",
				"  {job=\"devvm-journal\", unit=\"<x>.service\"}   this workstation",
				"  {job=\"pve-journal\"}                        the Proxmox host",
				"  {job=\"sshd-devvm\"}                         ssh auth",
				"  {job=\"systemd-journal\", host=\"rpi-sofia\"}   the Sofia pi",
				"NOT in Loki: Home Assistant (outside the cluster), and a device's own",
				"        loopback endpoints — those genuinely need the device.",
			},
		},
		{
			Intent:  "read a secret, credential, token, or API key",
			Use:     "homelab vault get <name>  (logins)  /  homelab vault kv get <path>  (infra)",
			Instead: "assuming you have no access because a local binary is missing",
			Synonyms: []string{"secret", "credential", "password", "token", "api key", "apikey",
				"login", "vault", "gcloud", "aws", "console", "access", "auth", "no access"},
			Detail: []string{
				"Two stores: Vaultwarden for logins, HashiCorp Vault/OpenBao kv for infra.",
				"homelab vault search <vendor>   find it by name first",
				"homelab vault kv list secret    what infra paths exist",
				"Before saying \"I have no X access here\", check here and say what you found.",
				"`which <binary>` returning nothing is not evidence about credentials.",
			},
		},
		{
			Intent:  "start, land, or clean up work on a task",
			Use:     "homelab work start <topic>  /  homelab work land  /  homelab work clean",
			Instead: "git worktree add / git push HEAD:master / git worktree remove by hand",
			Synonyms: []string{"worktree", "branch", "land", "merge", "ship", "push",
				"start work", "clean up", "feature"},
			Detail: []string{
				"work start reads the real remote and carries the git-crypt filter flags.",
				"work land merges master in, verifies, pushes HEAD:master and watches CI.",
				"Pass --verify-cmd unless the repo root has a go.mod: auto-detection only",
				"        covers Go, so it errors first try in most repos here.",
			},
		},
		{
			Intent:  "plan, validate, or apply a terraform stack",
			Use:     "homelab tf plan <stack>  /  homelab tf validate <stack>  /  homelab tf apply <stack>",
			Instead: "bare terragrunt, bare terraform, or scripts/tg by absolute path",
			Synonyms: []string{"terraform", "terragrunt", "stack", "plan", "apply", "infra change",
				"tfvars", "state"},
			Detail: []string{
				"Always the full form: `homelab tf <verb> <stack>`. Bare `homelab tf` prints",
				"        unknown command, which reads as \"the verb does not exist\".",
				"A bare terragrunt on a Tier-1 stack dies in \"Initializing the backend\" with",
				"        pq: password authentication failed. That means PG_CONN_STR was never",
				"        set, which only scripts/tg does. It is NOT a permission-tier limit.",
			},
		},
		{
			Intent:  "query a database running in the cluster",
			Use:     "homelab k8s db <app> [--mysql] -- \"<SQL>\"",
			Instead: "kubectl exec ... -- psql / mysql",
			Synonyms: []string{"database", "db", "sql", "postgres", "psql", "mysql", "query",
				"table", "rows"},
			Detail: []string{
				"The study counted 159 hand-rolled kubectl-exec-psql calls across 10 sessions.",
			},
		},
		{
			Intent:  "check whether a service is reachable, or why it is not",
			Use:     "homelab net check <host>[/path]",
			Instead: "a bare curl, which tests only one leg",
			Synonyms: []string{"reachable", "reachability", "down", "unreachable", "dns",
				"external", "internal", "502", "503", "timeout", "connectivity"},
			Detail: []string{
				"Checks external (public DNS -> Cloudflare) and internal (Traefik LB)",
				"        separately, so split-horizon problems are visible rather than",
				"        looking like an outage.",
				"For name resolution specifically: homelab dns lookup <name> diffs",
				"        Technitium (10.0.20.201) against public 1.1.1.1.",
			},
		},
		{
			Intent:  "triage a broken app in the cluster",
			Use:     "homelab k8s debug <app>",
			Instead: "hand-assembling kubectl get/describe/logs/events",
			Synonyms: []string{"broken", "crashloop", "pending", "not starting", "triage",
				"debug", "pod", "deployment", "events", "describe"},
			Detail: []string{
				"One call returns pods (wide) + deploy + describe + recent events + last logs.",
			},
		},
		{
			Intent:  "drive a browser through an anti-bot wall or a signed-in session",
			Use:     "homelab browser run <script.js> [--shared-context]",
			Instead: "the headless Playwright MCP, when it is being blocked",
			Synonyms: []string{"cloudflare", "bot", "captcha", "blocked", "403", "login",
				"signed in", "browser", "scrape", "headful", "chrome"},
			Detail: []string{
				"Default to the headless Playwright MCP; escalate here only when a page loads",
				"        but a gated action silently fails, or the site flags automation.",
				"--shared-context reuses the master's warmed PERSISTENT profile (cookies from",
				"        a manual noVNC login). One profile, no per-context auth, reachable by",
				"        anyone who can drive it. It is not a ToS or safety improvement over a",
				"        plain HTTP client.",
			},
		},
		{
			Intent:  "make a request that must not come from our IP, or must appear from another country",
			Use:     "HTTPS_PROXY=http://proxy-egress-uk.proxy.svc.cluster.local:8888 (SOCKS5 on :1080, the h in socks5h matters)",
			Instead: "making the request directly",
			Synonyms: []string{"geo", "geoblock", "geo-restricted", "vpn", "egress", "another country",
				"uk", "proxy", "not from home"},
			Detail: []string{
				"Always set NO_PROXY=.svc.cluster.local,.cluster.local,localhost,127.0.0.1",
				"        or in-cluster calls take a round trip through the UK.",
				"NOT a way past anti-bot walls: VPN exits sit in hosting ASNs that score",
				"        worse than a residential address. Use homelab browser run for those.",
			},
		},
		{
			Intent:  "see how Claude is used here, or read a past conversation",
			Use:     "homelab claude-usage [--since 30d]  /  homelab claude-usage --session <id|name>",
			Instead: "grep/rg/jq over ~/.claude/projects",
			Synonyms: []string{"transcript", "session", "past conversation", "what did we do",
				"claude usage", "cost", "tokens", "history"},
		},
		{
			Intent:   "remember something across sessions, or recall what we decided",
			Use:      "homelab memory store \"...\"  /  homelab memory recall \"<context>\"",
			Instead:  "a local file under ~/.claude",
			Synonyms: []string{"remember", "memory", "recall", "we decided", "last time", "note"},
			Detail:   []string{"Recall runs automatically each turn, but only on the prompt text at turn start. Query it yourself before a non-obvious mid-turn decision."},
		},
		{
			Intent:   "check a CI pipeline",
			Use:      "homelab ci status [commit]  /  homelab ci watch",
			Instead:  "hand-polling the Woodpecker or GitHub API",
			Synonyms: []string{"ci", "pipeline", "build", "woodpecker", "actions", "deploy status", "green"},
			Detail:   []string{"For a rollout specifically: homelab deploy wait <ns>/<deploy>."},
		},
		{
			Intent:   "share a log, config, snippet, or file with someone",
			Use:      "homelab paste <file|->  (encrypted, expiring)  /  homelab share <file>  (Nextcloud link)",
			Synonyms: []string{"paste", "share", "send file", "link", "pastebin", "upload"},
		},
		{
			Intent:   "publish a finished design doc, plan, or report",
			Use:      "homelab pages publish <doc.md>",
			Synonyms: []string{"publish", "page", "plan", "design doc", "report", "pages"},
		},
		{
			Intent:   "see everything we self-host",
			Use:      "homelab services [--search X]",
			Synonyms: []string{"what do we run", "inventory", "services", "catalog", "self-hosted"},
		},
	}
}

// routingTable keeps the existing two-column contract that formatCatalog and the
// older tests depend on, derived from capabilities() so there is one source of
// truth. Rows that name a competitor say so inline, because that naming is the
// only part with a measured effect on behaviour.
func routingTable() [][2]string {
	caps := capabilities()
	out := make([][2]string, 0, len(caps))
	for _, c := range caps {
		use := c.Use
		if c.Instead != "" {
			use += "   [not: " + c.Instead + "]"
		}
		out = append(out, [2]string{c.Intent, use})
	}
	return out
}

// howStopWords are words that carry no routing signal. Without this, "how do I
// test on a device" matches every row containing "a" or "the".
var howStopWords = map[string]bool{
	"a": true, "an": true, "the": true, "i": true, "do": true, "how": true,
	"to": true, "on": true, "in": true, "of": true, "for": true, "is": true,
	"it": true, "my": true, "me": true, "we": true, "can": true, "want": true,
	"need": true, "should": true, "with": true, "and": true, "or": true,
	"this": true, "that": true, "what": true, "where": true, "when": true,
	"there": true, "from": true, "get": true, "use": true, "using": true,
	"some": true, "any": true, "was": true, "are": true, "be": true,
	// Added after a live miss: "someone" sits in the share/paste intent and was
	// enough on its own to surface that row for "reproduce a bug someone saw on
	// their phone". These carry no routing signal in any query.
	"someone": true, "somebody": true, "their": true, "theirs": true,
	"his": true, "her": true, "hers": true, "saw": true, "seen": true,
	"says": true, "said": true, "told": true, "tell": true, "just": true,
	"really": true, "also": true, "only": true, "but": true, "not": true,
	"one": true, "another": true, "still": true, "again": true, "now": true,
	"then": true, "like": true, "would": true, "could": true, "does": true,
	"doesn": true, "didn": true, "isn": true, "seems": true, "think": true,
	// "chrome works" stemmed onto "work start". Nobody asking about worktrees
	// says "works"; they say worktree, branch, land or ship.
	"works": true, "working": true, "work": false,
}

// capTokens splits text into lowercase routing-relevant words.
func capTokens(s string) []string {
	var out []string
	for _, raw := range strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return !('a' <= r && r <= 'z') && !('0' <= r && r <= '9')
	}) {
		if len(raw) < 2 || howStopWords[raw] {
			continue
		}
		out = append(out, raw)
	}
	return out
}

// matchCapabilities ranks the index against a free-text task description and
// returns only rows with real overlap. Returning nothing for an unrelated query
// is deliberate: an index that always answers is noise, and the study's whole
// finding is that noise gets ignored.
func matchCapabilities(caps []capability, task string) []capability {
	q := capTokens(task)
	if len(q) == 0 {
		return nil
	}
	type scored struct {
		c capability
		n int
		i int
	}
	var hits []scored
	for i, c := range caps {
		// Intent words are weighted above synonyms: a word in the task
		// description itself is a stronger signal than one in the widening
		// list, and without the split a single incidental synonym hit
		// ("someone" in the share row) outranked a genuine match.
		hay := map[string]int{}
		for _, t := range capTokens(strings.Join(c.Synonyms, " ")) {
			hay[t] = 2
		}
		for _, t := range capTokens(c.Intent) {
			hay[t] = 3
		}
		// Multi-word synonyms should count when the query contains the phrase.
		phrase := strings.ToLower(c.Intent + " " + strings.Join(c.Synonyms, " "))
		n := 0
		for _, t := range q {
			if w, ok := hay[t]; ok {
				n += w
				continue
			}
			// Prefix match catches plurals and simple inflections
			// ("logs"/"log", "reproducing"/"reproduce").
			for h, w := range hay {
				if len(t) >= 4 && (strings.HasPrefix(h, t) || strings.HasPrefix(t, h)) {
					n += w
					break
				}
			}
		}
		for i := 0; i+1 < len(q); i++ {
			if strings.Contains(phrase, q[i]+" "+q[i+1]) {
				n += 3
			}
		}
		// Floor of 2: one weak synonym brush is not a match. An index that
		// answers everything gets ignored, which is the failure being fixed.
		if n >= 2 {
			hits = append(hits, scored{c: c, n: n, i: i})
		}
	}
	sort.SliceStable(hits, func(a, b int) bool {
		if hits[a].n != hits[b].n {
			return hits[a].n > hits[b].n
		}
		return hits[a].i < hits[b].i
	})
	out := make([]capability, 0, len(hits))
	for _, h := range hits {
		out = append(out, h.c)
	}
	return out
}

// formatHow renders the answer to `homelab how "<task>"`. Viktor reads these on
// a phone, so the command comes with the answer rather than a pointer to where
// the command is documented.
func formatHow(hits []capability, task string) string {
	var b strings.Builder
	if len(hits) == 0 {
		fmt.Fprintf(&b, "No capability indexed for %q.\n\n", task)
		b.WriteString("Try different words, or read the full inventory:\n")
		b.WriteString("  homelab services [--search X]\n")
		b.WriteString("If we genuinely do not have it, that is worth an issue: /file-issue\n")
		return b.String()
	}
	fmt.Fprintf(&b, "For %q:\n", task)
	const max = 3
	for i, c := range hits {
		if i >= max {
			fmt.Fprintf(&b, "\n  ... %d more, run `homelab services` for the full inventory\n", len(hits)-max)
			break
		}
		fmt.Fprintf(&b, "\n  %s\n", c.Intent)
		fmt.Fprintf(&b, "    use:    %s\n", c.Use)
		if c.Instead != "" {
			fmt.Fprintf(&b, "    NOT:    %s\n", c.Instead)
		}
		for _, d := range c.Detail {
			fmt.Fprintf(&b, "    %s\n", d)
		}
	}
	return b.String()
}
