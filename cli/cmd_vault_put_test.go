package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// putFakeRunner records argv AND stdin for every call, so a test can assert
// both what bw/vault were asked to do and that no secret travelled in argv.
type putFakeRunner struct {
	calls  [][]string
	stdins []string
	out    map[string]string // exact key: name + " " + strings.Join(argv, " ")
	err    map[string]error
}

func (r *putFakeRunner) run(name string, argv, envv []string) (string, error) {
	r.calls = append(r.calls, append([]string{name}, argv...))
	r.stdins = append(r.stdins, "")
	return r.answer(name, argv)
}

func (r *putFakeRunner) runStdin(name string, argv, envv []string, stdin string) (string, error) {
	r.calls = append(r.calls, append([]string{name}, argv...))
	r.stdins = append(r.stdins, stdin)
	return r.answer(name, argv)
}

func (r *putFakeRunner) answer(name string, argv []string) (string, error) {
	key := name + " " + strings.Join(argv, " ")
	if e, ok := r.err[key]; ok {
		return "", e
	}
	if v, ok := r.out[key]; ok {
		return v, nil
	}
	return "", errors.New("unexpected call: " + key)
}

// argvHas reports whether s appears anywhere in any recorded argv. The whole
// point of the stdin plumbing is that this stays false for every secret.
func (r *putFakeRunner) argvHas(s string) bool {
	for _, c := range r.calls {
		for _, a := range c {
			if strings.Contains(a, s) {
				return true
			}
		}
	}
	return false
}

// lastStdinJSON base64-decodes the stdin of the last recorded call and parses
// it as the bw item payload.
func lastStdinJSON(t *testing.T, r *putFakeRunner) map[string]interface{} {
	t.Helper()
	raw := strings.TrimSpace(r.stdins[len(r.stdins)-1])
	dec, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		t.Fatalf("stdin is not base64: %v (%q)", err, raw)
	}
	var m map[string]interface{}
	if err := json.Unmarshal(dec, &m); err != nil {
		t.Fatalf("stdin is not JSON: %v (%s)", err, dec)
	}
	return m
}

// --- flag parsing ----------------------------------------------------------

