package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// `vault put` is the WRITE side of the Vaultwarden verbs: it creates or updates
// one login in the caller's own password-manager vault. It exists so a value
// held in the HashiCorp KV store can reach the password manager — and therefore
// the phone in your pocket — without a human copy-pasting it out of a web UI,
// and without a script that asks for the master password on every run
// (infra#94).
//
// TWO STORES, TWO TOKENS, IN THIS ORDER. `--from-kv` reads the HashiCorp side,
// which needs the caller's OWN Vault token; the Vaultwarden side needs the
// scoped workstation-claude-<user> token, which has `deny` everywhere except
// secret/workstation/claude-users/<user>. So every KV read happens FIRST, under
// ensureVaultAddr() alone, and only then does ensureVaultToken() swap in the
// scoped token for the bw session. Resolving in the other order 403s on any
// path outside the caller's own claude-users entry.
//
// Values never travel in argv. The item JSON — password and all — is
// base64-encoded and piped to `bw create item` / `bw edit item` on stdin, the
// same discipline the read verbs and `vault kv put` already keep, because argv
// is readable via ps / /proc/<pid>/cmdline by any process of the same UID.
// The two flags that take a literal secret on the command line (--field, --totp)
// are the documented exception, and say so on stderr — see argvExposureWarning.

const (
	// bwItemTypeLogin is the Bitwarden item type for a login (1). The other
	// types (secure note, card, identity) are out of scope for this verb.
	bwItemTypeLogin = 1
	// bwFieldHidden is the custom-field type the web UI masks, the way it masks
	// a password. Everything `put` writes as a custom field is a credential
	// until proven otherwise, so it goes in hidden.
	bwFieldHidden = 1
)

// putField is one requested custom field, before its value is resolved.
// Exactly one of Value / KVRef is meaningful, per FromKV.
type putField struct {
	Name   string
	Value  string // literal, when FromKV is false
	KVRef  string // "<path>#<key>", when FromKV is true
	FromKV bool
}

// putOpts is a parsed `vault put` argv. The Has* flags distinguish "not asked
// for" from "asked for, empty" — an update must leave an untouched field alone
// rather than blanking it.
type putOpts struct {
	Name          string
	Username      string
	HasUsername   bool
	URIs          []string
	HasURIs       bool
	Note          string
	HasNote       bool
	Fields        []putField
	TOTP          string
	TOTPKVRef     string
	HasTOTP       bool
	FromKV        string // password source: "<path>#<key>"
	PasswordStdin bool
	Update        bool
}

// nameValue is a resolved custom field.
type nameValue struct{ Name, Value string }

// putValues is everything secret, already resolved, ready to be written.
type putValues struct {
	Password string
	Fields   []nameValue
	TOTP     string
}

const putUsage = `usage: homelab vault put <item-name> (--from-kv <path>#<key> | --password-stdin)
              [--username U] [--uri URL]… [--note TEXT] [--update]
              [--field NAME=VALUE] [--field-from-kv NAME=<path>#<key>]
              [--totp SEED | --totp-from-kv <path>#<key>]`

