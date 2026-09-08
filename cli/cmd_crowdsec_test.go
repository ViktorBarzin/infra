package main

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestParseBanDuration(t *testing.T) {
	cases := []struct {
		name    string
		in      string
		want    time.Duration
		wantErr string
	}{
		{name: "empty uses the safe default", in: "", want: crowdsecDefaultBan},
		{name: "hours pass through", in: "4h", want: 4 * time.Hour},
		{name: "minutes pass through", in: "30m", want: 30 * time.Minute},
		{name: "days are accepted as a suffix", in: "3d", want: 72 * time.Hour},
		{name: "exactly at the cap is allowed", in: "168h", want: crowdsecMaxBan},
		{name: "cap expressed in days is allowed", in: "7d", want: crowdsecMaxBan},

		// The incident this cap exists for: a 363-day hand-written ban on our
		// own London WAN egress IP (2026-08-16), which stayed enforceable long
		// after anyone remembered adding it.
		{name: "the 363-day incident ban is refused", in: "8717h", wantErr: "exceeds the 168h cap"},
		{name: "a year in days is refused", in: "365d", wantErr: "exceeds the 168h cap"},
		{name: "just over the cap is refused", in: "169h", wantErr: "exceeds the 168h cap"},

		{name: "zero is refused", in: "0h", wantErr: "must be positive"},
		{name: "negative is refused", in: "-1h", wantErr: "must be positive"},
		{name: "garbage is refused", in: "soon", wantErr: "invalid duration"},
		{name: "bare number is refused", in: "24", wantErr: "invalid duration"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseBanDuration(tc.in)
			if tc.wantErr != "" {
				if err == nil {
					t.Fatalf("parseBanDuration(%q) = %v, want error containing %q", tc.in, got, tc.wantErr)
				}
				if !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("parseBanDuration(%q) error = %q, want it to contain %q", tc.in, err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseBanDuration(%q) unexpected error: %v", tc.in, err)
			}
			if got != tc.want {
				t.Fatalf("parseBanDuration(%q) = %v, want %v", tc.in, got, tc.want)
			}
		})
	}
}

func TestCrowdsecCapIsSevenDays(t *testing.T) {
	if crowdsecMaxBan != 168*time.Hour {
		t.Fatalf("crowdsecMaxBan = %v, want 168h (7d)", crowdsecMaxBan)
	}
	if crowdsecDefaultBan > crowdsecMaxBan {
		t.Fatalf("default ban %v must not exceed the cap %v", crowdsecDefaultBan, crowdsecMaxBan)
	}
}

func TestBanRequiresReason(t *testing.T) {
	if err := validateBanRequest("137.220.71.46", ""); err == nil {
		t.Fatal("validateBanRequest with an empty reason should fail: an unexplained ban is what made the 2026-08-16 incident hard to unwind")
	}
	if err := validateBanRequest("137.220.71.46", "linkwarden 401 retry loop"); err != nil {
		t.Fatalf("validateBanRequest with ip+reason should succeed, got %v", err)
	}
}

func TestBanRejectsNonIP(t *testing.T) {
	for _, bad := range []string{"", "not-an-ip", "137.220.71.", "bcube.co.uk"} {
		if err := validateBanRequest(bad, "reason"); err == nil {
			t.Fatalf("validateBanRequest(%q) should fail: only literal IPs are bannable", bad)
		}
	}
	// A CIDR is a legitimate scope for a ban and must keep working.
	if err := validateBanRequest("192.35.168.0/24", "scanner range"); err != nil {
		t.Fatalf("validateBanRequest with a CIDR should succeed, got %v", err)
	}
}

func TestHumanDuration(t *testing.T) {
	cases := map[time.Duration]string{
		168 * time.Hour:            "168h",
		24 * time.Hour:             "24h",
		30 * time.Minute:           "30m",
		90 * time.Minute:           "1h30m",
		10 * time.Second:           "10s", // naive suffix trimming would yield "1"
		time.Hour + 30*time.Second: "1h0m30s",
	}
	for in, want := range cases {
		if got := humanDuration(in); got != want {
			t.Errorf("humanDuration(%v) = %q, want %q", in, got, want)
		}
	}
}

