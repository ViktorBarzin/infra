package main

import (
	"strings"
	"testing"
	"time"
)

func TestNextcloudCredCandidatesPrefersPerUserPath(t *testing.T) {
	got := nextcloudCredCandidates("emo")
	if len(got) == 0 || got[0] != "secret/emo/nextcloud" {
		t.Fatalf("want the caller's own tree first, got %v", got)
	}
	// wizard additionally falls back to the pre-existing admin credential the
	// visualize skill already uses, so the verb works without a second setup.
	w := nextcloudCredCandidates("wizard")
	if len(w) < 2 || w[1] != "secret/nextcloud/caldav" {
		t.Errorf("want the wizard fallback, got %v", w)
	}
	// A non-wizard user must NOT be pointed at the admin credential.
	for _, p := range got {
		if p == "secret/nextcloud/caldav" {
			t.Errorf("non-wizard user must not fall back to the admin credential: %v", got)
		}
	}
}

func TestRemoteSharePathIsNamespacedAndStamped(t *testing.T) {
	got := remoteSharePath("app.log", "20260815-171500")
	if !strings.HasPrefix(got, "/_share/") {
		t.Errorf("want uploads namespaced under /_share/, got %q", got)
	}
	if !strings.Contains(got, "20260815-171500") || !strings.HasSuffix(got, "app.log") {
		t.Errorf("want a timestamp prefix and the original name, got %q", got)
	}
}

func TestRemoteSharePathSanitisesTraversal(t *testing.T) {
	// The remote name is derived from a local path; a caller passing
	// ../../etc/passwd must not be able to steer the upload out of /_share/.
	for _, in := range []string{"../../etc/passwd", "/etc/passwd", "a/b/c.txt"} {
		got := remoteSharePath(in, "s")
		if strings.Contains(got, "..") {
			t.Errorf("remoteSharePath(%q) = %q, leaks traversal", in, got)
		}
		if strings.Count(got, "/") != 2 { // /_share/<name>
			t.Errorf("remoteSharePath(%q) = %q, want a flat name under /_share/", in, got)
		}
	}
}

func TestParseOCSShareSuccess(t *testing.T) {
	body := `{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},
	          "data":{"id":"238","url":"https://nextcloud.viktorbarzin.me/s/aRsJ94rbxQcn9QZ","expiration":"2026-09-14 00:00:00"}}}`
	url, exp, err := parseOCSShare(body)
	if err != nil {
		t.Fatalf("parseOCSShare: %v", err)
	}
	if url != "https://nextcloud.viktorbarzin.me/s/aRsJ94rbxQcn9QZ" {
		t.Errorf("unexpected url %q", url)
	}
	if exp != "2026-09-14 00:00:00" {
		t.Errorf("unexpected expiration %q", exp)
	}
}

func TestParseOCSShareFailureSurfacesMessage(t *testing.T) {
	body := `{"ocs":{"meta":{"status":"failure","statuscode":403,"message":"Public upload disabled"}}}`
	if _, _, err := parseOCSShare(body); err == nil {
		t.Fatal("want an error on an OCS failure")
	} else if !strings.Contains(err.Error(), "Public upload disabled") {
		t.Errorf("want the server's message surfaced, got: %v", err)
	}
}

func TestParseOCSShareRejectsGarbage(t *testing.T) {
	if _, _, err := parseOCSShare("<html>login</html>"); err == nil {
		t.Error("non-JSON (e.g. an auth redirect page) must be an error, not an empty URL")
	}
}

func TestOCSExpireDate(t *testing.T) {
	now := time.Date(2026, 8, 15, 17, 0, 0, 0, time.UTC)
	if got := ocsExpireDate(now, 30); got != "2026-09-14" {
		t.Errorf("ocsExpireDate(+30d) = %q, want 2026-09-14", got)
	}
	if got := ocsExpireDate(now, 1); got != "2026-08-16" {
		t.Errorf("ocsExpireDate(+1d) = %q, want 2026-08-16", got)
	}
}

func TestParseShareArgs(t *testing.T) {
	for _, tc := range []struct {
		args  []string
		path  string
		days  int
		force bool
	}{
		{[]string{"a.log"}, "a.log", 30, false},
		{[]string{"a.log", "--expire", "7"}, "a.log", 7, false},
		{[]string{"--force", "a.log"}, "a.log", 30, true},
		{[]string{"a.log", "--expire", "0"}, "a.log", 0, false},
	} {
		got, err := parseShareArgs(tc.args)
		if err != nil {
			t.Fatalf("parseShareArgs(%v): %v", tc.args, err)
		}
		if got.path != tc.path || got.expireDays != tc.days || got.force != tc.force {
			t.Errorf("parseShareArgs(%v) = %+v, want path=%s days=%d force=%v", tc.args, got, tc.path, tc.days, tc.force)
		}
	}
	if _, err := parseShareArgs(nil); err == nil {
		t.Error("want a usage error with no file argument")
	}
}
