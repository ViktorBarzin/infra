package main

// `homelab claude-sessions mcp-secrets`: the kept place for the MCP server
// secrets the session store leaves out (docs/plans/2026-11-11-disposable-devvm.md).
//
// The store keeps ~/.claude.json and ~/.codex/config.toml redacted: header
// values, keys in env, tokens inside a URL (the ha server's secret path) are
// blanked, and restore writes the files without them. This keeps those
// secrets in Vault, one secret per user, secret/workstation/<user>/mcp:
//
//	claude_json        JSON {"mcpServers": {name: entry}, "projects": {dir: {name: entry}}}:
//	                   each MCP server entry of ~/.claude.json that holds a secret, as it is live
//	codex_config_toml  JSON {"[table header]": "block"}: each table of ~/.codex/config.toml
//	                   that holds a secret, header line to the next header, as it is live
//
// capture reads the live files and merges into that secret (an entry captured
// now replaces the one before; one the files no longer have stays, unused).
// fill puts the secrets back into a restored file: an entry is replaced by
// its Vault copy only when it is exactly what the store's redaction makes of
// that copy, so a file on the live box, whose entries still hold their
// secrets, is never touched, and an entry that changed since the capture is
// reported instead of guessed at. Values are never printed.
//
// Both need a Vault token that can read secret/workstation/<user> (an
// admin's). Run as root, they read the user's files and write as the user
// (runuser, with no Vault token in its environment).

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

const codexConfigRel = ".codex/config.toml"

func mcpSecretsPath(user string) string { return "secret/workstation/" + user + "/mcp" }

// mcpKV is Vault's KV as these verbs use it.
type mcpKV interface {
	get(path string) (map[string]string, bool, error)
	put(path string, data map[string]string) error
}

type claudeMCPSecrets struct {
	Servers  map[string]any            `json:"mcpServers,omitempty"`
	Projects map[string]map[string]any `json:"projects,omitempty"`
}

// ---- what the store makes of an entry ---------------------------------------

func deepCopyJSON(v any) any {
	b, _ := json.Marshal(v)
	var out any
	json.Unmarshal(b, &out)
	return out
}

func jsonEqual(a, b any) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return bytes.Equal(x, y)
}

// stripEntry is an MCP server entry as a restored file holds it: redacted
// the way the ingest does, then without its redacted keys. changed says the
// redaction found something.
func stripEntry(name string, entry any) (any, bool) {
	changed := false
	v := redactJSON(deepCopyJSON(entry), tableMode(name, redactKeys), &changed)
	return dropRedacted(v), changed
}

// tomlBlock is one table of a TOML file: its header line (empty for what
// comes before the first one) and every line up to the next header.
type tomlBlock struct {
	header string
	lines  []string
}

func splitTOMLBlocks(content []byte) []tomlBlock {
	blocks := []tomlBlock{{}}
	for _, l := range strings.Split(string(content), "\n") {
		if strings.HasPrefix(strings.TrimSpace(l), "[") {
			blocks = append(blocks, tomlBlock{header: strings.TrimSpace(l)})
		}
		b := &blocks[len(blocks)-1]
		b.lines = append(b.lines, l)
	}
	return blocks
}

func joinTOMLBlocks(blocks []tomlBlock) []byte {
	var lines []string
	for _, b := range blocks {
		lines = append(lines, b.lines...)
	}
	return []byte(strings.Join(lines, "\n"))
}

// body is a block without its trailing blank lines, which depend on where
// the block sits in the file.
func (b tomlBlock) body() string { return strings.Join(b.lines[:b.bodyLen()], "\n") }

func (b tomlBlock) bodyLen() int {
	end := len(b.lines)
	for end > 0 && strings.TrimSpace(b.lines[end-1]) == "" {
		end--
	}
	return end
}

func stripTOML(block string) (string, bool) {
	red, changed := redactTOML([]byte(block))
	return string(withoutRedacted("config.toml", red)), changed
}

// ---- capture ------------------------------------------------------------------