// The bug this covers: `homelab crowdsec ban 2a03:2880::/32` failed with
// "2a03:2880::/32 is not a valid ip" because the wrapper always passed
// cscli's --ip flag. A CIDR — v4 or v6 — has to go to --range instead.
func TestParseBanTarget(t *testing.T) {
	cases := []struct {
		name     string
		in       string
		wantFlag string
		wantErr  string
	}{
		{name: "IPv4 address", in: "192.0.2.1", wantFlag: "--ip"},
		{name: "IPv6 address", in: "2001:db8::1", wantFlag: "--ip"},
		{name: "IPv6 loopback", in: "::1", wantFlag: "--ip"},
		{name: "IPv4-mapped IPv6 address", in: "::ffff:192.0.2.1", wantFlag: "--ip"},
		{name: "IPv4 CIDR", in: "192.0.2.0/24", wantFlag: "--range"},
		{name: "the reported IPv6 CIDR", in: "2a03:2880::/32", wantFlag: "--range"},
		{name: "IPv6 documentation CIDR", in: "2001:db8::/32", wantFlag: "--range"},
		{name: "single-address IPv4 CIDR", in: "192.0.2.1/32", wantFlag: "--range"},
		{name: "single-address IPv6 CIDR", in: "2001:db8::1/128", wantFlag: "--range"},
		{name: "surrounding whitespace is trimmed", in: "  2a03:2880::/32  ", wantFlag: "--range"},

		{name: "empty is refused", in: "", wantErr: "required"},
		{name: "hostname is refused", in: "bcube.co.uk", wantErr: "not a valid IP"},
		{name: "garbage is refused", in: "not-an-ip", wantErr: "not a valid IP"},
		{name: "truncated IPv4 is refused", in: "137.220.71.", wantErr: "not a valid IP"},
		{name: "hostname with a mask is refused", in: "example.com/24", wantErr: "not a valid CIDR"},
		{name: "IPv4 prefix out of range is refused", in: "192.0.2.0/33", wantErr: "not a valid CIDR"},
		{name: "IPv6 prefix out of range is refused", in: "2a03:2880::/129", wantErr: "not a valid CIDR"},
		{name: "empty prefix length is refused", in: "2a03:2880::/", wantErr: "not a valid CIDR"},
		{name: "malformed IPv6 is refused", in: "2a03::2880::1", wantErr: "not a valid IP"},
		{name: "a zoned link-local address is refused", in: "fe80::1%eth0", wantErr: "not a valid IP"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			flag, value, err := parseBanTarget(tc.in)
			if tc.wantErr != "" {
				if err == nil {
					t.Fatalf("parseBanTarget(%q) = (%q, %q), want error containing %q", tc.in, flag, value, tc.wantErr)
				}
				if !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("parseBanTarget(%q) error = %q, want it to contain %q", tc.in, err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseBanTarget(%q) unexpected error: %v", tc.in, err)
			}
			if flag != tc.wantFlag {
				t.Fatalf("parseBanTarget(%q) flag = %q, want %q", tc.in, flag, tc.wantFlag)
			}
			if want := strings.TrimSpace(tc.in); value != want {
				t.Fatalf("parseBanTarget(%q) value = %q, want the address as typed %q", tc.in, value, want)
			}
		})
	}
}

func TestValidateBanRequestAcceptsEveryAddressShape(t *testing.T) {
	for _, target := range []string{"192.0.2.1", "2001:db8::1", "192.0.2.0/24", "2a03:2880::/32"} {
		if err := validateBanRequest(target, "meta crawler swarm"); err != nil {
			t.Errorf("validateBanRequest(%q) should succeed, got %v", target, err)
		}
	}
}

func TestCscliAddArgs(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want []string
	}{
		{name: "IPv4 address goes to --ip", in: "192.0.2.1",
			want: []string{"cscli", "decisions", "add", "--ip", "192.0.2.1", "--duration", "24h", "--reason", "meta crawler swarm"}},
		{name: "IPv6 address goes to --ip", in: "2001:db8::1",
			want: []string{"cscli", "decisions", "add", "--ip", "2001:db8::1", "--duration", "24h", "--reason", "meta crawler swarm"}},
		{name: "IPv4 CIDR goes to --range", in: "192.0.2.0/24",
			want: []string{"cscli", "decisions", "add", "--range", "192.0.2.0/24", "--duration", "24h", "--reason", "meta crawler swarm"}},
		{name: "the reported IPv6 CIDR goes to --range", in: "2a03:2880::/32",
			want: []string{"cscli", "decisions", "add", "--range", "2a03:2880::/32", "--duration", "24h", "--reason", "meta crawler swarm"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := cscliAddArgs(tc.in, 24*time.Hour, "meta crawler swarm")
			if err != nil {
				t.Fatalf("cscliAddArgs(%q) unexpected error: %v", tc.in, err)
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("cscliAddArgs(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestCscliDeleteArgs(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want []string
	}{
		{name: "IPv4 address goes to --ip", in: "192.0.2.1",
			want: []string{"cscli", "decisions", "delete", "--ip", "192.0.2.1"}},
		{name: "IPv6 address goes to --ip", in: "2001:db8::1",
			want: []string{"cscli", "decisions", "delete", "--ip", "2001:db8::1"}},
		{name: "IPv4 CIDR goes to --range", in: "192.0.2.0/24",
			want: []string{"cscli", "decisions", "delete", "--range", "192.0.2.0/24"}},
		{name: "the reported IPv6 CIDR goes to --range", in: "2a03:2880::/32",
			want: []string{"cscli", "decisions", "delete", "--range", "2a03:2880::/32"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := cscliDeleteArgs(tc.in)
			if err != nil {
				t.Fatalf("cscliDeleteArgs(%q) unexpected error: %v", tc.in, err)
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("cscliDeleteArgs(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// The guardrails exist because of the 2026-08-16 lockout; a fix for the address
// parsing must not loosen any of them.
func TestBanArgvGuardrailsSurvive(t *testing.T) {
	if _, err := cscliAddArgs("2a03:2880::/32", 169*time.Hour, "reason"); err == nil {
		t.Error("cscliAddArgs should refuse a duration beyond the 168h cap")
	}
	if _, err := cscliAddArgs("2a03:2880::/32", 8717*time.Hour, "reason"); err == nil {
		t.Error("cscliAddArgs should refuse the 363-day incident duration")
	}
	if _, err := cscliAddArgs("2a03:2880::/32", 0, "reason"); err == nil {
		t.Error("cscliAddArgs should refuse a non-positive duration")
	}
	if _, err := cscliAddArgs("2a03:2880::/32", 24*time.Hour, "  "); err == nil {
		t.Error("cscliAddArgs should refuse a blank reason")
	}
	if _, err := cscliAddArgs("meta.com", 24*time.Hour, "reason"); err == nil {
		t.Error("cscliAddArgs should refuse a hostname")
	}
	if _, err := cscliDeleteArgs("meta.com"); err == nil {
		t.Error("cscliDeleteArgs should refuse a hostname")
	}
}
