package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

// vault verbs give each unix user no-HITL access to THEIR OWN Vaultwarden vault.
// Identity is the kernel UID; per-user creds live in that user's isolated Vault
// path (secret/workstation/claude-users/<user>) read via their scoped token, and
// decryption is done by the official `bw` CLI. See
// docs/runbooks/homelab-vault-onboarding.md.
func vaultCommands() []Command {
	cmds := []Command{
		// Vaultwarden — your personal password manager (logins/passwords/TOTP).
		{Path: []string{"vault", "setup"}, Tier: TierWrite,
			Summary: "[vaultwarden] one-time: store your master password + API key in your Vault path", Run: vaultSetup},
		{Path: []string{"vault", "status"}, Tier: TierRead,
			Summary: "[vaultwarden] show whether your vault is configured/reachable (no secrets)", Run: vaultStatus},
		{Path: []string{"vault", "list"}, Tier: TierRead,
			Summary: "[vaultwarden] list your item names: vault list [--search Q]", Run: vaultList},
		{Path: []string{"vault", "get"}, Tier: TierRead,
			Summary: "[vaultwarden] fetch one login: vault get <name> [--field password|username|uri|notes|totp] [--json] [--all]", Run: vaultGet},
		{Path: []string{"vault", "search"}, Tier: TierRead,
			Summary: "[vaultwarden] search your item names: vault search <query>", Run: vaultSearch},
		{Path: []string{"vault", "code"}, Tier: TierRead,
			Summary: "[vaultwarden] current TOTP code for an item: vault code <name>", Run: vaultCode},
		{Path: []string{"vault", "lock"}, Tier: TierWrite,
			Summary: "[vaultwarden] lock/log out the local bw session", Run: vaultLock},
		{Path: []string{"vault"}, Tier: TierRead,
			Summary: "two stores: Vaultwarden (logins) + HashiCorp Vault/OpenBao kv (infra secrets) — run `homelab vault` for help",
			Run:     func([]string) error { fmt.Print(vaultHelp()); return nil }},
	}
	// HashiCorp Vault / OpenBao — homelab INFRA secrets (the secret/… KV store).
	return append(cmds, vaultKVCommands()...)
}

// vaultHelp is shown for bare `homelab vault`. It LEADS with the distinction
// between the two unrelated "vaults" this command fronts, because the name
// collides: Vaultwarden (a password manager) vs HashiCorp Vault / OpenBao (the
// infra secrets store).
func vaultHelp() string {
	return `homelab vault — two different secret stores under one command:

  • Vaultwarden               your personal PASSWORD MANAGER (logins / passwords / TOTP)
  • HashiCorp Vault / OpenBao  homelab INFRA secrets (the secret/… KV store)  → 'vault kv …'

── Vaultwarden  (reads YOUR OWN vault; no-HITL after one-time setup) ──
  homelab vault setup             one-time: store your master password + API key in your Vault path
  homelab vault status            configured / unlocked / reachable (no secrets)
  homelab vault list [--search Q] list your item names (no secrets)
  homelab vault get <name> [--field password|username|uri|notes|totp] [--json]
                                  TTY → clipboard (auto-clears); piped → stdout
  homelab vault get <name> --all  all fields (incl. custom) as JSON; piped only.
                                  TOTP shown as presence flag — use 'vault code' for a code.
  homelab vault code <name>       current TOTP code
  homelab vault lock              lock / log out the local bw session

── HashiCorp Vault / OpenBao  (infra secrets; uses your own OIDC vault token) ──
  homelab vault kv get <path> [--field K]   read an infra KV secret
  homelab vault kv list <path>              list sub-paths
  homelab vault kv put <path> <key>         write one key (value via stdin)

Vaultwarden creds live only in your own Vault path; the admin never sees them.
Security model: docs/runbooks/homelab-vault-onboarding.md
(note: anything running as your user can decrypt your vault — the accepted no-HITL trade).
`
}

const vwUserPathPrefix = "secret/workstation/claude-users/"

// vwCreds is one user's Vaultwarden auth material, read from their Vault path.
type vwCreds struct {
	Email          string
	MasterPassword string
	ClientID       string
	ClientSecret   string
}

// cmdRunner shells out to an external command with an explicit environment and
// returns trimmed stdout. Secrets are passed via envv, NEVER argv. Tests inject
// a fake; realRunner is the production implementation.
type cmdRunner func(name string, argv, envv []string) (string, error)

