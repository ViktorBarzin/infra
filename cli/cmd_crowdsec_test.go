package main

import (
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
