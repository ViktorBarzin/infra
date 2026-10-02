package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeDelegationAPI is an in-memory delegationAPI that records every call, so
// the flow tests can assert both what reached the API and in what order.
type fakeDelegationAPI struct {
	calls     []string
	created   delegationCreate
	createErr error
	sentErr   error
	reason    string
	// gets is the sequence of statuses Get returns, one per call; the last
	// one repeats.
	gets   []delegation
	getErr []error
	getN   int
	waits  []int
	listed []delegation
}

func (f *fakeDelegationAPI) Create(c delegationCreate) (delegation, error) {
	f.calls = append(f.calls, "create")
	f.created = c
	if f.createErr != nil {
		return delegation{}, f.createErr
	}
	return delegation{
		ID: "d_01TEST", Caller: c.Caller, CreatedBy: "homelab", Task: c.Task,
		Status: "pending", Message: "[homelab delegation d_01TEST]\nfrom: session x\n\n" + c.Task,
		ExpiresAt: "2026-10-03T12:00:00Z",
	}, nil
}

func (f *fakeDelegationAPI) MarkSent(id string) (delegation, error) {
	f.calls = append(f.calls, "sent:"+id)
	if f.sentErr != nil {
		return delegation{}, f.sentErr
	}
	return delegation{ID: id, Status: "sent"}, nil
}

func (f *fakeDelegationAPI) MarkUndelivered(id, reason string) (delegation, error) {
	f.calls = append(f.calls, "undelivered:"+id)
	f.reason = reason
	return delegation{ID: id, Status: "undelivered", Reason: reason}, nil
}

func (f *fakeDelegationAPI) Get(id string, wait int) (delegation, error) {
	f.calls = append(f.calls, "get:"+id)
	f.waits = append(f.waits, wait)
	i := f.getN
	f.getN++
	if i < len(f.getErr) && f.getErr[i] != nil {
		return delegation{}, f.getErr[i]
	}
	if len(f.gets) == 0 {
		return delegation{ID: id, Status: "sent"}, nil
	}
	if i >= len(f.gets) {
		i = len(f.gets) - 1
	}
	return f.gets[i], nil
}

func (f *fakeDelegationAPI) List(status string, limit int) ([]delegation, error) {
	f.calls = append(f.calls, fmt.Sprintf("list:%s:%d", status, limit))
	return f.listed, nil
}

type fakeSender struct {
	to, text string
	n        int
	err      error
}

func (s *fakeSender) send(to, text string) error {
	s.n++
	s.to, s.text = to, text
	return s.err
}

