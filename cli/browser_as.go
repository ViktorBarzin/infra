package main

// `homelab browser as <user> --reason <why>`: start an impersonation and print
// its Authentik session for a browser this command does not drive: the
// Playwright MCP browser or a T3 preview tab. `--end` logs the session out.
//
// `browser run|open --as` owns the whole lifecycle of its browser. Here the
// agent's own browser outlives this process, so the session is kept in a 0600
// file under the user cache dir until `--end` logs it out. The printed cookies
// are a live sign-in as the target user: Viktor accepted them in the agent's
// transcript (2026-11-15), because transcripts are never shared.

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

type browserAsOpts struct {
	user, reason, format string
	end, help            bool
}

func parseBrowserAsArgs(args []string) (browserAsOpts, error) {
	o := browserAsOpts{format: "json"}
	var users []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		next := func() (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s needs a value", a)
			}
			i++
			return args[i], nil
		}
		var err error
		switch {
		case a == "-h" || a == "--help":
			o.help = true
		case a == "--end":
			o.end = true
		case a == "--reason":
			o.reason, err = next()
		case strings.HasPrefix(a, "--reason="):
			o.reason = strings.TrimPrefix(a, "--reason=")
		case a == "--format":
			o.format, err = next()
		case strings.HasPrefix(a, "--format="):
			o.format = strings.TrimPrefix(a, "--format=")
		case strings.HasPrefix(a, "-"):
			err = fmt.Errorf("unknown flag %s", a)
		default:
			users = append(users, a)
		}
		if err != nil {
			return o, err
		}
	}
	if o.help {
		return o, nil
	}
	if len(users) > 1 {
		return o, fmt.Errorf("one user at a time, got %s", strings.Join(users, " "))
	}
	if len(users) == 1 {
		o.user = users[0]
	}
	if o.end {
		return o, nil
	}
	if o.user == "" {
		return o, errors.New("usage: homelab browser as <user> --reason \"<why>\" [--format json|playwright|t3]")
	}
	if strings.TrimSpace(o.reason) == "" {
		return o, errors.New("--reason is required: Authentik records it with the impersonation")
	}
	switch o.format {
	case "json", "playwright", "t3":
	default:
		return o, fmt.Errorf("--format %s: want json, playwright or t3", o.format)
	}
	return o, nil
}

// savedSession is what `--end` needs to log a session out later.
type savedSession struct {
	BaseURL        string     `json:"base_url"`
	Requested      string     `json:"requested"`
	TargetUsername string     `json:"target_username"`
	TargetPK       int        `json:"target_pk"`
	Started        time.Time  `json:"started"`
	Cookies        []pwCookie `json:"cookies"`
}

func impersonationDir() (string, error) {
	d, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "homelab", "impersonation"), nil
}

var unsafeFileChars = regexp.MustCompile(`[^A-Za-z0-9._@-]`)

// saveSession writes the session to <dir>/<username>.json, mode 0600.
func saveSession(dir string, im *impersonation, requested string) (string, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return "", err
	}
	b, err := json.Marshal(savedSession{
		BaseURL: im.base.String(), Requested: requested, TargetUsername: im.TargetUsername,
		TargetPK: im.TargetPK, Started: time.Now().UTC(), Cookies: im.cookies(),
	})
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, unsafeFileChars.ReplaceAllString(im.TargetUsername, "_")+".json")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return "", err
	}
	return path, os.Rename(tmp, path)
}

// findSessions lists saved session files for a user (its username or the name
// it was started with), or all of them when user is empty.
func findSessions(dir, user string) ([]string, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, err
	}
	var out []string
	for _, f := range files {
		if user == "" {
			out = append(out, f)
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var s savedSession
		if json.Unmarshal(b, &s) == nil && (s.TargetUsername == user || s.Requested == user) {
			out = append(out, f)
		}
	}
	return out, nil
}