func captureClaudeMCP(content []byte) (claudeMCPSecrets, error) {
	out := claudeMCPSecrets{Servers: map[string]any{}, Projects: map[string]map[string]any{}}
	var all map[string]any
	if err := json.Unmarshal(content, &all); err != nil {
		return out, fmt.Errorf("%s does not parse: %w", claudeJSONRel, err)
	}
	keep := func(servers any, into map[string]any) error {
		m, _ := servers.(map[string]any)
		for name, e := range m {
			if b, _ := json.Marshal(e); bytes.Contains(b, []byte(redactedValue)) {
				return fmt.Errorf("%s server %s holds %s: this file was restored and not filled yet", claudeJSONRel, name, redactedValue)
			}
			if _, changed := stripEntry(name, e); changed {
				into[name] = e
			}
		}
		return nil
	}
	if err := keep(all["mcpServers"], out.Servers); err != nil {
		return out, err
	}
	projects, _ := all["projects"].(map[string]any)
	for dir, pv := range projects {
		p, _ := pv.(map[string]any)
		got := map[string]any{}
		if err := keep(p["mcpServers"], got); err != nil {
			return out, err
		}
		if len(got) > 0 {
			out.Projects[dir] = got
		}
	}
	return out, nil
}

func captureCodexMCP(content []byte) map[string]string {
	out := map[string]string{}
	for _, b := range splitTOMLBlocks(content) {
		if _, changed := stripTOML(b.body()); changed {
			out[b.header] = b.body()
		}
	}
	return out
}

// readMCPSecrets reads the user's secret; a user with none gets empty maps.
func readMCPSecrets(kv mcpKV, user string) (claudeMCPSecrets, map[string]string, bool, error) {
	c := claudeMCPSecrets{Servers: map[string]any{}, Projects: map[string]map[string]any{}}
	codex := map[string]string{}
	d, found, err := kv.get(mcpSecretsPath(user))
	if err != nil || !found {
		return c, codex, false, err
	}
	if s := d["claude_json"]; s != "" {
		if err := json.Unmarshal([]byte(s), &c); err != nil {
			return c, codex, true, fmt.Errorf("claude_json in Vault: %w", err)
		}
		if c.Servers == nil {
			c.Servers = map[string]any{}
		}
		if c.Projects == nil {
			c.Projects = map[string]map[string]any{}
		}
	}
	if s := d["codex_config_toml"]; s != "" {
		if err := json.Unmarshal([]byte(s), &codex); err != nil {
			return c, codex, true, fmt.Errorf("codex_config_toml in Vault: %w", err)
		}
	}
	return c, codex, true, nil
}