func realRunner(name string, argv, envv []string) (string, error) {
	cmd := exec.Command(name, argv...)
	if envv != nil {
		cmd.Env = envv
	}
	out, err := cmd.Output()
	// Trim only the trailing newline the tool appends — NOT all whitespace, so a
	// fetched secret with significant leading/trailing spaces is preserved.
	return strings.TrimRight(string(out), "\r\n"), augmentErr(err, exitStderr(err))
}

// exitStderr returns the stderr captured by cmd.Output() on a failed exec (it
// stows it on *exec.ExitError), or nil. The tools we shell out to (vault, bw)
// write the actionable message there — "connection refused", "permission
// denied" — which the caller would otherwise never see behind a bare
// "exit status N".
func exitStderr(err error) []byte {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.Stderr
	}
	return nil
}

// augmentErr appends captured stderr to an error so failures are diagnosable
// (not just "exit status 2"). Returns nil when err is nil, and err unchanged
// when there's no stderr; preserves the wrapped error for errors.Is/As.
func augmentErr(err error, stderr []byte) error {
	if err == nil {
		return nil
	}
	if s := strings.TrimSpace(string(stderr)); s != "" {
		return fmt.Errorf("%w: %s", err, s)
	}
	return err
}

// realRunnerStdin runs a command feeding `stdin` to it, for secret values that
// must NOT appear in argv (visible via ps / /proc/<pid>/cmdline to same-UID
// processes). Used by setup to write the master password / client_secret.
func realRunnerStdin(name string, argv, envv []string, stdin string) (string, error) {
	cmd := exec.Command(name, argv...)
	if envv != nil {
		cmd.Env = envv
	}
	cmd.Stdin = strings.NewReader(stdin)
	out, err := cmd.Output()
	return strings.TrimRight(string(out), "\r\n"), augmentErr(err, exitStderr(err))
}

func vwCredsPath(user string) string { return vwUserPathPrefix + user }

func bwAppDataDir(uid string) string { return "/run/user/" + uid + "/homelab-bw" }

// readVaultField returns one field from a KV-v2 path, "" if absent/error.
func readVaultField(run cmdRunner, field, path string) string {
	out, err := run("vault", []string{"kv", "get", "-field=" + field, path}, nil)
	if err != nil {
		return ""
	}
	return out
}

// loadCreds reads the four vaultwarden_* keys from the user's isolated path.
// A missing master password means the user hasn't onboarded.
func loadCreds(run cmdRunner, user string) (vwCreds, error) {
	p := vwCredsPath(user)
	c := vwCreds{
		Email:          readVaultField(run, "vaultwarden_email", p),
		MasterPassword: readVaultField(run, "vaultwarden_master_password", p),
		ClientID:       readVaultField(run, "vaultwarden_client_id", p),
		ClientSecret:   readVaultField(run, "vaultwarden_client_secret", p),
	}
	if c.MasterPassword == "" {
		return vwCreds{}, fmt.Errorf("vault not configured for this user — run `homelab vault setup`")
	}
	return c, nil
}

// vaultCurrentUser/vaultCurrentUID are seams for tests (avoid conflict with repo.go's currentUser func).
var vaultCurrentUser = func() string { return os.Getenv("USER") }
var vaultCurrentUID = func() string { return fmt.Sprintf("%d", os.Getuid()) }

// scopedTokenPath is where claude-auth-sync keeps the user's scoped Vault token.
// MUST match CAS_VAULT_TOKEN_FILE in scripts/workstation/claude-auth-sync.sh.
func scopedTokenPath(home string) string {
	return home + "/.config/claude-auth-sync/vault-token"
}

// vaultTokenSource decides which Vault token the `vault` child processes should
// use. Precedence: an explicit $VAULT_TOKEN (deliberate override), then the
// per-user scoped token claude-auth-sync maintains at scopedTokenPath(HOME)
// (policy workstation-claude-<user>, which grants exactly the create/read/update
// this tool needs on the user's own path), then a native ~/.vault-token.
//
// The scoped token MUST beat ~/.vault-token: this tool only ever touches the
// caller's own secret/workstation/claude-users/<user> path, and a power-user who
// ran `vault login -method=oidc` carries a read-only ~/.vault-token whose
// capability on that path is `deny` — letting it win shadows the scoped token
// and every op fails 403/deny (emo, 2026-06-28). ~/.vault-token is only the
// right credential when there is no scoped token (admins). Returns the token to
// export — "" when the vault CLI should read the ambient/native credential —
// plus a source tag for tests/logging.
func vaultTokenSource(envToken string, haveVaultTokenFile bool, scopedToken string) (token, source string) {
	switch {
	case envToken != "":
		return "", "env"
	case strings.TrimSpace(scopedToken) != "":
		return strings.TrimSpace(scopedToken), "scoped"
	case haveVaultTokenFile:
		return "", "file"
	default:
		return "", "none"
	}
}