// parsePutArgs parses the argv strictly. An argument that looks like a flag and
// is not one we know is an ERROR, a valueless flag is an ERROR, and a second
// bare word is an ERROR — never a silently-ignored token. This is the same
// failure class that made `vault kv get -field=x` dump 53 values on 2026-09-10
// and `vault get -field=username` hand back a password: a dropped argument
// leaves a default in place, and the default here writes to the wrong item or
// with the wrong value. Both dash spellings are accepted so muscle memory from
// the upstream CLIs lands on what the caller meant.
func parsePutArgs(args []string) (putOpts, error) {
	var o putOpts
	// need pulls the value of a flag written either as --flag=V or --flag V.
	need := func(i *int, name, value string, hasValue bool, what string) (string, error) {
		if hasValue {
			if value == "" {
				return "", fmt.Errorf("--%s needs %s", name, what)
			}
			return value, nil
		}
		if *i+1 >= len(args) || strings.HasPrefix(args[*i+1], "-") {
			return "", fmt.Errorf("--%s needs %s", name, what)
		}
		*i++
		return args[*i], nil
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "-") {
			if o.Name == "" {
				o.Name = a
				continue
			}
			return o, fmt.Errorf("unexpected argument %q; the item name is one argument — quote it: homelab vault put %q …", a, o.Name+" "+a)
		}
		name, value, hasValue := flagToken(a)
		var err error
		switch name {
		case "update":
			o.Update = true
		case "password-stdin":
			o.PasswordStdin = true
		case "from-kv":
			o.FromKV, err = need(&i, name, value, hasValue, "a reference like secret/emo/panels#password")
		case "username":
			o.Username, err = need(&i, name, value, hasValue, "a username")
			o.HasUsername = err == nil
		case "note":
			o.Note, err = need(&i, name, value, hasValue, "the note text")
			o.HasNote = err == nil
		case "uri":
			var u string
			if u, err = need(&i, name, value, hasValue, "a URL"); err == nil {
				o.URIs = append(o.URIs, u)
				o.HasURIs = true
			}
		case "totp":
			o.TOTP, err = need(&i, name, value, hasValue, "a TOTP seed")
			o.HasTOTP = err == nil
		case "totp-from-kv":
			o.TOTPKVRef, err = need(&i, name, value, hasValue, "a reference like secret/emo/panels#totp")
			o.HasTOTP = err == nil
		case "field", "field-from-kv":
			var spec string
			if spec, err = need(&i, name, value, hasValue, "NAME=VALUE"); err == nil {
				err = o.addField(name == "field-from-kv", spec)
			}
		default:
			return o, fmt.Errorf("unknown flag %q; `vault put` takes --from-kv/--password-stdin, --username, --uri, --note, --field, --field-from-kv, --totp, --totp-from-kv, --update", a)
		}
		if err != nil {
			return o, err
		}
	}
	if o.Name == "" {
		return o, fmt.Errorf(putUsage)
	}
	if o.PasswordStdin == (o.FromKV != "") {
		return o, fmt.Errorf("pass exactly one password source: --from-kv <path>#<key> (from the infra KV store) or --password-stdin (piped, or a no-echo prompt)")
	}
	if o.TOTP != "" && o.TOTPKVRef != "" {
		return o, fmt.Errorf("--totp and --totp-from-kv ask for the same field; pass one, not both")
	}
	return o, nil
}

// addField appends one --field / --field-from-kv spec. Duplicate names are
// rejected: Vaultwarden would hold both, and the read side (normalizeItem)
// collapses same-named fields last-wins, so a duplicate is a silent data loss
// waiting to happen rather than a thing anyone means.
func (o *putOpts) addField(fromKV bool, spec string) error {
	name, value, ok := strings.Cut(spec, "=")
	if !ok {
		return fmt.Errorf("--field%s wants NAME=VALUE, got %q", kvSuffix(fromKV), spec)
	}
	if name == "" {
		return fmt.Errorf("--field%s wants a field name before the '=', got %q", kvSuffix(fromKV), spec)
	}
	for _, f := range o.Fields {
		if f.Name == name {
			return fmt.Errorf("--field %q given twice; a Vaultwarden item should carry one field of each name", name)
		}
	}
	f := putField{Name: name, FromKV: fromKV}
	if fromKV {
		f.KVRef = value
	} else {
		f.Value = value
	}
	o.Fields = append(o.Fields, f)
	return nil
}

func kvSuffix(fromKV bool) string {
	if fromKV {
		return "-from-kv"
	}
	return ""
}

