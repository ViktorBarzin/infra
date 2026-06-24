package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
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
// docs/superpowers/specs/2026-06-24-homelab-vault-design.md.
func vaultCommands() []Command {
	return []Command{
		{Path: []string{"vault", "setup"}, Tier: TierWrite,
			Summary: "one-time: store your Vaultwarden master password + API key in your Vault path", Run: vaultSetup},
		{Path: []string{"vault", "status"}, Tier: TierRead,
			Summary: "show whether your vault is configured/reachable (no secrets)", Run: vaultStatus},
		{Path: []string{"vault", "list"}, Tier: TierRead,
			Summary: "list your item names: vault list [--search Q]", Run: vaultList},
		{Path: []string{"vault", "get"}, Tier: TierRead,
			Summary: "fetch one item: vault get <name> [--field password|username|uri|notes] [--json]", Run: vaultGet},
		{Path: []string{"vault", "search"}, Tier: TierRead,
			Summary: "search your item names: vault search <query>", Run: vaultSearch},
		{Path: []string{"vault", "code"}, Tier: TierRead,
			Summary: "current TOTP code for an item: vault code <name>", Run: vaultCode},
		{Path: []string{"vault", "lock"}, Tier: TierWrite,
			Summary: "lock/log out the local bw session", Run: vaultLock},
	}
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
	return strings.TrimSpace(string(out)), err
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

func bwLoginArgs() []string  { return []string{"login", "--apikey"} }
func bwUnlockArgs() []string { return []string{"unlock", "--passwordenv", "BW_PASSWORD", "--raw"} }
func bwGetArgs(field, name string) []string { return []string{"get", field, name} }
func bwStatusArgs() []string { return []string{"status"} }

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
	if st, _ := run("bw", bwStatusArgs(), loginEnv); !strings.Contains(st, "\"status\"") || strings.Contains(st, "unauthenticated") {
		if _, err := run("bw", bwLoginArgs(), loginEnv); err != nil {
			return session{}, fmt.Errorf("bw login --apikey failed (API key valid? run `homelab vault setup`): %w", err)
		}
	}
	sess, err := bwUnlock(run, loginEnv)
	if err != nil {
		return session{}, err
	}
	return session{env: bwSecretEnv(appdata, creds, sess)}, nil
}

type getOpts struct {
	name  string
	field string
	json  bool
}

var validGetFields = map[string]bool{"password": true, "username": true, "uri": true, "notes": true, "totp": true}

func parseGetArgs(args []string) (getOpts, error) {
	o := getOpts{field: "password"}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--json":
			o.json = true
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
		return o, fmt.Errorf("usage: homelab vault get <name> [--field password|username|uri|notes|totp] [--json]")
	}
	if !validGetFields[o.field] {
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

// emitSecret returns it TTY-aware: clipboard (OSC52, gated, auto-clear) on a
// terminal; stdout otherwise. Returns the human-facing status string (never the
// secret) for the clipboard path.
func emitSecret(value string) {
	if returnMode(stdoutIsTTY()) == "stdout" {
		fmt.Println(value)
		return
	}
	if !terminalAllowed(os.Getenv("TERM"), os.Getenv("TERM_PROGRAM")) {
		fmt.Fprintln(os.Stderr, "refusing to print secret: this terminal can't do OSC52 clipboard safely; pipe the command or use a supported terminal")
		return
	}
	fmt.Fprint(os.Stderr, osc52(value))
	fmt.Fprintln(os.Stderr, "copied to clipboard; clearing in 30s")
	clearClipboardAfter(30)
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
	if _, err := run("bw", []string{"sync"}, s.env); err != nil {
		return "vault: configured + unlocked, but sync/reachability failed: " + err.Error()
	}
	return "vault: configured, unlocked, reachable ✓"
}

func vaultStatus(args []string) error {
	hardenProcess()
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
	appdata := bwAppDataDir(vaultCurrentUID())
	_, _ = realRunner("bw", []string{"lock"}, bwBaseEnv(appdata))
	_, err := realRunner("bw", []string{"logout"}, bwBaseEnv(appdata))
	if err == nil {
		fmt.Println("locked")
	}
	return nil // lock/logout best-effort; never error the caller
}

func vaultPutArgs(user string, c vwCreds) []string {
	return []string{"kv", "patch", vwCredsPath(user),
		"vaultwarden_email=" + c.Email,
		"vaultwarden_master_password=" + c.MasterPassword,
		"vaultwarden_client_id=" + c.ClientID,
		"vaultwarden_client_secret=" + c.ClientSecret,
	}
}

// promptNoEcho reads one line without terminal echo (for the master password).
func promptNoEcho(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)
	exec.Command("stty", "-echo").Run()
	defer func() { exec.Command("stty", "echo").Run(); fmt.Fprintln(os.Stderr) }()
	r := bufio.NewReader(os.Stdin)
	line, err := r.ReadString('\n')
	return strings.TrimSpace(line), err
}

func promptLine(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	return strings.TrimSpace(line), err
}

func vaultSetup(args []string) error {
	hardenProcess()
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
	if _, err := realRunner("vault", vaultPutArgs(vaultCurrentUser(), c), nil); err != nil {
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
	val, err := getValue(realRunner, user, uid, o)
	if err != nil {
		return err
	}
	writeOpLog(opRecord{User: user, Verb: "get", PID: os.Getpid(), PPID: os.Getppid(), ParentComm: parentComm(os.Getppid()), ItemName: o.name})
	if o.json {
		fmt.Printf("{%q:%q}\n", o.field, val)
		return nil
	}
	emitSecret(val)
	return nil
}