// vaultAddrDefault is the cluster Vault the workstation talks to. The bw server
// is likewise hardcoded (openSession), so a sane default here is consistent.
const vaultAddrDefault = "https://vault.viktorbarzin.me"

// vaultAddrToSet returns the VAULT_ADDR to export when the caller's environment
// doesn't already set one, else "". homelab vault is invoked by AFK agent
// sessions — frequently non-login shells (tmux panes, agent subprocesses) that
// never sourced /etc/environment — so, like claude-auth-sync, the CLI must NOT
// depend on an ambient VAULT_ADDR; otherwise every `vault` child falls back to
// the 127.0.0.1:8200 default and fails "connection refused" (exit 2).
func vaultAddrToSet(envAddr string) string {
	if strings.TrimSpace(envAddr) == "" {
		return vaultAddrDefault
	}
	return ""
}

// ensureVaultAddr exports the default VAULT_ADDR when none is set, so the vault
// child processes reach the cluster Vault regardless of the caller's shell. An
// explicit VAULT_ADDR (admins, CI) is left untouched.
func ensureVaultAddr() {
	if a := vaultAddrToSet(os.Getenv("VAULT_ADDR")); a != "" {
		os.Setenv("VAULT_ADDR", a)
	}
}

// fileNonEmpty reports whether path exists and has content.
func fileNonEmpty(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Size() > 0
}

// ensureVaultToken wires vaultTokenSource to the real environment: when the user
// has no ambient Vault credential, it exports the claude-auth-sync scoped token
// so the `vault` child processes authenticate as workstation-claude-<user>. It
// is idempotent and safe for admins, whose explicit $VAULT_TOKEN / ~/.vault-token
// take precedence and are left untouched.
func ensureVaultToken() {
	// Every vault verb funnels through here, so this is the one place that also
	// guarantees VAULT_ADDR is set (see vaultAddrToSet for why it can't be
	// assumed from the caller's shell).
	ensureVaultAddr()
	home := os.Getenv("HOME")
	scoped, _ := os.ReadFile(scopedTokenPath(home))
	tok, src := vaultTokenSource(os.Getenv("VAULT_TOKEN"), home != "" && fileNonEmpty(home+"/.vault-token"), string(scoped))
	if src == "scoped" {
		os.Setenv("VAULT_TOKEN", tok)
	}
}

// bwBaseEnv is the minimal non-secret environment bw/node need. We deliberately
// do NOT inherit the full parent env (keeps stray secrets out of the child).
func bwBaseEnv(appdata string) []string {
	path := os.Getenv("PATH")
	if path == "" {
		path = "/usr/local/bin:/usr/bin:/bin"
	}
	return []string{
		"PATH=" + path,
		"HOME=" + os.Getenv("HOME"),
		"BITWARDENCLI_APPDATA_DIR=" + appdata,
		"BW_NOINTERACTION=true",
	}
}

// bwSecretEnv adds the secret-bearing vars. session may be "" (pre-unlock).
func bwSecretEnv(appdata string, c vwCreds, session string) []string {
	env := bwBaseEnv(appdata)
	env = append(env,
		"BW_CLIENTID="+c.ClientID,
		"BW_CLIENTSECRET="+c.ClientSecret,
		"BW_PASSWORD="+c.MasterPassword,
	)
	if session != "" {
		env = append(env, "BW_SESSION="+session)
	}
	return env
}

func bwLoginArgs() []string                 { return []string{"login", "--apikey"} }
func bwUnlockArgs() []string                { return []string{"unlock", "--passwordenv", "BW_PASSWORD", "--raw"} }
func bwGetArgs(field, name string) []string { return []string{"get", field, name} }
func bwItemArgs(name string) []string       { return []string{"get", "item", name} }
func bwStatusArgs() []string                { return []string{"status"} }
func bwSyncArgs() []string                  { return []string{"sync"} }

// bwNeedsLogin parses `bw status` JSON and reports whether a `bw login` is
// required. Unparseable/empty output → true (safer to attempt login).
func bwNeedsLogin(statusJSON string) bool {
	var s struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal([]byte(statusJSON), &s); err != nil {
		return true
	}
	return s.Status == "unauthenticated" || s.Status == ""
}

func bwListArgs(search string) []string {
	a := []string{"list", "items"}
	if search != "" {
		a = append(a, "--search", search)
	}
	return a
}

// bwUnlock runs `bw unlock` and returns the raw session key.
func bwUnlock(run cmdRunner, env []string) (string, error) {
	out, err := run("bw", bwUnlockArgs(), env)
	if err != nil {
		return "", fmt.Errorf("bw unlock failed (wrong master password? run `homelab vault setup`): %w", err)
	}
	return out, nil
}