// parseKVRef splits a reference to one key of one KV secret. Both spellings
// work: the explicit `secret/emo/panels#password`, and the path form
// `secret/emo/panels/password` that `vault kv get` already accepts.
func parseKVRef(ref string) (path, key string, err error) {
	if p, k, ok := strings.Cut(ref, "#"); ok {
		if p == "" || k == "" {
			return "", "", fmt.Errorf("%q is not a KV reference; write it as <path>#<key>, e.g. secret/emo/panels#password", ref)
		}
		return p, k, nil
	}
	p, k, ok := splitKVFieldPath(ref)
	if !ok {
		return "", "", fmt.Errorf("%q is not a KV reference; write it as <path>#<key>, e.g. secret/emo/panels#password", ref)
	}
	return p, k, nil
}

// resolvePutValues turns every requested value into a real one. KV reads go
// through the caller's own Vault token (see the file header on ordering);
// readStdin is readSecretValue in production — piped stdin, or a no-echo
// prompt on a terminal.
func resolvePutValues(run cmdRunner, o putOpts, readStdin func(prompt string) (string, error)) (putValues, error) {
	var v putValues
	fromKV := func(ref, what string) (string, error) {
		path, key, err := parseKVRef(ref)
		if err != nil {
			return "", err
		}
		val, err := kvGetField(run, path, key)
		if err != nil {
			return "", fmt.Errorf("reading %s from %s: %w", key, path, err)
		}
		if val == "" {
			return "", fmt.Errorf("%s is empty at %s (key %q) — nothing written", what, path, key)
		}
		return val, nil
	}

	if o.PasswordStdin {
		pw, err := readStdin("Password for " + o.Name + ": ")
		if err != nil {
			return v, err
		}
		if pw == "" {
			return v, fmt.Errorf("empty password; aborting (nothing written)")
		}
		v.Password = pw
	} else {
		pw, err := fromKV(o.FromKV, "the password")
		if err != nil {
			return v, err
		}
		v.Password = pw
	}

	for _, f := range o.Fields {
		val := f.Value
		if f.FromKV {
			got, err := fromKV(f.KVRef, "field "+f.Name)
			if err != nil {
				return v, err
			}
			val = got
		}
		v.Fields = append(v.Fields, nameValue{Name: f.Name, Value: val})
	}

	switch {
	case o.TOTPKVRef != "":
		seed, err := fromKV(o.TOTPKVRef, "the TOTP seed")
		if err != nil {
			return v, err
		}
		v.TOTP = seed
	case o.TOTP != "":
		v.TOTP = o.TOTP
	}
	return v, nil
}

// argvExposureWarning names the values this invocation put in argv, where any
// process of the same UID could read them while the command ran. --field and
// --totp take a literal by design (infra#94, Viktor's call); the warning is how
// the caller learns the safe spelling exists.
func argvExposureWarning(o putOpts) string {
	var what []string
	for _, f := range o.Fields {
		if !f.FromKV {
			what = append(what, "--field "+f.Name)
		}
	}
	if o.TOTP != "" {
		what = append(what, "--totp")
	}
	if len(what) == 0 {
		return ""
	}
	return "note: the value(s) for " + strings.Join(what, ", ") +
		" were visible in this process's argv (ps, /proc) while it ran. " +
		"To keep a value out of argv, hold it in the KV store and pass --field-from-kv NAME=<path>#<key> / --totp-from-kv <path>#<key>."
}

// --- the item payload ------------------------------------------------------

type bwURI struct {
	Match *int   `json:"match"`
	URI   string `json:"uri"`
}

type bwLogin struct {
	URIs     []bwURI `json:"uris"`
	Username *string `json:"username"`
	Password string  `json:"password"`
	Totp     *string `json:"totp"`
}

type bwCustomField struct {
	Name  string `json:"name"`
	Value string `json:"value"`
	Type  int    `json:"type"`
}

// bwNewItem is the create payload. The null-valued keys are kept because that
// is the shape `bw create item` is known to accept.
type bwNewItem struct {
	OrganizationID *string         `json:"organizationId"`
	CollectionIDs  []string        `json:"collectionIds"`
	FolderID       *string         `json:"folderId"`
	Type           int             `json:"type"`
	Name           string          `json:"name"`
	Notes          *string         `json:"notes"`
	Favorite       bool            `json:"favorite"`
	Fields         []bwCustomField `json:"fields"`
	Reprompt       int             `json:"reprompt"`
	Login          bwLogin         `json:"login"`
	SecureNote     *struct{}       `json:"secureNote"`
	Card           *struct{}       `json:"card"`
	Identity       *struct{}       `json:"identity"`
}