func TestParsePutArgsMinimal(t *testing.T) {
	o, err := parsePutArgs([]string{"My Login", "--from-kv", "secret/emo/panels#password"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if o.Name != "My Login" {
		t.Errorf("name = %q, want %q", o.Name, "My Login")
	}
	if o.FromKV != "secret/emo/panels#password" {
		t.Errorf("FromKV = %q", o.FromKV)
	}
	if o.Update {
		t.Error("Update should default to false")
	}
}

func TestParsePutArgsAcceptsBothDashSpellings(t *testing.T) {
	for _, args := range [][]string{
		{"X", "-from-kv=secret/a/b#k", "-username=admin", "-update"},
		{"X", "--from-kv", "secret/a/b#k", "--username", "admin", "--update"},
		{"X", "--from-kv=secret/a/b#k", "--username=admin", "--update"},
	} {
		o, err := parsePutArgs(args)
		if err != nil {
			t.Fatalf("%v: unexpected error: %v", args, err)
		}
		if o.Username != "admin" || !o.HasUsername || !o.Update || o.FromKV != "secret/a/b#k" {
			t.Errorf("%v parsed to %+v", args, o)
		}
	}
}

func TestParsePutArgsRejectsUnknownFlag(t *testing.T) {
	_, err := parsePutArgs([]string{"X", "--password", "hunter2", "--from-kv", "secret/a/b#k"})
	if err == nil {
		t.Fatal("want an error for --password, got nil")
	}
	if !strings.Contains(err.Error(), "--password-stdin") {
		t.Errorf("error should point at the safe flag, got: %v", err)
	}
}

func TestParsePutArgsRejectsSecondBareWord(t *testing.T) {
	_, err := parsePutArgs([]string{"X", "Y", "--password-stdin"})
	if err == nil {
		t.Fatal("want an error for a second bare word, got nil")
	}
}

func TestParsePutArgsRequiresName(t *testing.T) {
	if _, err := parsePutArgs([]string{"--password-stdin"}); err == nil {
		t.Fatal("want an error with no item name, got nil")
	}
}

func TestParsePutArgsRequiresExactlyOnePasswordSource(t *testing.T) {
	if _, err := parsePutArgs([]string{"X"}); err == nil {
		t.Error("want an error with no password source, got nil")
	}
	_, err := parsePutArgs([]string{"X", "--password-stdin", "--from-kv", "secret/a/b#k"})
	if err == nil {
		t.Error("want an error with two password sources, got nil")
	}
}

func TestParsePutArgsFlagsNeedingAValue(t *testing.T) {
	// A valueless flag must error, never swallow the next flag or fall through
	// to a default — the same failure class as the 2026-09-10 kv leak.
	for _, args := range [][]string{
		{"X", "--from-kv"},
		{"X", "--username", "--password-stdin"},
		{"X", "--uri", "--password-stdin"},
		{"X", "--note", "--password-stdin"},
		{"X", "--field", "--password-stdin"},
		{"X", "--field-from-kv", "--password-stdin"},
		{"X", "--totp", "--password-stdin"},
	} {
		if _, err := parsePutArgs(args); err == nil {
			t.Errorf("%v: want an error, got nil", args)
		}
	}
}

func TestParsePutArgsURIsAreRepeatable(t *testing.T) {
	o, err := parsePutArgs([]string{"X", "--password-stdin", "--uri", "http://a", "--uri", "http://b"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(o.URIs) != 2 || o.URIs[0] != "http://a" || o.URIs[1] != "http://b" {
		t.Errorf("URIs = %v", o.URIs)
	}
}

func TestParsePutArgsCustomFields(t *testing.T) {
	o, err := parsePutArgs([]string{"X", "--password-stdin",
		"--field", "serial=AB-12", "--field-from-kv", "pin=secret/emo/panel#pin"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(o.Fields) != 2 {
		t.Fatalf("want 2 fields, got %d", len(o.Fields))
	}
	if o.Fields[0].Name != "serial" || o.Fields[0].Value != "AB-12" || o.Fields[0].FromKV {
		t.Errorf("literal field parsed as %+v", o.Fields[0])
	}
	if o.Fields[1].Name != "pin" || o.Fields[1].KVRef != "secret/emo/panel#pin" || !o.Fields[1].FromKV {
		t.Errorf("kv field parsed as %+v", o.Fields[1])
	}
}

func TestParsePutArgsCustomFieldSyntaxErrors(t *testing.T) {
	for _, args := range [][]string{
		{"X", "--password-stdin", "--field", "novalue"},                             // no '='
		{"X", "--password-stdin", "--field", "=orphan"},                             // no name
		{"X", "--password-stdin", "--field-from-kv", "novalue"},                     // no '='
		{"X", "--password-stdin", "--field", "a=1", "--field", "a=2"},               // duplicate
		{"X", "--password-stdin", "--field", "a=1", "--field-from-kv", "a=s/b/c#d"}, // duplicate across forms
	} {
		if _, err := parsePutArgs(args); err == nil {
			t.Errorf("%v: want an error, got nil", args)
		}
	}
}

func TestParsePutArgsTOTPSourcesAreExclusive(t *testing.T) {
	_, err := parsePutArgs([]string{"X", "--password-stdin", "--totp", "SEED", "--totp-from-kv", "secret/a/b#k"})
	if err == nil {
		t.Fatal("want an error for two TOTP sources, got nil")
	}
}

// --- KV reference parsing --------------------------------------------------

func TestParseKVRef(t *testing.T) {
	cases := []struct {
		in        string
		path, key string
		wantErr   bool
	}{
		{in: "secret/emo/panels#password", path: "secret/emo/panels", key: "password"},
		{in: "secret/emo/panels/password", path: "secret/emo/panels", key: "password"},
		{in: "secret/platform#cloudflare_api_key", path: "secret/platform", key: "cloudflare_api_key"},
		{in: "secret/emo/panels#", wantErr: true},
		{in: "#password", wantErr: true},
		{in: "secret/panels", wantErr: true}, // two segments: mount + secret, no key
		{in: "", wantErr: true},
	}
	for _, c := range cases {
		p, k, err := parseKVRef(c.in)
		if c.wantErr {
			if err == nil {
				t.Errorf("%q: want an error, got %q/%q", c.in, p, k)
			}
			continue
		}
		if err != nil {
			t.Errorf("%q: unexpected error: %v", c.in, err)
			continue
		}
		if p != c.path || k != c.key {
			t.Errorf("%q → %q/%q, want %q/%q", c.in, p, k, c.path, c.key)
		}
	}
}

// --- value resolution ------------------------------------------------------

func TestResolvePutValuesReadsKVWithoutArgvExposure(t *testing.T) {
	r := &putFakeRunner{out: map[string]string{
		"vault kv get -field=password secret/emo/panels": "FAKE_PANEL_PASSWORD",
		"vault kv get -field=pin secret/emo/panel":       "FAKE_PIN",
	}}
	o, err := parsePutArgs([]string{"X", "--from-kv", "secret/emo/panels#password",
		"--field-from-kv", "pin=secret/emo/panel#pin", "--field", "serial=AB-12"})
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	v, err := resolvePutValues(r.run, o, func(string) (string, error) {
		t.Fatal("stdin must not be read when --from-kv is given")
		return "", nil
	})
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if v.Password != "FAKE_PANEL_PASSWORD" {
		t.Errorf("password = %q", v.Password)
	}
	// Order follows the argv, so the KV-sourced field comes first here.
	if len(v.Fields) != 2 || v.Fields[0].Value != "FAKE_PIN" || v.Fields[1].Value != "AB-12" {
		t.Errorf("fields = %+v", v.Fields)
	}
	if r.argvHas("FAKE_PANEL_PASSWORD") || r.argvHas("FAKE_PIN") {
		t.Error("a resolved secret reached argv")
	}
}

func TestResolvePutValuesEmptyKVValueIsAnError(t *testing.T) {
	r := &putFakeRunner{out: map[string]string{
		"vault kv get -field=password secret/emo/panels": "",
	}}
	o, _ := parsePutArgs([]string{"X", "--from-kv", "secret/emo/panels#password"})
	if _, err := resolvePutValues(r.run, o, nil); err == nil {
		t.Fatal("want an error for an empty KV value, got nil")
	}
}

func TestResolvePutValuesPasswordStdin(t *testing.T) {
	r := &putFakeRunner{out: map[string]string{}}
	o, _ := parsePutArgs([]string{"X", "--password-stdin"})
	v, err := resolvePutValues(r.run, o, func(string) (string, error) { return "FROM-STDIN", nil })
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if v.Password != "FROM-STDIN" {
		t.Errorf("password = %q", v.Password)
	}
	if len(r.calls) != 0 {
		t.Errorf("no vault call expected, got %v", r.calls)
	}
}

func TestResolvePutValuesRejectsEmptyStdin(t *testing.T) {
	o, _ := parsePutArgs([]string{"X", "--password-stdin"})
	if _, err := resolvePutValues(nil, o, func(string) (string, error) { return "", nil }); err == nil {
		t.Fatal("want an error for an empty password, got nil")
	}
}

// --- item building ---------------------------------------------------------

func TestBuildLoginItemShape(t *testing.T) {
	o, _ := parsePutArgs([]string{"Вермонт панели (admin)", "--password-stdin",
		"--username", "admin", "--uri", "http://192.168.1.150:81", "--note", "шестте панела"})
	raw, err := buildLoginItem(o, putValues{Password: "FAKE_PW", Fields: []nameValue{{"pin", "FAKE_PIN"}}, TOTP: "FAKE_SEED"})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	var it struct {
		Type  int    `json:"type"`
		Name  string `json:"name"`
		Notes string `json:"notes"`
		Login struct {
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
	if err := json.Unmarshal(raw, &it); err != nil {
		t.Fatalf("unmarshal: %v\n%s", err, raw)
	}
	if it.Type != bwItemTypeLogin {
		t.Errorf("type = %d, want %d", it.Type, bwItemTypeLogin)
	}
	if it.Name != "Вермонт панели (admin)" {
		t.Errorf("name = %q", it.Name)
	}
	if it.Notes != "шестте панела" {
		t.Errorf("notes = %q", it.Notes)
	}
	if it.Login.Username != "admin" || it.Login.Password != "FAKE_PW" || it.Login.Totp != "FAKE_SEED" {
		t.Errorf("login = %+v", it.Login)
	}
	if len(it.Login.URIs) != 1 || it.Login.URIs[0].URI != "http://192.168.1.150:81" {
		t.Errorf("uris = %+v", it.Login.URIs)
	}
	// Custom fields written by `put` are HIDDEN, so the web UI masks them the
	// way it masks a password.
	if len(it.Fields) != 1 || it.Fields[0].Name != "pin" || it.Fields[0].Value != "FAKE_PIN" || it.Fields[0].Type != bwFieldHidden {
		t.Errorf("fields = %+v", it.Fields)
	}
}

func TestBuildLoginItemOmitsUnsetOptionals(t *testing.T) {
	o, _ := parsePutArgs([]string{"Bare", "--password-stdin"})
	raw, err := buildLoginItem(o, putValues{Password: "FAKE_PW"})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	var it map[string]interface{}
	json.Unmarshal(raw, &it)
	login := it["login"].(map[string]interface{})
	if login["username"] != nil {
		t.Errorf("username should be null, got %v", login["username"])
	}
	if login["totp"] != nil {
		t.Errorf("totp should be null, got %v", login["totp"])
	}
	if uris, ok := login["uris"].([]interface{}); ok && len(uris) != 0 {
		t.Errorf("uris should be empty, got %v", uris)
	}
}

// --- merge (the --update path) ---------------------------------------------

const existingItemJSON = `{
  "object": "item",
  "id": "ID-1",
  "organizationId": "ORG-1",
  "folderId": "FOLDER-1",
  "type": 1,
  "reprompt": 0,
  "name": "Вермонт панели (admin)",
  "notes": "старата бележка",
  "favorite": true,
  "collectionIds": ["COLL-1"],
  "passwordHistory": [{"lastUsedDate": "2026-01-01T00:00:00.000Z", "password": "OLD"}],
  "fields": [
    {"name": "pin", "value": "OLD_PIN", "type": 1},
    {"name": "serial", "value": "KEEP_ME", "type": 0}
  ],
  "login": {
    "username": "admin",
    "password": "OLD_PASSWORD",
    "totp": "OLD_SEED",
    "uris": [{"match": null, "uri": "http://old"}]
  }
}`

func TestMergeLoginItemKeepsWhatWasNotAsked(t *testing.T) {
	o, _ := parsePutArgs([]string{"Вермонт панели (admin)", "--password-stdin", "--update"})
	raw, err := mergeLoginItem(existingItemJSON, o, putValues{Password: "NEW_PASSWORD"})
	if err != nil {
		t.Fatalf("merge: %v", err)
	}
	var m map[string]interface{}
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if m["folderId"] != "FOLDER-1" || m["organizationId"] != "ORG-1" || m["favorite"] != true {
		t.Errorf("untouched top-level keys changed: %v", m)
	}
	if m["passwordHistory"] == nil {
		t.Error("passwordHistory was dropped")
	}
	if m["notes"] != "старата бележка" {
		t.Errorf("notes changed without --note: %v", m["notes"])
	}
	login := m["login"].(map[string]interface{})
	if login["password"] != "NEW_PASSWORD" {
		t.Errorf("password = %v", login["password"])
	}
	if login["username"] != "admin" {
		t.Errorf("username changed without --username: %v", login["username"])
	}
	if login["totp"] != "OLD_SEED" {
		t.Errorf("totp changed without --totp: %v", login["totp"])
	}
	uris := login["uris"].([]interface{})
	if len(uris) != 1 || uris[0].(map[string]interface{})["uri"] != "http://old" {
		t.Errorf("uris changed without --uri: %v", uris)
	}
	fields := m["fields"].([]interface{})
	if len(fields) != 2 {
		t.Errorf("fields = %v", fields)
	}
}

func TestMergeLoginItemReplacesNamedFieldAndKeepsOthers(t *testing.T) {
	o, _ := parsePutArgs([]string{"X", "--password-stdin", "--update",
		"--field", "pin=NEW_PIN", "--field", "extra=NEW_EXTRA",
		"--note", "нова бележка", "--uri", "http://new", "--totp", "NEW_SEED"})
	raw, err := mergeLoginItem(existingItemJSON, o, putValues{
		Password: "NEW_PASSWORD",
		Fields:   []nameValue{{"pin", "NEW_PIN"}, {"extra", "NEW_EXTRA"}},
		TOTP:     "NEW_SEED",
	})
	if err != nil {
		t.Fatalf("merge: %v", err)
	}
	var m map[string]interface{}
	json.Unmarshal(raw, &m)
	if m["notes"] != "нова бележка" {
		t.Errorf("notes = %v", m["notes"])
	}
	login := m["login"].(map[string]interface{})
	if login["totp"] != "NEW_SEED" {
		t.Errorf("totp = %v", login["totp"])
	}
	uris := login["uris"].([]interface{})
	if len(uris) != 1 || uris[0].(map[string]interface{})["uri"] != "http://new" {
		t.Errorf("uris = %v", uris)
	}
	got := map[string]interface{}{}
	for _, f := range m["fields"].([]interface{}) {
		fm := f.(map[string]interface{})
		got[fm["name"].(string)] = fm["value"]
	}
	if got["pin"] != "NEW_PIN" {
		t.Errorf("pin = %v, want NEW_PIN", got["pin"])
	}
	if got["serial"] != "KEEP_ME" {
		t.Errorf("serial = %v, want KEEP_ME (untouched fields survive)", got["serial"])
	}
	if got["extra"] != "NEW_EXTRA" {
		t.Errorf("extra = %v, want NEW_EXTRA (new field appended)", got["extra"])
	}
}

func TestMergeLoginItemRejectsANonLogin(t *testing.T) {
	o, _ := parsePutArgs([]string{"X", "--password-stdin", "--update"})
	if _, err := mergeLoginItem(`{"id":"ID-1","type":2,"name":"X","secureNote":{"type":0}}`, o, putValues{Password: "P"}); err == nil {
		t.Fatal("want an error updating a secure note as a login, got nil")
	}
}

// --- exact-name matching ---------------------------------------------------

func TestExactItemIDs(t *testing.T) {
	// bw's --search is a substring match, so the exact filter is ours to do.
	list := `[{"id":"A","name":"Вермонт панели (admin)"},
	          {"id":"B","name":"Вермонт панели (admin) стар"},
	          {"id":"C","name":"Вермонт панели (admin)"}]`
	got := exactItemIDs(list, "Вермонт панели (admin)")
	if len(got) != 2 || got[0] != "A" || got[1] != "C" {
		t.Errorf("exactItemIDs = %v, want [A C]", got)
	}
	if n := len(exactItemIDs(`[]`, "X")); n != 0 {
		t.Errorf("empty list → %d ids", n)
	}
}

// --- the write flow --------------------------------------------------------

func newPutRunner(listOut string) *putFakeRunner {
	return &putFakeRunner{out: map[string]string{
		"bw list items --search New Item": listOut,
		"bw create item":                  `{"id":"NEW-ID","name":"New Item"}`,
		"bw edit item ID-1":               `{"id":"ID-1","name":"New Item"}`,
		"bw get item ID-1":                existingItemJSON,
	}}
}

func TestPutItemCreatesWhenTheNameIsFree(t *testing.T) {
	r := newPutRunner(`[{"id":"OTHER","name":"New Item but longer"}]`)
	o, _ := parsePutArgs([]string{"New Item", "--password-stdin", "--username", "admin"})
	action, err := putItem(r.run, r.runStdin, nil, o, putValues{Password: "FAKE_PW"})
	if err != nil {
		t.Fatalf("putItem: %v", err)
	}
	if action != "created" {
		t.Errorf("action = %q, want created", action)
	}
	if r.argvHas("FAKE_PW") {
		t.Error("the password reached argv")
	}
	last := r.calls[len(r.calls)-1]
	if strings.Join(last, " ") != "bw create item" {
		t.Errorf("last call = %v, want `bw create item`", last)
	}
	item := lastStdinJSON(t, r)
	if item["login"].(map[string]interface{})["password"] != "FAKE_PW" {
		t.Errorf("password did not reach stdin: %v", item["login"])
	}
}

func TestPutItemRefusesAnExistingNameWithoutUpdate(t *testing.T) {
	r := newPutRunner(`[{"id":"ID-1","name":"New Item"}]`)
	o, _ := parsePutArgs([]string{"New Item", "--password-stdin"})
	_, err := putItem(r.run, r.runStdin, nil, o, putValues{Password: "FAKE_PW"})
	if err == nil {
		t.Fatal("want a refusal, got nil")
	}
	if !strings.Contains(err.Error(), "--update") {
		t.Errorf("the error must name the flag that proceeds, got: %v", err)
	}
	for _, c := range r.calls {
		if j := strings.Join(c, " "); strings.HasPrefix(j, "bw create") || strings.HasPrefix(j, "bw edit") {
			t.Errorf("a refused put still wrote: %v", c)
		}
	}
}

func TestPutItemUpdatesWithTheFlag(t *testing.T) {
	r := newPutRunner(`[{"id":"ID-1","name":"New Item"}]`)
	o, _ := parsePutArgs([]string{"New Item", "--password-stdin", "--update"})
	action, err := putItem(r.run, r.runStdin, nil, o, putValues{Password: "FAKE_PW"})
	if err != nil {
		t.Fatalf("putItem: %v", err)
	}
	if action != "updated" {
		t.Errorf("action = %q, want updated", action)
	}
	if r.argvHas("FAKE_PW") {
		t.Error("the password reached argv")
	}
	last := r.calls[len(r.calls)-1]
	if strings.Join(last, " ") != "bw edit item ID-1" {
		t.Errorf("last call = %v, want `bw edit item ID-1`", last)
	}
	item := lastStdinJSON(t, r)
	if item["login"].(map[string]interface{})["password"] != "FAKE_PW" {
		t.Error("the new password did not reach stdin")
	}
	if item["folderId"] != "FOLDER-1" {
		t.Errorf("the update dropped folderId: %v", item["folderId"])
	}
}

func TestPutItemRefusesAnAmbiguousName(t *testing.T) {
	r := newPutRunner(`[{"id":"ID-1","name":"New Item"},{"id":"ID-2","name":"New Item"}]`)
	o, _ := parsePutArgs([]string{"New Item", "--password-stdin", "--update"})
	_, err := putItem(r.run, r.runStdin, nil, o, putValues{Password: "FAKE_PW"})
	if err == nil {
		t.Fatal("want an error on two items with the same name, got nil")
	}
	if !strings.Contains(err.Error(), "ID-1") || !strings.Contains(err.Error(), "ID-2") {
		t.Errorf("the error should name both ids so the caller can pick, got: %v", err)
	}
}

// --- argv hygiene warning --------------------------------------------------

func TestArgvExposureWarning(t *testing.T) {
	literal, _ := parsePutArgs([]string{"X", "--password-stdin", "--field", "pin=1234"})
	if w := argvExposureWarning(literal); w == "" {
		t.Error("a literal --field value was visible in argv; the caller should be told")
	} else if !strings.Contains(w, "--field-from-kv") {
		t.Errorf("the warning should name the safe form, got: %q", w)
	}
	totp, _ := parsePutArgs([]string{"X", "--password-stdin", "--totp", "SEED"})
	if w := argvExposureWarning(totp); w == "" {
		t.Error("a literal --totp seed was visible in argv; the caller should be told")
	}
	clean, _ := parsePutArgs([]string{"X", "--from-kv", "secret/a/b#k", "--field-from-kv", "pin=secret/a/b#pin"})
	if w := argvExposureWarning(clean); w != "" {
		t.Errorf("nothing secret was in argv, but warned: %q", w)
	}
}

// --- registration ----------------------------------------------------------

func TestVaultPutIsRegisteredAsAWrite(t *testing.T) {
	var found *Command
	for i, c := range vaultCommands() {
		if strings.Join(c.Path, " ") == "vault put" {
			found = &vaultCommands()[i]
		}
	}
	if found == nil {
		t.Fatal("`vault put` is not registered")
	}
	if found.Tier != TierWrite {
		t.Errorf("tier = %q, want %q", found.Tier, TierWrite)
	}
	if !strings.Contains(found.Summary, "vaultwarden") {
		t.Errorf("summary should mark the store it writes to, got %q", found.Summary)
	}
}

func TestVaultHelpDocumentsPutAndTheReverseDirection(t *testing.T) {
	h := vaultHelp()
	if !strings.Contains(h, "vault put") {
		t.Error("help does not mention `vault put`")
	}
	// The Vaultwarden → KV direction needs no verb: the two existing ones pipe.
	if !strings.Contains(h, "homelab vault get") || !strings.Contains(h, "| homelab vault kv put") {
		t.Error("help does not show the pipe that moves a value the other way")
	}
}