// delegateFixture writes the two contact files into a temp dir and returns
// deps wired to fakes.
func delegateFixture(t *testing.T, contacts, allowlist string) (delegateDeps, *fakeDelegationAPI, *fakeSender, *bytes.Buffer) {
	t.Helper()
	dir := t.TempDir()
	cp := filepath.Join(dir, "delegate-contacts")
	ap := filepath.Join(dir, "message-allowlist")
	if contacts != "" {
		if err := os.WriteFile(cp, []byte(contacts), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if allowlist != "" {
		if err := os.WriteFile(ap, []byte(allowlist), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	api := &fakeDelegationAPI{}
	snd := &fakeSender{}
	out := &bytes.Buffer{}
	return delegateDeps{
		api:          api,
		send:         snd.send,
		contactsPath: cp,
		allowPath:    ap,
		out:          out,
		sleep:        func(time.Duration) {},
		now:          func() time.Time { return time.Date(2026, 10, 2, 12, 0, 0, 0, time.UTC) },
	}, api, snd, out
}

func TestParseDelegateContacts(t *testing.T) {
	got := parseDelegateContacts("# callers\nmuse = Muse (Meta AI)\n\nbad line\nother=Someone=Else\n")
	if got["muse"] != "Muse (Meta AI)" {
		t.Errorf("muse = %q", got["muse"])
	}
	if got["other"] != "Someone=Else" {
		t.Errorf("other = %q (only the first = splits)", got["other"])
	}
	if len(got) != 2 {
		t.Errorf("got %v, want 2 entries (the line without = is ignored)", got)
	}
}

func TestParseDelegateExpiry(t *testing.T) {
	cases := []struct {
		in      string
		want    int
		wantErr bool
	}{
		{"", 0, false}, // unset: let agent-api apply its 24h default
		{"24h", 86400, false},
		{"90m", 5400, false},
		{"3d", 259200, false},
		{"14d", 1209600, false},
		{"15d", 0, true}, // over the 14-day maximum
		{"0s", 0, true},
		{"-1h", 0, true},
		{"30s", 0, true}, // under a minute is a typo, not a deadline
		{"soon", 0, true},
	}
	for _, c := range cases {
		got, err := parseDelegateExpiry(c.in)
		if (err != nil) != c.wantErr {
			t.Errorf("%q: err = %v, wantErr %v", c.in, err, c.wantErr)
			continue
		}
		if got != c.want {
			t.Errorf("%q = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestParseDelegateArgs(t *testing.T) {
	o, err := parseDelegateArgs([]string{"muse", "check", "my", "flight", "--wait", "--expires", "3d", "--from", "s1"})
	if err != nil {
		t.Fatal(err)
	}
	if o.caller != "muse" || o.task != "check my flight" || !o.wait || o.expiresIn != 259200 || o.from != "s1" {
		t.Errorf("%+v", o)
	}
	if _, err := parseDelegateArgs([]string{"muse"}); err == nil {
		t.Error("a delegation with no task must be refused")
	}
	if _, err := parseDelegateArgs([]string{"muse", "x", "--nope"}); err == nil {
		t.Error("unknown flag must error, not fall through")
	}
	if _, err := parseDelegateArgs([]string{"muse", strings.Repeat("a", 8001)}); err == nil {
		t.Error("a task over 8000 chars must be refused before it reaches the API")
	}
}

func TestDelegateRefusesWithoutBothContactFiles(t *testing.T) {
	cases := []struct {
		name, contacts, allow, wantErr string
	}{
		{"caller missing from delegate-contacts", "other=Bob\n", "Muse\n", "no WhatsApp chat configured for caller \"muse\""},
		{"contacts file missing", "", "Muse\n", "no WhatsApp chat configured for caller \"muse\""},
		{"chat not on the message allowlist", "muse=Muse\n", "Anca Milea\n", "not on the message allowlist"},
		{"allowlist missing", "muse=Muse\n", "", "not on the message allowlist"},
		// The allowlist resolves --to fuzzily for a human; an unattended send
		// gets no such latitude, so a near-match is still a refusal.
		{"near match is not enough", "muse=Muse\n", "Muse (Meta AI)\n", "not on the message allowlist"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			deps, api, snd, _ := delegateFixture(t, c.contacts, c.allow)
			err := runDelegate(delegateOpts{caller: "muse", task: "do it"}, deps)
			if err == nil || !strings.Contains(err.Error(), c.wantErr) {
				t.Fatalf("err = %v, want it to contain %q", err, c.wantErr)
			}
			if len(api.calls) != 0 {
				t.Errorf("API was called (%v); a refused delegation must not leave a pending record", api.calls)
			}
			if snd.n != 0 {
				t.Errorf("sender was called %d times", snd.n)
			}
		})
	}
}

func TestDelegateHappyPath(t *testing.T) {
	deps, api, snd, out := delegateFixture(t, "muse=Muse\n", "Muse\n")
	err := runDelegate(delegateOpts{caller: "muse", task: "check seat 32A", from: "terminal-lobby-404", expiresIn: 3600}, deps)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(api.calls, ",") != "create,sent:d_01TEST" {
		t.Errorf("calls = %v", api.calls)
	}
	if api.created.Caller != "muse" || api.created.Task != "check seat 32A" ||
		api.created.FromSession != "terminal-lobby-404" || api.created.ExpiresInS != 3600 {
		t.Errorf("create body = %+v", api.created)
	}
	// The text sent is exactly what agent-api rendered: the callback
	// instructions live in it, and the CLI must not rewrite them.
	if snd.to != "Muse" || !strings.HasPrefix(snd.text, "[homelab delegation d_01TEST]") {
		t.Errorf("sent to=%q text=%q", snd.to, snd.text)
	}
	if !strings.Contains(out.String(), "d_01TEST") {
		t.Errorf("output does not name the delegation id: %q", out.String())
	}
}

func TestDelegateUndeliveredOnSendError(t *testing.T) {
	deps, api, snd, _ := delegateFixture(t, "muse=Muse\n", "Muse\n")
	snd.err = &sendError{reason: "WhatsApp Web is logged out in the shared browser; re-link at chrome.viktorbarzin.me"}
	err := runDelegate(delegateOpts{caller: "muse", task: "x"}, deps)
	if err == nil {
		t.Fatal("a failed send must exit non-zero")
	}
	if strings.Join(api.calls, ",") != "create,undelivered:d_01TEST" {
		t.Errorf("calls = %v (want undelivered, never sent)", api.calls)
	}
	if !strings.Contains(api.reason, "re-link at chrome.viktorbarzin.me") {
		t.Errorf("reason = %q", api.reason)
	}
	if !strings.Contains(err.Error(), "re-link at chrome.viktorbarzin.me") {
		t.Errorf("err = %v, want the actionable reason", err)
	}
	if strings.Contains(err.Error(), "\n") {
		t.Errorf("err is not one line: %q", err.Error())
	}
}

func TestDelegateCapReached(t *testing.T) {
	deps, api, snd, _ := delegateFixture(t, "muse=Muse\n", "Muse\n")
	api.createErr = &apiError{status: 429, msg: "cap reached", retryAfter: 1200}
	err := runDelegate(delegateOpts{caller: "muse", task: "x"}, deps)
	if err == nil || !strings.Contains(err.Error(), "retry in 20m") {
		t.Fatalf("err = %v, want the Retry-After surfaced", err)
	}
	if snd.n != 0 {
		t.Error("nothing may be sent when the create was refused")
	}
}

func TestDelegateSentMarkFailureStillSucceeds(t *testing.T) {
	// The message is out; Muse can still post a result against a pending
	// delegation, so a failed /sent is a warning, not a failed delegation.
	deps, api, _, out := delegateFixture(t, "muse=Muse\n", "Muse\n")
	api.sentErr = errors.New("connection refused")
	if err := runDelegate(delegateOpts{caller: "muse", task: "x"}, deps); err != nil {
		t.Fatalf("err = %v", err)
	}
	if !strings.Contains(out.String(), "warning") {
		t.Errorf("want a warning in the output, got %q", out.String())
	}
}

func TestDelegateWaitLoop(t *testing.T) {
	t.Run("polls until done and prints the result", func(t *testing.T) {
		deps, api, _, out := delegateFixture(t, "muse=Muse\n", "Muse\n")
		api.gets = []delegation{
			{ID: "d_01TEST", Status: "sent", ExpiresAt: "2026-10-03T12:00:00Z"},
			{ID: "d_01TEST", Status: "sent", ExpiresAt: "2026-10-03T12:00:00Z"},
			{ID: "d_01TEST", Status: "done", Result: "seat 32A confirmed"},
		}
		if err := runDelegate(delegateOpts{caller: "muse", task: "x", wait: true}, deps); err != nil {
			t.Fatal(err)
		}
		if api.getN != 3 {
			t.Errorf("Get called %d times, want 3", api.getN)
		}
		for _, w := range api.waits {
			if w != 300 {
				t.Errorf("wait = %d, want the 300 s server maximum", w)
			}
		}
		if !strings.Contains(out.String(), "seat 32A confirmed") {
			t.Errorf("result not printed: %q", out.String())
		}
	})
	t.Run("failed exits non-zero with the result", func(t *testing.T) {
		deps, api, _, _ := delegateFixture(t, "", "")
		api.gets = []delegation{{ID: "d_1", Status: "failed", Result: "no such booking"}}
		err := waitDelegation("d_1", deps)
		if err == nil || !strings.Contains(err.Error(), "failed") {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("expired exits non-zero", func(t *testing.T) {
		deps, api, _, _ := delegateFixture(t, "", "")
		api.gets = []delegation{{ID: "d_1", Status: "sent"}, {ID: "d_1", Status: "expired"}}
		err := waitDelegation("d_1", deps)
		if err == nil || !strings.Contains(err.Error(), "expired") {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("undelivered exits non-zero with the reason", func(t *testing.T) {
		deps, api, _, _ := delegateFixture(t, "", "")
		api.gets = []delegation{{ID: "d_1", Status: "undelivered", Reason: "logged out"}}
		err := waitDelegation("d_1", deps)
		if err == nil || !strings.Contains(err.Error(), "logged out") {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("stops when the server never expires a delegation past its deadline", func(t *testing.T) {
		deps, api, _, _ := delegateFixture(t, "", "")
		// now is 2026-10-02T12:00Z; the deadline passed an hour ago and the
		// server still says sent. Waiting forever on it helps nobody.
		api.gets = []delegation{{ID: "d_1", Status: "sent", ExpiresAt: "2026-10-02T11:00:00Z"}}
		err := waitDelegation("d_1", deps)
		if err == nil || !strings.Contains(err.Error(), "past its expiry") {
			t.Fatalf("err = %v", err)
		}
		if api.getN > 2 {
			t.Errorf("kept polling %d times past the deadline", api.getN)
		}
	})
	t.Run("rides out transient errors, then gives up", func(t *testing.T) {
		deps, api, _, _ := delegateFixture(t, "", "")
		boom := errors.New("connection refused")
		api.getErr = []error{boom, boom, nil}
		api.gets = []delegation{{}, {}, {ID: "d_1", Status: "done", Result: "ok"}}
		if err := waitDelegation("d_1", deps); err != nil {
			t.Fatalf("two transient errors then done: err = %v", err)
		}
		deps2, api2, _, _ := delegateFixture(t, "", "")
		api2.getErr = []error{boom, boom, boom, boom, boom, boom, boom, boom}
		if err := waitDelegation("d_1", deps2); err == nil {
			t.Fatal("persistent errors must end the wait")
		}
	})
	t.Run("a 404 ends the wait at once", func(t *testing.T) {
		deps, api, _, _ := delegateFixture(t, "", "")
		api.getErr = []error{&apiError{status: 404, msg: "not found"}}
		if err := waitDelegation("d_1", deps); err == nil {
			t.Fatal("want an error")
		}
		if api.getN != 1 {
			t.Errorf("retried a 404 %d times", api.getN)
		}
	})
}

func TestClassifySendFailure(t *testing.T) {
	cases := []struct{ stderr, want string }{
		{"Error: WhatsApp Web is not logged in (no chat list appeared). Log in via noVNC", "re-link at chrome.viktorbarzin.me"},
		{"Error: contact not found in WhatsApp: Muse", "chat \"Muse\" not found in WhatsApp"},
		{"Error: recipient verification FAILED — opened chat is not \"Muse\"", "recipient verification failed"},
		{"chrome-service CDP not ready", "chrome-service"},
		{"", "WhatsApp send failed"},
	}
	for _, c := range cases {
		got := classifySendFailure("Muse", c.stderr, errors.New("exit status 1"))
		if !strings.Contains(got, c.want) {
			t.Errorf("stderr %q -> %q, want it to contain %q", c.stderr, got, c.want)
		}
		if strings.Contains(got, "\n") {
			t.Errorf("reason is not one line: %q", got)
		}
	}
}

// TestHTTPDelegationAPI drives the real client against an httptest server
// standing in for agent-api, so the wire shape matches the contract.
func TestHTTPDelegationAPI(t *testing.T) {
	var seen []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok123" {
			w.WriteHeader(401)
			return
		}
		body, _ := io.ReadAll(r.Body)
		seen = append(seen, r.Method+" "+r.URL.RequestURI()+" "+string(body))
		switch {
		case r.Method == "POST" && r.URL.Path == "/v1/delegations":
			var c map[string]any
			_ = json.Unmarshal(body, &c)
			if c["caller"] == "capped" {
				w.Header().Set("Retry-After", "60")
				w.WriteHeader(429)
				_, _ = w.Write([]byte(`{"error":"cap reached for capped"}`))
				return
			}
			w.WriteHeader(201)
			_, _ = w.Write([]byte(`{"delegation_id":"d_X","caller":"muse","status":"pending","message":"hi"}`))
		case r.Method == "POST" && r.URL.Path == "/v1/delegations/d_X/sent":
			_, _ = w.Write([]byte(`{"delegation_id":"d_X","status":"sent"}`))
		case r.Method == "POST" && r.URL.Path == "/v1/delegations/d_X/undelivered":
			_, _ = w.Write([]byte(`{"delegation_id":"d_X","status":"undelivered","reason":"r"}`))
		case r.Method == "GET" && r.URL.Path == "/v1/delegations/d_X":
			_, _ = w.Write([]byte(`{"delegation_id":"d_X","status":"done","result":"ok"}`))
		case r.Method == "GET" && r.URL.Path == "/v1/delegations":
			_, _ = w.Write([]byte(`{"delegations":[{"delegation_id":"d_X","status":"sent"}]}`))
		default:
			w.WriteHeader(404)
			_, _ = w.Write([]byte(`{"error":"unknown delegation"}`))
		}
	}))
	defer srv.Close()
	api := &httpDelegationAPI{base: srv.URL, token: "tok123", client: srv.Client()}

	d, err := api.Create(delegationCreate{Caller: "muse", Task: "t", FromSession: "s", ExpiresInS: 60})
	if err != nil || d.ID != "d_X" || d.Message != "hi" {
		t.Fatalf("create: %+v %v", d, err)
	}
	if !strings.Contains(seen[0], `"expires_in_s":60`) || !strings.Contains(seen[0], `"from_session":"s"`) {
		t.Errorf("create body = %s", seen[0])
	}
	if _, err := api.Create(delegationCreate{Caller: "capped", Task: "t"}); err == nil {
		t.Error("429 must be an error")
	} else {
		var ae *apiError
		if !errors.As(err, &ae) || ae.status != 429 || ae.retryAfter != 60 || !strings.Contains(ae.msg, "cap reached") {
			t.Errorf("429 err = %#v", err)
		}
	}
	// An unset expiry is omitted so agent-api applies its own default.
	_, _ = api.Create(delegationCreate{Caller: "muse", Task: "t"})
	if strings.Contains(seen[len(seen)-1], "expires_in_s") {
		t.Errorf("unset expiry was sent: %s", seen[len(seen)-1])
	}
	if d, err := api.MarkSent("d_X"); err != nil || d.Status != "sent" {
		t.Errorf("sent: %+v %v", d, err)
	}
	if d, err := api.MarkUndelivered("d_X", "r"); err != nil || d.Reason != "r" {
		t.Errorf("undelivered: %+v %v", d, err)
	}
	if !strings.Contains(seen[len(seen)-1], `{"reason":"r"}`) {
		t.Errorf("undelivered body = %s", seen[len(seen)-1])
	}
	if d, err := api.Get("d_X", 300); err != nil || d.Result != "ok" {
		t.Errorf("get: %+v %v", d, err)
	}
	if !strings.Contains(seen[len(seen)-1], "/v1/delegations/d_X?wait=300") {
		t.Errorf("get uri = %s", seen[len(seen)-1])
	}
	if ds, err := api.List("sent", 10); err != nil || len(ds) != 1 {
		t.Errorf("list: %+v %v", ds, err)
	}
	if !strings.Contains(seen[len(seen)-1], "status=sent") || !strings.Contains(seen[len(seen)-1], "limit=10") {
		t.Errorf("list uri = %s", seen[len(seen)-1])
	}
	_, err = api.Get("d_nope", 0)
	var ae *apiError
	if !errors.As(err, &ae) || ae.status != 404 {
		t.Errorf("404 err = %#v", err)
	}
}

func TestReadAgentAPIToken(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "agent-api-token")
	if _, err := readAgentAPIToken(p); err == nil || !strings.Contains(err.Error(), "playbook") {
		t.Errorf("missing file: err = %v, want a pointer at the playbook", err)
	}
	_ = os.WriteFile(p, []byte("  secret-token\n"), 0o600)
	tok, err := readAgentAPIToken(p)
	if err != nil || tok != "secret-token" {
		t.Errorf("tok=%q err=%v", tok, err)
	}
	_ = os.WriteFile(p, []byte("\n"), 0o600)
	if _, err := readAgentAPIToken(p); err == nil {
		t.Error("an empty token file must be an error")
	}
}