func strPtr(s string) *string { return &s }

func uriList(urls []string) []bwURI {
	out := make([]bwURI, 0, len(urls))
	for _, u := range urls {
		out = append(out, bwURI{URI: u})
	}
	return out
}

// buildLoginItem renders the create payload. Pure, so the shape is unit-tested
// rather than discovered against a live vault.
func buildLoginItem(o putOpts, v putValues) ([]byte, error) {
	it := bwNewItem{
		Type:   bwItemTypeLogin,
		Name:   o.Name,
		Fields: []bwCustomField{},
		Login: bwLogin{
			URIs:     uriList(o.URIs),
			Password: v.Password,
		},
	}
	if o.HasUsername {
		it.Login.Username = strPtr(o.Username)
	}
	if v.TOTP != "" {
		it.Login.Totp = strPtr(v.TOTP)
	}
	if o.HasNote {
		it.Notes = strPtr(o.Note)
	}
	for _, f := range v.Fields {
		it.Fields = append(it.Fields, bwCustomField{Name: f.Name, Value: f.Value, Type: bwFieldHidden})
	}
	return json.Marshal(it)
}

// mergeLoginItem applies the requested changes to the item bw returned, leaving
// everything that was not asked for exactly as it was. It works on the decoded
// object rather than a typed struct on purpose: an item carries keys this CLI
// does not model (folderId, collectionIds, passwordHistory, reprompt, and
// whatever a future Bitwarden release adds), and re-serialising from a struct
// would quietly drop them on every update.
func mergeLoginItem(existing string, o putOpts, v putValues) ([]byte, error) {
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(existing), &m); err != nil {
		return nil, fmt.Errorf("parse the existing item: %w", err)
	}
	t, ok := m["type"].(float64)
	if !ok || int(t) != bwItemTypeLogin {
		return nil, fmt.Errorf("%q is not a login item (type %v); `vault put` only writes logins — edit it in the web UI", o.Name, m["type"])
	}
	login, _ := m["login"].(map[string]interface{})
	if login == nil {
		login = map[string]interface{}{}
	}
	login["password"] = v.Password
	if o.HasUsername {
		login["username"] = o.Username
	}
	if o.HasURIs {
		login["uris"] = uriList(o.URIs)
	}
	if o.HasTOTP {
		login["totp"] = v.TOTP
	}
	m["login"] = login
	if o.HasNote {
		m["notes"] = o.Note
	}
	if len(v.Fields) > 0 {
		m["fields"] = mergeCustomFields(m["fields"], v.Fields)
	}
	return json.Marshal(m)
}

// mergeCustomFields replaces same-named fields in place (keeping the type the
// item already gave them, so a plain-text field stays plain text) and appends
// the rest as hidden. Fields the caller did not name are untouched.
func mergeCustomFields(existing interface{}, want []nameValue) []interface{} {
	out, _ := existing.([]interface{})
	for _, w := range want {
		replaced := false
		for _, e := range out {
			em, ok := e.(map[string]interface{})
			if !ok || em["name"] != w.Name {
				continue
			}
			em["value"] = w.Value
			replaced = true
			break
		}
		if !replaced {
			out = append(out, map[string]interface{}{
				"name": w.Name, "value": w.Value, "type": bwFieldHidden,
			})
		}
	}
	return out
}

// --- bw plumbing -----------------------------------------------------------

func bwCreateItemArgs() []string        { return []string{"create", "item"} }
func bwEditItemArgs(id string) []string { return []string{"edit", "item", id} }

// encodeItem is what `bw encode` does — base64 — done in-process so the payload
// never crosses a pipe between two commands, and fed to bw on stdin so it never
// lands in argv.
func encodeItem(payload []byte) string {
	return base64.StdEncoding.EncodeToString(payload) + "\n"
}

