package main

import (
	"strings"
	"testing"
	"time"
)

func TestGenInviteCode(t *testing.T) {
	seen := map[string]bool{}
	for n := 0; n < 200; n++ {
		c, err := genInviteCode()
		if err != nil {
			t.Fatalf("genInviteCode: %v", err)
		}
		if len(c) != 8 {
			t.Fatalf("code %q length = %d, want 8", c, len(c))
		}
		for _, r := range c {
			if !strings.ContainsRune(inviteAlphabet, r) {
				t.Fatalf("code %q has char %q outside alphabet", c, r)
			}
		}
		seen[c] = true
	}
	if len(seen) < 190 { // 200 draws from ~10^12 should essentially never collide
		t.Fatalf("only %d unique codes in 200 draws — entropy too low", len(seen))
	}
}

func TestParseExpiry(t *testing.T) {
	cases := []struct {
		in   string
		want time.Duration
		ok   bool
	}{
		{"7d", 7 * 24 * time.Hour, true},
		{"1d", 24 * time.Hour, true},
		{"48h", 48 * time.Hour, true},
		{"30m", 30 * time.Minute, true},
		{" 7d ", 7 * 24 * time.Hour, true},
		{"", 0, false},
		{"0d", 0, false},
		{"-1d", 0, false},
		{"banana", 0, false},
		{"7x", 0, false},
	}
	for _, c := range cases {
		got, err := parseExpiry(c.in)
		if c.ok {
			if err != nil || got != c.want {
				t.Errorf("parseExpiry(%q) = %v, %v; want %v, nil", c.in, got, err, c.want)
			}
		} else if err == nil {
			t.Errorf("parseExpiry(%q) = %v, nil; want error", c.in, got)
		}
	}
}

func TestBuildInvitePayload(t *testing.T) {
	exp := time.Date(2026, 8, 2, 10, 0, 0, 0, time.UTC)
	p := buildInvitePayload("ABCD2345", "Proxy Users", true, exp)
	if p["single_use"] != true {
		t.Errorf("single_use = %v, want true", p["single_use"])
	}
	if p["expires"] != "2026-08-02T10:00:00Z" {
		t.Errorf("expires = %v, want RFC3339 UTC", p["expires"])
	}
	fd, ok := p["fixed_data"].(map[string]interface{})
	if !ok {
		t.Fatalf("fixed_data not a map: %T", p["fixed_data"])
	}
	if fd["code"] != "ABCD2345" {
		t.Errorf("fixed_data.code = %v, want ABCD2345", fd["code"])
	}
	if fd["target_group"] != "Proxy Users" {
		t.Errorf("fixed_data.target_group = %v, want Proxy Users", fd["target_group"])
	}
	if name, _ := p["name"].(string); !strings.HasPrefix(name, "invite-") {
		t.Errorf("name = %v, want invite-<code>", p["name"])
	}
}

func TestParseInviteList(t *testing.T) {
	js := `{"results":[
	  {"pk":"11","name":"invite-abcd2345","expires":"2026-08-02T10:00:00Z","single_use":true,"fixed_data":{"code":"ABCD2345","target_group":"Proxy Users"}},
	  {"pk":"22","name":"legacy-proxy-signup","single_use":false,"fixed_data":{"attributes.proxy_only":true}},
	  {"pk":"33","name":"invite-wxyz6789","single_use":false,"fixed_data":{"code":"WXYZ6789","target_group":"TripIt Users"}}
	]}`
	got, err := parseInviteList(js)
	if err != nil {
		t.Fatalf("parseInviteList: %v", err)
	}
	// only the two entries carrying an invite code are returned (legacy one dropped)
	if len(got) != 2 {
		t.Fatalf("got %d invites, want 2 (code-bearing only)", len(got))
	}
	if got[0].code() != "ABCD2345" || got[0].group() != "Proxy Users" {
		t.Errorf("invite[0] = %q/%q, want ABCD2345/Proxy Users", got[0].code(), got[0].group())
	}
	if got[1].code() != "WXYZ6789" || got[1].group() != "TripIt Users" {
		t.Errorf("invite[1] = %q/%q, want WXYZ6789/TripIt Users", got[1].code(), got[1].group())
	}
}