// loadSession rebuilds a live impersonation from a saved session file.
func loadSession(path string) (*impersonation, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s savedSession
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	base, err := url.Parse(s.BaseURL)
	if err != nil {
		return nil, err
	}
	jar, _ := cookiejar.New(nil)
	var hc []*http.Cookie
	for _, c := range s.Cookies {
		hc = append(hc, &http.Cookie{Name: c.Name, Value: c.Value, Path: "/"})
	}
	jar.SetCookies(base, hc)
	return &impersonation{TargetPK: s.TargetPK, TargetUsername: s.TargetUsername,
		base: base, client: &http.Client{Jar: jar, Timeout: impersonateTimeout}}, nil
}

func jsString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// siteRegexp matches a host and every subdomain of its registrable domain
// (viktorbarzin.me for authentik.viktorbarzin.me).
func siteRegexp(host string) string {
	labels := strings.Split(host, ".")
	if len(labels) > 2 {
		labels = labels[len(labels)-2:]
	}
	return `/(^|\.)` + strings.ReplaceAll(strings.Join(labels, "."), ".", `\.`) + `$/`
}

// checkJS returns the expression that reads users/me and reports whether the
// browser is now the target, impersonated by the agent.
func checkJS(meVar, target, original string) string {
	return fmt.Sprintf(`const ok = %[1]s.user && %[1]s.user.username === %[2]s && %[1]s.original && %[1]s.original.username === %[3]s;
  return ok ? "signed in as " + %[2]s + ", impersonated by " + %[3]s
            : "not impersonating: Authentik reports " + JSON.stringify({ user: %[1]s.user && %[1]s.user.username, original: %[1]s.original && %[1]s.original.username });`,
		meVar, jsString(target), jsString(original))
}

// playwrightSnippet is a function for the Playwright MCP's browser_run_code.
// It drops every cookie of our domain first: the session browser is seeded
// with Viktor's logins, and the forward-auth cookies on each app host would
// otherwise keep showing Viktor.
func playwrightSnippet(base string, cookies []pwCookie, target, original string) string {
	u, _ := url.Parse(base)
	cj, _ := json.Marshal(cookies)
	return fmt.Sprintf(`async (page) => {
  const ctx = page.context();
  await ctx.clearCookies({ domain: %s });
  await ctx.addCookies(%s);
  const r = await ctx.request.get(%s);
  if (!r.ok()) return "users/me answered " + r.status();
  const me = await r.json();
  %s
}`, siteRegexp(u.Hostname()), cj, jsString(base+"/api/v3/core/users/me/"), checkJS("me", target, original))
}

// t3Snippet is an expression for T3's preview_evaluate, run in a tab on the
// Authentik origin. document.cookie cannot set httpOnly cookies, which Django
// does not need; it also cannot replace an httpOnly cookie already there, so
// the tab must be a fresh isolated one that has not loaded an Authentik page.
func t3Snippet(base string, cookies []pwCookie, target, original string) string {
	var sets strings.Builder
	for _, c := range cookies {
		attrs := "; path=/; samesite=lax"
		if c.Secure {
			attrs = "; path=/; secure; samesite=lax"
		}
		fmt.Fprintf(&sets, "  document.cookie = %s + %s + %s;\n", jsString(c.Name+"="), jsString(c.Value), jsString(attrs))
	}
	return fmt.Sprintf(`(async () => {
  if (location.origin !== %[1]s) return "navigate this tab to " + %[2]s + " first";
%[3]s  const r = await fetch("/api/v3/core/users/me/", { credentials: "same-origin" });
  if (!r.ok) return "users/me answered " + r.status + ": open a new tab without profileId, so it starts with no cookies";
  const me = await r.json();
  %[4]s
})()`, jsString(base), jsString(base+"/-/health/live/"), sets.String(), checkJS("me", target, original))
}