// exactItemIDs keeps only the items whose name matches exactly. bw's --search is
// a fuzzy substring match, so "Вермонт панели" also returns "Вермонт панели
// (стар)" — deciding that an item "already exists" on that basis would refuse a
// legitimate create, or update the wrong login.
func exactItemIDs(listJSON, name string) []string {
	var items []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err := json.Unmarshal([]byte(listJSON), &items); err != nil {
		return nil
	}
	var out []string
	for _, it := range items {
		if it.Name == name {
			out = append(out, it.ID)
		}
	}
	return out
}

func findItemIDs(run cmdRunner, env []string, name string) ([]string, error) {
	out, err := run("bw", bwListArgs(name), env)
	if err != nil {
		return nil, err
	}
	return exactItemIDs(out, name), nil
}

// putItem creates or updates the item and reports which it did. Create is the
// default and a name collision is refused, because an unintended update
// overwrites a working credential while an unintended create is visible and
// harmless.
func putItem(run cmdRunner, runStdin cmdRunnerStdin, env []string, o putOpts, v putValues) (string, error) {
	ids, err := findItemIDs(run, env, o.Name)
	if err != nil {
		return "", fmt.Errorf("looking for an existing %q: %w", o.Name, err)
	}
	if len(ids) > 1 {
		return "", fmt.Errorf("%d items are already named %q (%s); `vault put` cannot tell which one you mean — rename one in the web UI first",
			len(ids), o.Name, strings.Join(ids, ", "))
	}
	if len(ids) == 0 {
		payload, err := buildLoginItem(o, v)
		if err != nil {
			return "", err
		}
		if _, err := runStdin("bw", bwCreateItemArgs(), env, encodeItem(payload)); err != nil {
			return "", fmt.Errorf("bw create item failed: %w", err)
		}
		return "created", nil
	}
	if !o.Update {
		return "", fmt.Errorf("an item named %q already exists (id %s); pass --update to change it, or pick another name", o.Name, ids[0])
	}
	raw, err := run("bw", bwItemArgs(ids[0]), env)
	if err != nil {
		return "", fmt.Errorf("reading the existing %q: %w", o.Name, err)
	}
	payload, err := mergeLoginItem(raw, o, v)
	if err != nil {
		return "", err
	}
	if _, err := runStdin("bw", bwEditItemArgs(ids[0]), env, encodeItem(payload)); err != nil {
		return "", fmt.Errorf("bw edit item failed: %w", err)
	}
	return "updated", nil
}

// --- handler ---------------------------------------------------------------

func vaultPut(args []string) error {
	hardenProcess()
	o, err := parsePutArgs(args)
	if err != nil {
		return err
	}
	// Phase 1: the HashiCorp KV reads, on the caller's OWN token. This must
	// happen before ensureVaultToken() swaps in the scoped one (file header).
	ensureVaultAddr()
	v, err := resolvePutValues(realRunner, o, readSecretValue)
	if err != nil {
		return err
	}
	// Phase 2: Vaultwarden, which needs the scoped token to read the caller's
	// own bw credentials.
	ensureVaultToken()
	uid := vaultCurrentUID()
	unlock, err := withUserLock(uid)
	if err != nil {
		return err
	}
	defer unlock()
	user := vaultCurrentUser()
	s, err := openSession(realRunner, user, uid)
	if err != nil {
		return err
	}
	action, err := putItem(realRunner, realRunnerStdin, s.env, o, v)
	if err != nil {
		return err
	}
	writeOpLog(opRecord{User: user, Verb: "put", PID: os.Getpid(), PPID: os.Getppid(), ParentComm: parentComm(os.Getppid()), ItemName: o.Name})
	if w := argvExposureWarning(o); w != "" {
		fmt.Fprintln(os.Stderr, w)
	}
	fmt.Fprintf(os.Stderr, "%s %q in your Vaultwarden vault\n", action, o.Name)
	return nil
}