// bwGet fetches one field of one item; session must be present in env.
func bwGet(run cmdRunner, env []string, field, name string) (string, error) {
	return run("bw", bwGetArgs(field, name), env)
}

func returnMode(isTTY bool) string {
	if isTTY {
		return "clipboard"
	}
	return "stdout"
}

// stdoutIsTTY reports whether stdout is a character device (a terminal).
func stdoutIsTTY() bool {
	fi, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

// stderrIsTTY reports whether stderr is a terminal (the OSC52 escape is written
// to stderr, so the clipboard path is only viable when stderr is a terminal).
func stderrIsTTY() bool {
	fi, err := os.Stderr.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

// osc52 returns the OSC 52 escape that makes the local terminal copy payload to
// the system clipboard (works over SSH; no X11). osc52clear copies empty.
func osc52(payload string) string {
	return "\x1b]52;c;" + base64.StdEncoding.EncodeToString([]byte(payload)) + "\a"
}
func osc52clear() string { return "\x1b]52;c;\a" }

// terminalAllowed gates OSC 52: only terminals known to honor clipboard writes,
// else we'd dump the secret's base64 into scrollback on unsupported terminals.
func terminalAllowed(term, termProgram string) bool {
	t := strings.ToLower(term)
	p := strings.ToLower(termProgram)
	for _, ok := range []string{"kitty", "alacritty", "foot", "wezterm", "ghostty", "tmux", "screen"} {
		if strings.Contains(t, ok) || strings.Contains(p, ok) {
			return true
		}
	}
	// xterm proper supports it only when the program is a known-good emulator.
	return false
}

// opRecord is one CLI operation. ItemName is accepted for the caller's
// convenience but is INTENTIONALLY never rendered into the log line — auditing
// which of your own logins you opened is itself sensitive, and per-item reads
// are invisible server-side anyway (spec §9a).
type opRecord struct {
	User       string
	Verb       string
	PID        int
	PPID       int
	ParentComm string
	ItemName   string // never logged
}

func opLogLine(r opRecord) string {
	return fmt.Sprintf("user=%s verb=%s pid=%d ppid=%d parent=%s",
		r.User, r.Verb, r.PID, r.PPID, r.ParentComm)
}

// parentComm reads /proc/<ppid>/comm (best-effort; "" on failure).
func parentComm(ppid int) string {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/comm", ppid))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// writeOpLog appends one privacy-aware line to the user's op-log (best-effort;
// never blocks or fails the command). Goes to syslog so it ships to Loki.
func writeOpLog(r opRecord) {
	exec.Command("logger", "-t", "homelab-vault", opLogLine(r)).Run() // best-effort
}

func vaultLockPath(uid string) string { return "/run/user/" + uid + "/homelab-vault.lock" }

// hardenProcess disables core dumps so a bw/homelab crash can't spill the master
// password to a core file. Best-effort.
func hardenProcess() {
	_ = syscall.Setrlimit(syscall.RLIMIT_CORE, &syscall.Rlimit{Cur: 0, Max: 0})
}

// withUserLock serializes bw mutations for this user (concurrent Claude sessions
// as the same user otherwise race bw's appdata). Returns an unlock func.
func withUserLock(uid string) (func(), error) {
	f, err := os.OpenFile(vaultLockPath(uid), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return func() { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}

// session is one usable bw context: the env (with BW_SESSION) ready for `bw get`.
type session struct {
	env []string
}

// openSession resolves creds, ensures login, unlocks, and returns a ready env.
// Caller must hold the user lock. appdata is created on tmpfs (0700).
func openSession(run cmdRunner, user, uid string) (session, error) {
	creds, err := loadCreds(run, user)
	if err != nil {
		return session{}, err
	}
	appdata := bwAppDataDir(uid)
	if err := os.MkdirAll(appdata, 0700); err != nil {
		return session{}, fmt.Errorf("create bw appdata %s: %w", appdata, err)
	}
	loginEnv := bwSecretEnv(appdata, creds, "")
	// Ensure server is set and we're logged in (idempotent; ignore "already").
	_, _ = run("bw", []string{"config", "server", "https://vaultwarden.viktorbarzin.me"}, loginEnv)
	st, _ := run("bw", bwStatusArgs(), loginEnv)
	if bwNeedsLogin(st) {
		if _, err := run("bw", bwLoginArgs(), loginEnv); err != nil {
			return session{}, fmt.Errorf("bw login --apikey failed (API key valid? run `homelab vault setup`): %w", err)
		}
	}
	sess, err := bwUnlock(run, loginEnv)
	if err != nil {
		return session{}, err
	}
	sessEnv := bwSecretEnv(appdata, creds, sess)
	// Pull the latest server-side state so reads reflect current values. `bw
	// unlock` only decrypts the LOCAL cache, so a persisted (already-logged-in)
	// session would otherwise serve stale data until the next login. Best-effort:
	// a transient sync failure must not break a read — fall back to the cached
	// vault and warn (status reports reachability separately).
	if _, err := run("bw", bwSyncArgs(), sessEnv); err != nil {
		fmt.Fprintln(os.Stderr, "homelab vault: warning: bw sync failed; using cached vault (values may be stale): "+err.Error())
	}
	return session{env: sessEnv}, nil
}

type getOpts struct {
	name  string
	field string
	json  bool
	all   bool // dump every field (incl. custom) as normalized JSON
}

var validGetFields = map[string]bool{"password": true, "username": true, "uri": true, "notes": true, "totp": true}

func parseGetArgs(args []string) (getOpts, error) {
	o := getOpts{field: "password"}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--json":
			o.json = true
		case a == "--all":
			o.all = true
		case a == "--field" && i+1 < len(args):
			o.field = args[i+1]
			i++
		case strings.HasPrefix(a, "--field="):
			o.field = strings.TrimPrefix(a, "--field=")
		case !strings.HasPrefix(a, "-") && o.name == "":
			o.name = a
		}
	}
	if o.name == "" {
		return o, fmt.Errorf("usage: homelab vault get <name> [--field password|username|uri|notes|totp] [--json] [--all]")
	}
	// --all dumps the whole item, so --field is irrelevant — skip its allowlist.
	if !o.all && !validGetFields[o.field] {
		return o, fmt.Errorf("invalid --field %q (want password|username|uri|notes|totp)", o.field)
	}
	return o, nil
}

// getValue opens a session and fetches one field. Pure of I/O side effects
// besides the runner, so it is unit-tested with a fake runner.
func getValue(run cmdRunner, user, uid string, o getOpts) (string, error) {
	s, err := openSession(run, user, uid)
	if err != nil {
		return "", err
	}
	return bwGet(run, s.env, o.field, o.name)
}

// getItem opens a session and returns the whole item as raw `bw get item` JSON.
// Used by `get --all`; normalization is a separate, pure step (normalizeItem).
func getItem(run cmdRunner, user, uid, name string) (string, error) {
	s, err := openSession(run, user, uid)
	if err != nil {
		return "", err
	}
	return run("bw", bwItemArgs(name), s.env)
}

// normalizedItem is the browse-all-fields projection of a Vaultwarden item: the
// standard login fields that are present, notes, and a flat map of custom field
// name→value. bw internals (id, object, reprompt, passwordHistory) are dropped,
// and the TOTP *seed* is reduced to a presence flag — the only seed-derived path
// stays the specially-audited `vault code` (see the design §10/§16).
type normalizedItem struct {
	Name     string            `json:"name"`
	Username string            `json:"username,omitempty"`
	Password string            `json:"password,omitempty"`
	URIs     []string          `json:"uris,omitempty"`
	TOTP     bool              `json:"totp,omitempty"` // presence only, never the seed
	Notes    string            `json:"notes,omitempty"`
	Fields   map[string]string `json:"fields,omitempty"` // custom field name→value
}

// bwFieldLinked is the Bitwarden custom-field type for a "linked" field: it
// references another field and carries a null value, so it is not real data.
const bwFieldLinked = 3

// normalizeItem parses a `bw get item` payload into the browse projection. It is
// pure (no I/O), so it is the unit-tested heart of `get --all`.
func normalizeItem(raw string) (normalizedItem, error) {
	var it struct {
		Name  string `json:"name"`
		Notes string `json:"notes"`
		Login *struct {
			Username string `json:"username"`
			Password string `json:"password"`
			Totp     string `json:"totp"`
			URIs     []struct {
				URI string `json:"uri"`
			} `json:"uris"`
		} `json:"login"`
		Fields []struct {
			Name  string `json:"name"`
			Value string `json:"value"`
			Type  int    `json:"type"`
		} `json:"fields"`
	}
	if err := json.Unmarshal([]byte(raw), &it); err != nil {
		return normalizedItem{}, fmt.Errorf("parse bw item: %w", err)
	}
	n := normalizedItem{Name: it.Name, Notes: it.Notes}
	if it.Login != nil {
		n.Username = it.Login.Username
		n.Password = it.Login.Password
		n.TOTP = it.Login.Totp != ""
		for _, u := range it.Login.URIs {
			if u.URI != "" {
				n.URIs = append(n.URIs, u.URI)
			}
		}
	}
	for _, f := range it.Fields {
		if f.Type == bwFieldLinked {
			continue // references another field, no value of its own
		}
		if n.Fields == nil {
			n.Fields = map[string]string{}
		}
		n.Fields[f.Name] = f.Value // duplicate names: last-wins (rare; documented)
	}
	return n, nil
}

// clipboardDecision picks how to return a secret value. "stdout" prints it (a
// pipe/agent — the intended machine path); "clipboard" copies via OSC52;
// "refuse" emits nothing sensitive (would otherwise risk dumping the secret's
// base64 into scrollback, or silently fail because the OSC52 escape goes to a
// non-terminal stderr).
func clipboardDecision(stdoutTTY, stderrTTY bool, term, termProgram string) string {
	if !stdoutTTY {
		return "stdout"
	}
	if terminalAllowed(term, termProgram) && stderrTTY {
		return "clipboard"
	}
	return "refuse"
}

// jsonToStdoutOK reports whether `--json` may print the secret to stdout — only
// when stdout is NOT a terminal (i.e. piped to a machine consumer).
func jsonToStdoutOK(stdoutTTY bool) bool { return !stdoutTTY }

// emitSecret returns a value TTY-aware (see clipboardDecision). Never prints the
// secret to a terminal's stdout/scrollback.
func emitSecret(value string) {
	switch clipboardDecision(stdoutIsTTY(), stderrIsTTY(), os.Getenv("TERM"), os.Getenv("TERM_PROGRAM")) {
	case "stdout":
		fmt.Println(value)
	case "clipboard":
		fmt.Fprint(os.Stderr, osc52(value))
		fmt.Fprintln(os.Stderr, "copied to clipboard; clearing in 30s")
		clearClipboardAfter(30)
	default: // refuse
		fmt.Fprintln(os.Stderr, "refusing to print secret: this terminal can't do OSC52 clipboard safely; pipe the command (e.g. | cat) or use a supported terminal")
	}
}

// clearClipboardAfter spawns a detached background clear so the secret doesn't
// linger in the clipboard. Best-effort.
func clearClipboardAfter(seconds int) {
	exec.Command("sh", "-c", fmt.Sprintf("sleep %d; printf '%s'", seconds, osc52clear())).Start()
}

// listNames extracts "name (id)" from `bw list items` JSON; never values.
func listNames(jsonOut string) []string {
	var items []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err := json.Unmarshal([]byte(jsonOut), &items); err != nil {
		return nil
	}
	out := make([]string, 0, len(items))
	for _, it := range items {
		out = append(out, fmt.Sprintf("%s (%s)", it.Name, it.ID))
	}
	return out
}

func runList(run cmdRunner, user, uid, search string) ([]string, error) {
	s, err := openSession(run, user, uid)
	if err != nil {
		return nil, err
	}
	out, err := run("bw", bwListArgs(search), s.env)
	if err != nil {
		return nil, err
	}
	return listNames(out), nil
}

func vaultList(args []string) error {
	hardenProcess()
	ensureVaultToken()
	search := ""
	for i := 0; i < len(args); i++ {
		if args[i] == "--search" && i+1 < len(args) {
			search = args[i+1]
			i++
		} else if strings.HasPrefix(args[i], "--search=") {
			search = strings.TrimPrefix(args[i], "--search=")
		}
	}
	uid := vaultCurrentUID()
	unlock, err := withUserLock(uid)
	if err != nil {
		return err
	}
	defer unlock()
	names, err := runList(realRunner, vaultCurrentUser(), uid, search)
	if err != nil {
		return err
	}
	for _, n := range names {
		fmt.Println(n)
	}
	return nil
}

func vaultSearch(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: homelab vault search <query>")
	}
	return vaultList([]string{"--search", strings.Join(args, " ")})
}

func vaultCode(args []string) error {
	hardenProcess()
	ensureVaultToken()
	if len(args) == 0 {
		return fmt.Errorf("usage: homelab vault code <name>")
	}
	name := args[0]
	uid := vaultCurrentUID()
	unlock, err := withUserLock(uid)
	if err != nil {
		return err
	}
	defer unlock()
	user := vaultCurrentUser()
	val, err := getValue(realRunner, user, uid, getOpts{name: name, field: "totp"})
	if err != nil {
		return err
	}
	// TOTP is the most sensitive op: log AND emit an ntfy-bound marker (spec §9a-d).
	writeOpLog(opRecord{User: user, Verb: "code", PID: os.Getpid(), PPID: os.Getppid(), ParentComm: parentComm(os.Getppid()), ItemName: name})
	exec.Command("logger", "-t", "homelab-vault-totp", "user="+user+" totp-fetch parent="+parentComm(os.Getppid())).Run()
	emitSecret(val)
	return nil
}

// statusSummary reports config/reachability without revealing secrets.
func statusSummary(run cmdRunner, user, uid string) string {
	if _, err := loadCreds(run, user); err != nil {
		return "vault: not configured — run `homelab vault setup`"
	}
	s, err := openSession(run, user, uid)
	if err != nil {
		return "vault: configured, but unlock/login FAILED (creds stale? run `homelab vault setup`): " + err.Error()
	}
	// openSession already did a best-effort sync; status re-runs it explicitly so
	// a reachability failure surfaces in this report rather than only on stderr.
	if _, err := run("bw", bwSyncArgs(), s.env); err != nil {
		return "vault: configured + unlocked, but sync/reachability failed: " + err.Error()
	}
	return "vault: configured, unlocked, reachable ✓"
}

func vaultStatus(args []string) error {
	hardenProcess()
	ensureVaultToken()
	uid := vaultCurrentUID()
	unlock, err := withUserLock(uid)
	if err != nil {
		return err
	}
	defer unlock()
	fmt.Println(statusSummary(realRunner, vaultCurrentUser(), uid))
	return nil
}

func vaultLock(args []string) error {
	uid := vaultCurrentUID()
	unlock, err := withUserLock(uid) // logout mutates bw state — serialize with get/list
	if err != nil {
		return err
	}
	defer unlock()
	appdata := bwAppDataDir(uid)
	_, _ = realRunner("bw", []string{"lock"}, bwBaseEnv(appdata))
	_, logoutErr := realRunner("bw", []string{"logout"}, bwBaseEnv(appdata))
	if logoutErr == nil {
		fmt.Println("locked")
	}
	return nil // lock/logout best-effort; never error the caller
}

// kvWriteVerb selects the KV write semantics. merge=true → `kv patch -method=rw`
// (read-modify-write: needs only read+update, NOT the `patch` capability the
// scoped workstation-claude-<user> policy lacks, and preserves co-located keys
// such as claude-auth-sync's claude_ai_oauth_json). merge=false → `kv put`
// (creates the path on first use, before any sibling keys exist).
func kvWriteVerb(merge bool) []string {
	if merge {
		return []string{"kv", "patch", "-method=rw"}
	}
	return []string{"kv", "put"}
}

// vaultWritePublicArgs writes the non-secret identifiers via argv. Neither the
// email nor the API client_id is a usable credential on its own.
func vaultWritePublicArgs(merge bool, user, email, clientID string) []string {
	return append(kvWriteVerb(merge), vwCredsPath(user),
		"vaultwarden_email="+email,
		"vaultwarden_client_id="+clientID,
	)
}

// vaultWriteSecretArgs writes ONE secret value via the `key=-` stdin form, so the
// value never appears in argv (ps / /proc/<pid>/cmdline). Fed on stdin by
// realRunnerStdin.
func vaultWriteSecretArgs(merge bool, user, key string) []string {
	return append(kvWriteVerb(merge), vwCredsPath(user), key+"=-")
}

// credsPathExists reports whether the user's KV path already holds data. Used to
// pick create (`kv put`) vs merge (`kv patch -method=rw`) for the first write:
// claude-auth-sync usually creates the path first (Claude OAuth backup), but a
// user could run `homelab vault setup` before that ever happens.
func credsPathExists(run cmdRunner, user string) bool {
	_, err := run("vault", []string{"kv", "get", "-format=json", vwCredsPath(user)}, nil)
	return err == nil
}

// cmdRunnerStdin is realRunnerStdin's shape, injected so writeCreds is testable.
type cmdRunnerStdin func(name string, argv, envv []string, stdin string) (string, error)

// writeCreds stores all four fields in the user's Vault path using only the
// capabilities the scoped policy grants (create/read/update — NOT `patch`). The
// first (public) write creates the path when absent; the two real secrets then
// merge in via read-modify-write so the public keys — and any claude-auth-sync
// keys already present — survive. Secret values travel on stdin, never argv.
func writeCreds(run cmdRunner, runStdin cmdRunnerStdin, user string, c vwCreds) error {
	merge := credsPathExists(run, user)
	if _, err := run("vault", vaultWritePublicArgs(merge, user, c.Email, c.ClientID), nil); err != nil {
		return err
	}
	// The path now exists regardless of the branch above → merge the secrets in.
	if _, err := runStdin("vault", vaultWriteSecretArgs(true, user, "vaultwarden_master_password"), nil, c.MasterPassword); err != nil {
		return err
	}
	if _, err := runStdin("vault", vaultWriteSecretArgs(true, user, "vaultwarden_client_secret"), nil, c.ClientSecret); err != nil {
		return err
	}
	return nil
}

// promptNoEcho reads one line without terminal echo (for the master password).
func promptNoEcho(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)
	exec.Command("stty", "-echo").Run()
	defer func() { exec.Command("stty", "echo").Run(); fmt.Fprintln(os.Stderr) }()
	r := bufio.NewReader(os.Stdin)
	line, err := r.ReadString('\n')
	// Trim only the line terminator — a master password / API secret may
	// legitimately contain leading/trailing spaces.
	return strings.TrimRight(line, "\r\n"), err
}

func promptLine(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	return strings.TrimSpace(line), err
}

func vaultSetup(args []string) error {
	hardenProcess()
	ensureVaultToken()
	fmt.Fprintln(os.Stderr, "One-time setup. Stored ONLY in your own Vault path; the admin never sees it.")
	fmt.Fprintln(os.Stderr, "Get your API key at https://vaultwarden.viktorbarzin.me → Settings → Security → Keys → View API key.")
	email, err := promptLine("Vaultwarden email: ")
	if err != nil {
		return err
	}
	clientID, err := promptLine("API key client_id (user.xxxx): ")
	if err != nil {
		return err
	}
	clientSecret, err := promptNoEcho("API key client_secret: ")
	if err != nil {
		return err
	}
	master, err := promptNoEcho("Master password: ")
	if err != nil {
		return err
	}
	if master == "" || clientID == "" || clientSecret == "" {
		return fmt.Errorf("all fields are required")
	}
	c := vwCreds{Email: email, MasterPassword: master, ClientID: clientID, ClientSecret: clientSecret}
	if err := writeCreds(realRunner, realRunnerStdin, vaultCurrentUser(), c); err != nil {
		return fmt.Errorf("writing creds to your Vault path failed (scoped token present?): %w", err)
	}
	fmt.Fprintln(os.Stderr, "Stored. Verifying unlock…")
	uid := vaultCurrentUID()
	unlock, err := withUserLock(uid)
	if err != nil {
		return err
	}
	defer unlock()
	if _, err := openSession(realRunner, vaultCurrentUser(), uid); err != nil {
		return fmt.Errorf("stored, but verification failed — double-check master password / API key: %w", err)
	}
	fmt.Fprintln(os.Stderr, "✓ Verified. Fetches are now AFK.")
	return nil
}

func vaultGet(args []string) error {
	hardenProcess()
	ensureVaultToken()
	o, err := parseGetArgs(args)
	if err != nil {
		return err
	}
	uid := vaultCurrentUID()
	unlock, err := withUserLock(uid)
	if err != nil {
		return err
	}
	defer unlock()
	user := vaultCurrentUser()
	if o.all {
		return getAllFields(user, uid, o.name)
	}
	val, err := getValue(realRunner, user, uid, o)
	if err != nil {
		return err
	}
	writeOpLog(opRecord{User: user, Verb: "get", PID: os.Getpid(), PPID: os.Getppid(), ParentComm: parentComm(os.Getppid()), ItemName: o.name})
	if o.json {
		if !jsonToStdoutOK(stdoutIsTTY()) {
			return fmt.Errorf("refusing to print a secret as JSON to a terminal; pipe it (e.g. | cat) or drop --json")
		}
		fmt.Printf("{%q:%q}\n", o.field, val)
		return nil
	}
	emitSecret(val)
	return nil
}

// getAllFields prints every field of one item as normalized JSON. Like
// `get --json`, the payload is all secret values, so it refuses a terminal
// (pipe it). The TOTP seed is never emitted — only a presence flag — so no extra
// TOTP audit is needed; the op-log uses a distinct verb so a bulk dump is
// distinguishable from a single-field get (the item name is still never logged).
func getAllFields(user, uid, name string) error {
	if !jsonToStdoutOK(stdoutIsTTY()) {
		return fmt.Errorf("refusing to print all fields as JSON to a terminal; pipe it (e.g. | jq)")
	}
	raw, err := getItem(realRunner, user, uid, name)
	if err != nil {
		return err
	}
	item, err := normalizeItem(raw)
	if err != nil {
		return err
	}
	out, err := json.Marshal(item)
	if err != nil {
		return err
	}
	writeOpLog(opRecord{User: user, Verb: "get-all", PID: os.Getpid(), PPID: os.Getppid(), ParentComm: parentComm(os.Getppid()), ItemName: name})
	fmt.Println(string(out))
	return nil
}