func browserAs(args []string) error {
	o, err := parseBrowserAsArgs(args)
	if err != nil {
		return err
	}
	if o.help {
		fmt.Print(browserAsHelp)
		return nil
	}
	dir, err := impersonationDir()
	if err != nil {
		return err
	}
	if o.end {
		return endSavedSessions(dir, o.user)
	}

	creds, err := readAgentCreds()
	if err != nil {
		return err
	}
	im, err := startImpersonation(impersonationConfig{
		BaseURL: authentikBaseURL, Creds: creds, Target: o.user, Reason: o.reason,
	})
	if err != nil {
		return fmt.Errorf("browser as %s: %w", o.user, err)
	}
	// One live session per user: end an older one before saving this one.
	if old, _ := findSessions(dir, im.TargetUsername); len(old) > 0 {
		_ = endSavedSessions(dir, im.TargetUsername)
	}
	if _, err := saveSession(dir, im, o.user); err != nil {
		_ = im.End()
		return err
	}

	switch o.format {
	case "playwright":
		fmt.Println(playwrightSnippet(im.base.String(), im.cookies(), im.TargetUsername, creds.Username))
	case "t3":
		fmt.Println(t3Snippet(im.base.String(), im.cookies(), im.TargetUsername, creds.Username))
	default:
		b, _ := json.Marshal(struct {
			Cookies []pwCookie `json:"cookies"`
			Origins []any      `json:"origins"`
		}{im.cookies(), []any{}})
		fmt.Println(string(b))
	}
	fmt.Fprintf(os.Stderr, "homelab browser as: signed in as %s, impersonating %s (pk %d); reason recorded in Authentik\n"+
		"  end it when done: homelab browser as --end %s\n", creds.Username, im.TargetUsername, im.TargetPK, im.TargetUsername)
	return nil
}

func endSavedSessions(dir, user string) error {
	files, err := findSessions(dir, user)
	if err != nil {
		return err
	}
	if len(files) == 0 {
		if user == "" {
			fmt.Fprintln(os.Stderr, "homelab browser as: no impersonation sessions to end")
			return nil
		}
		return fmt.Errorf("no saved impersonation session for %s in %s", user, dir)
	}
	var failed []string
	for _, f := range files {
		im, err := loadSession(f)
		if err == nil {
			err = im.End()
		}
		if err != nil {
			failed = append(failed, fmt.Sprintf("%s: %v", filepath.Base(f), err))
			continue
		}
		_ = os.Remove(f)
		fmt.Fprintf(os.Stderr, "homelab browser as: impersonation of %s ended, session logged out\n", im.TargetUsername)
	}
	if len(failed) > 0 {
		return fmt.Errorf("could not end %s; end it in the Authentik admin UI, Directory > Users > <user> > Sessions",
			strings.Join(failed, "; "))
	}
	return nil
}

const browserAsHelp = `homelab browser as — an Authentik session as another user, for your own browser

USAGE
  homelab browser as <user> --reason "<why>" [--format json|playwright|t3]
  homelab browser as --end [<user>]     # log out one session, or all of yours

Signs in as the agent account svc-agent (Vault secret/authentik-agent, admins
only), impersonates <user> (username, email or pk) and prints the session for
a browser you already drive. Authentik records an impersonation_started event
with the reason. The session stays live until --end logs it out; it is kept in
~/.cache/homelab/impersonation/ (mode 0600) until then. A new start for the
same user ends the older session first.

The output is a live sign-in as <user>. Keep it in the session; do not put it
in files, commits or messages.

T3 PREVIEW BROWSER (--format t3)
  1. preview_open url=https://authentik.viktorbarzin.me/-/health/live/ with NO
     profileId: that tab gets its own empty context. Never use the default
     profile, which holds Viktor's own sign-in.
  2. preview_evaluate the printed expression. It sets the cookies and answers
     "signed in as <user>, impersonated by svc-agent".
  3. preview_navigate to the app. Forward-auth and OIDC apps sign in as <user>.
  4. Close the tab, then run homelab browser as --end <user>.

PLAYWRIGHT MCP BROWSER (--format playwright)
  1. browser_run_code_unsafe with the printed function. It clears every
     viktorbarzin.me cookie in the session browser, Viktor's included, adds
     the session, and answers as above.
  2. browser_navigate to the app.
  3. Run homelab browser as --end <user>, then browser_close: the browser holds
     no sign-in of Viktor's for our apps any more, and a new one is seeded
     with them. Our domain's cookies are never pushed to the hub (ADR-0047),
     so the impersonated session does not reach Viktor's other browsers.

ANY OTHER CLIENT (--format json, the default)
  A Playwright storage state: {"cookies": [...], "origins": []}.

To open a browser for one run instead, use homelab browser run|open --as.
`