// captureMCPSecrets stores the secret-bearing entries of the user's live
// files in Vault and returns their names.
func captureMCPSecrets(kv mcpKV, user, home string) ([]string, error) {
	c, codex, _, err := readMCPSecrets(kv, user)
	if err != nil {
		return nil, err
	}
	if b, err := readHomeFile(home, claudeJSONRel); err == nil {
		got, err := captureClaudeMCP(b)
		if err != nil {
			return nil, err
		}
		for n, e := range got.Servers {
			c.Servers[n] = e
		}
		for dir, m := range got.Projects {
			if c.Projects[dir] == nil {
				c.Projects[dir] = map[string]any{}
			}
			for n, e := range m {
				c.Projects[dir][n] = e
			}
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	if b, err := readHomeFile(home, codexConfigRel); err == nil {
		if bytes.Contains(b, []byte(redactedValue)) {
			return nil, fmt.Errorf("%s holds %s: this file was restored and not filled yet", codexConfigRel, redactedValue)
		}
		for h, block := range captureCodexMCP(b) {
			codex[h] = block
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	names := mcpSecretNames(c, codex)
	if len(names) == 0 {
		return nil, nil
	}
	cj, _ := json.Marshal(c)
	cx, _ := json.Marshal(codex)
	return names, kv.put(mcpSecretsPath(user), map[string]string{"claude_json": string(cj), "codex_config_toml": string(cx)})
}

func mcpSecretNames(c claudeMCPSecrets, codex map[string]string) []string {
	var names []string
	for n := range c.Servers {
		names = append(names, claudeJSONRel+" mcpServers."+n)
	}
	for dir, m := range c.Projects {
		for n := range m {
			names = append(names, claudeJSONRel+" projects["+dir+"].mcpServers."+n)
		}
	}
	for h := range codex {
		if h == "" {
			h = "(top level)"
		}
		names = append(names, codexConfigRel+" "+h)
	}
	sort.Strings(names)
	return names
}

func listMCPSecrets(kv mcpKV, user string) ([]string, error) {
	c, codex, _, err := readMCPSecrets(kv, user)
	return mcpSecretNames(c, codex), err
}

// ---- fill ---------------------------------------------------------------------

type fillResult struct {
	Filled []string // entries given their secrets back
	Differ []string // restored entries that no longer match Vault's copy: fill by hand
	Absent []string // entries Vault has that the file does not
}

// fillEntry decides one entry: the Vault copy when the file holds exactly
// the stripped form of it, else nothing.
func fillEntry(name string, have, vault any, label string, res *fillResult) (any, bool) {
	if jsonEqual(have, vault) {
		return nil, false
	}
	if s, _ := stripEntry(name, have); !jsonEqual(s, have) {
		return nil, false // the file's own secrets: the live box, or the user's change
	}
	if s, _ := stripEntry(name, vault); !jsonEqual(s, have) {
		res.Differ = append(res.Differ, label)
		return nil, false
	}
	res.Filled = append(res.Filled, label)
	return deepCopyJSON(vault), true
}

func fillClaudeJSON(content []byte, c claudeMCPSecrets, res *fillResult) ([]byte, bool, error) {
	var all map[string]any
	if err := json.Unmarshal(content, &all); err != nil {
		return nil, false, fmt.Errorf("%s does not parse: %w", claudeJSONRel, err)
	}
	changed := false
	fillMap := func(servers any, want map[string]any, prefix string) {
		m, _ := servers.(map[string]any)
		for _, name := range sortedKeys(want) {
			label := claudeJSONRel + " " + prefix + name
			have, ok := m[name]
			if !ok {
				res.Absent = append(res.Absent, label)
				continue
			}
			if v, ok := fillEntry(name, have, want[name], label, res); ok {
				m[name] = v
				changed = true
			}
		}
	}
	fillMap(all["mcpServers"], c.Servers, "mcpServers.")
	projects, _ := all["projects"].(map[string]any)
	for _, dir := range sortedKeys(c.Projects) {
		p, _ := projects[dir].(map[string]any)
		if p == nil {
			for n := range c.Projects[dir] {
				res.Absent = append(res.Absent, claudeJSONRel+" projects["+dir+"].mcpServers."+n)
			}
			continue
		}
		fillMap(p["mcpServers"], c.Projects[dir], "projects["+dir+"].mcpServers.")
	}
	if !changed {
		return content, false, nil
	}
	b, err := encodeSettingsJSON(all)
	return b, true, err
}

func fillCodexTOML(content []byte, want map[string]string, res *fillResult) ([]byte, bool) {
	blocks := splitTOMLBlocks(content)
	seen := map[string]bool{}
	changed := false
	for i, b := range blocks {
		vault, ok := want[b.header]
		if !ok || seen[b.header] {
			continue
		}
		seen[b.header] = true
		label := codexConfigRel + " " + b.header
		have := b.body()
		if have == vault {
			continue
		}
		if s, _ := stripTOML(have); s != have {
			continue
		}
		if s, _ := stripTOML(vault); s != have {
			res.Differ = append(res.Differ, label)
			continue
		}
		trailing := b.lines[b.bodyLen():]
		blocks[i].lines = append(strings.Split(vault, "\n"), trailing...)
		res.Filled = append(res.Filled, label)
		changed = true
	}
	for _, h := range sortedKeys(want) {
		if !seen[h] {
			res.Absent = append(res.Absent, codexConfigRel+" "+h)
		}
	}
	if !changed {
		return content, false
	}
	return joinTOMLBlocks(blocks), true
}

func sortedKeys[V any](m map[string]V) []string {
	var k []string
	for x := range m {
		k = append(k, x)
	}
	sort.Strings(k)
	return k
}

// homeWriter replaces a file in a home with new content, keeping its mode.
type homeWriter interface {
	write(home, rel string, mode fs.FileMode, content []byte) error
}

// directWriter writes as the caller: their own home, or a drill directory.
type directWriter struct{}

func (directWriter) write(home, rel string, mode fs.FileMode, content []byte) error {
	p := filepath.Join(home, filepath.FromSlash(rel))
	tmp := p + ".mcp-fill." + strconv.Itoa(os.Getpid())
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(content); err == nil {
		err = f.Chmod(mode)
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, p)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}

// userWriter writes as the user through runuser, content on stdin, with an
// environment that holds no Vault token: a user can read the environment of
// any process running as them.
type userWriter struct{ user string }

func (w userWriter) write(home, rel string, mode fs.FileMode, content []byte) error {
	p := filepath.Join(home, filepath.FromSlash(rel))
	cmd := exec.Command("runuser", "-u", w.user, "--", "sh", "-c",
		`umask 077; t="$1.mcp-fill.$$"; if cat > "$t" && chmod "$2" "$t" && mv -f "$t" "$1"; then exit 0; fi; rm -f "$t"; exit 1`,
		"_", p, fmt.Sprintf("%o", mode.Perm()))
	cmd.Env = []string{"PATH=/usr/local/bin:/usr/bin:/bin", "LANG=C.UTF-8"}
	cmd.Stdin = bytes.NewReader(content)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("writing %s as %s: %w: %s", rel, w.user, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

// readHomeFile reads home/rel when it is a regular file owned by the
// home's owner, never through a link.
func readHomeFile(home, rel string) ([]byte, error) {
	hfi, err := os.Lstat(home)
	if err != nil {
		return nil, err
	}
	f, fi, _, ok := openOwned(filepath.Join(home, filepath.FromSlash(rel)), hfi.Sys().(*syscall.Stat_t).Uid)
	if !ok {
		if _, err := os.Lstat(filepath.Join(home, filepath.FromSlash(rel))); err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("%s: not a regular file owned by the home's owner", rel)
	}
	defer f.Close()
	b := make([]byte, fi.Size())
	if _, err := f.ReadAt(b, 0); err != nil && fi.Size() > 0 {
		return nil, err
	}
	return b, nil
}

func fillMCPSecrets(kv mcpKV, user, home string, w homeWriter) (fillResult, error) {
	var res fillResult
	c, codex, found, err := readMCPSecrets(kv, user)
	if err != nil || !found {
		return res, err
	}
	type job struct {
		rel  string
		fill func([]byte) ([]byte, bool, error)
	}
	for _, j := range []job{
		{claudeJSONRel, func(b []byte) ([]byte, bool, error) { return fillClaudeJSON(b, c, &res) }},
		{codexConfigRel, func(b []byte) ([]byte, bool, error) { out, ch := fillCodexTOML(b, codex, &res); return out, ch, nil }},
	} {
		b, err := readHomeFile(home, j.rel)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return res, err
		}
		out, changed, err := j.fill(b)
		if err != nil {
			return res, err
		}
		if !changed {
			continue
		}
		fi, err := os.Lstat(filepath.Join(home, filepath.FromSlash(j.rel)))
		if err != nil {
			return res, err
		}
		if err := w.write(home, j.rel, fi.Mode().Perm(), out); err != nil {
			return res, err
		}
	}
	return res, nil
}

// ---- Vault through the CLI ------------------------------------------------------

// vaultCLI reads and writes KV v2 with the vault binary: the token comes from
// VAULT_TOKEN or ~/.vault-token, values travel on stdin and stdout only.
type vaultCLI struct{}

func (vaultCLI) get(p string) (map[string]string, bool, error) {
	cmd := exec.Command("vault", "kv", "get", "-format=json", p)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		if strings.Contains(stderr.String(), "No value found") {
			return nil, false, nil
		}
		return nil, false, fmt.Errorf("vault kv get %s: %v: %s", p, err, strings.TrimSpace(stderr.String()))
	}
	var env struct {
		Data struct {
			Data map[string]string `json:"data"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &env); err != nil {
		return nil, false, fmt.Errorf("vault kv get %s: %w", p, err)
	}
	return env.Data.Data, true, nil
}

func (vaultCLI) put(p string, data map[string]string) error {
	b, err := json.Marshal(data)
	if err != nil {
		return err
	}
	cmd := exec.Command("vault", "kv", "put", p, "-")
	cmd.Stdin = bytes.NewReader(b)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("vault kv put %s: %v: %s", p, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

// ---- the verb -------------------------------------------------------------------

const mcpSecretsUsage = `usage: homelab claude-sessions mcp-secrets (capture | fill | list) --user <name> [--home <dir>]
  capture  store the MCP server secrets of the user's live ~/.claude.json and ~/.codex/config.toml
           in Vault (secret/workstation/<user>/mcp), merged into what is there; refuses a file that
           still holds <redacted>
  fill     put them back into a restored, redacted copy of those files; touches only entries that
           are exactly what the session store made of the Vault copy, so live files are left alone
           (t3-provision-users runs it on every pass that holds an admin Vault token)
  list     the entries kept in Vault, names only
  --home   another directory instead of the user's home, such as a drill restore
Needs a Vault token that reads secret/workstation/<user> (VAULT_TOKEN or ~/.vault-token).
As root, read the token inside the command, never on the sudo line:
  sudo bash -c 'VAULT_TOKEN="$(cat "/home/$SUDO_USER/.vault-token")" exec homelab claude-sessions mcp-secrets capture --user emo'`

func claudeSessionsMCPSecrets(args []string) error {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		fmt.Println(mcpSecretsUsage)
		return nil
	}
	verb, who, home := args[0], "", ""
	for i := 1; i < len(args); i++ {
		if i+1 >= len(args) {
			return fmt.Errorf("%s needs a value\n%s", args[i], mcpSecretsUsage)
		}
		switch args[i] {
		case "--user":
			who = args[i+1]
		case "--home":
			home = args[i+1]
		default:
			return fmt.Errorf("unknown argument %q\n%s", args[i], mcpSecretsUsage)
		}
		i++
	}
	if who == "" {
		if u, err := user.Current(); err == nil {
			who = u.Username
		}
	}
	if !restoreUserRe.MatchString(who) {
		return fmt.Errorf("--user takes a plain user name\n%s", mcpSecretsUsage)
	}
	ensureVaultAddr()
	kv := vaultCLI{}
	if verb == "list" {
		names, err := listMCPSecrets(kv, who)
		for _, n := range names {
			fmt.Println(n)
		}
		return err
	}
	if verb != "capture" && verb != "fill" {
		return fmt.Errorf("unknown verb %q\n%s", verb, mcpSecretsUsage)
	}
	u, err := user.Lookup(who)
	if err != nil {
		return err
	}
	if home == "" {
		home = u.HomeDir
	}
	home = filepath.Clean(home)
	fi, err := os.Lstat(home)
	if err != nil || !fi.IsDir() {
		return fmt.Errorf("%s is not a directory", home)
	}
	owner := strconv.FormatUint(uint64(fi.Sys().(*syscall.Stat_t).Uid), 10)
	if verb == "capture" {
		names, err := captureMCPSecrets(kv, who, home)
		if err != nil {
			return err
		}
		if len(names) == 0 {
			fmt.Fprintf(os.Stderr, "mcp-secrets capture user=%s: no MCP server secrets in the live files, nothing stored\n", who)
			return nil
		}
		fmt.Fprintf(os.Stderr, "mcp-secrets capture user=%s: %d entries kept in %s\n", who, len(names), mcpSecretsPath(who))
		for _, n := range names {
			fmt.Fprintf(os.Stderr, "  %s\n", n)
		}
		return nil
	}
	var w homeWriter = directWriter{}
	if os.Geteuid() == 0 && owner != "0" {
		if owner != u.Uid {
			return fmt.Errorf("%s belongs to uid %s, not %s: as root, fill only a directory the user owns", home, owner, who)
		}
		w = userWriter{user: who}
	} else if strconv.Itoa(os.Geteuid()) != owner {
		return fmt.Errorf("%s is not yours: fill another user's home as root", home)
	}
	res, err := fillMCPSecrets(kv, who, home, w)
	// Quiet when there is nothing to do: provisioning runs this every pass.
	for _, f := range res.Filled {
		fmt.Fprintf(os.Stderr, "mcp-secrets fill user=%s: secrets put back: %s\n", who, f)
	}
	for _, d := range res.Differ {
		fmt.Fprintf(os.Stderr, "mcp-secrets fill user=%s: WARN the restored entry differs from the Vault copy, fill by hand: %s\n", who, d)
	}
	return err
}
