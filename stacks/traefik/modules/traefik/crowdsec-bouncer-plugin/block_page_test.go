package crowdsec_bouncer_plugin

import (
	"net/http"
	"strings"
	"testing"
)

const browserAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

func TestBanServesHTMLPageToBrowsers(t *testing.T) {
	var hit bool
	b := testBouncer(t, enforcing(), banned("1.2.3.4"), okNext(&hit))

	rec := do(b, "1.2.3.4:1234", "app.viktorbarzin.me", map[string]string{"Accept": browserAccept})

	if hit {
		t.Fatal("banned browser reached the backend")
	}
	if rec.Code != http.StatusForbidden {
		t.Errorf("want 403, got %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Errorf("want text/html, got %q", ct)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
		t.Errorf("want Cache-Control no-store, got %q", cc)
	}
	body := rec.Body.String()
	for _, want := range []string{"<!doctype html>", "Your address is blocked", "1.2.3.4", "app.viktorbarzin.me", "UTC"} {
		if !strings.Contains(body, want) {
			t.Errorf("page lacks %q", want)
		}
	}
	// The page is self-contained: any sub-request from a banned client would
	// itself be blocked, so nothing may load from elsewhere.
	for _, bad := range []string{"<script", "<link", "src=", "url("} {
		if strings.Contains(body, bad) {
			t.Errorf("page references an external resource via %q", bad)
		}
	}
}

func TestBanKeepsPlainTextForNonBrowsers(t *testing.T) {
	for _, accept := range []string{"", "application/json", "*/*"} {
		var hit bool
		b := testBouncer(t, enforcing(), banned("1.2.3.4"), okNext(&hit))

		rec := do(b, "1.2.3.4:1234", "app.viktorbarzin.me", map[string]string{"Accept": accept})

		if rec.Code != http.StatusForbidden {
			t.Errorf("accept %q: want 403, got %d", accept, rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
			t.Errorf("accept %q: want text/plain, got %q", accept, ct)
		}
		if rec.Body.String() != "Forbidden\n" {
			t.Errorf("accept %q: want Forbidden, got %q", accept, rec.Body.String())
		}
	}
}

func TestBlockPageEscapesTheHost(t *testing.T) {
	b := testBouncer(t, enforcing(), banned("1.2.3.4"), okNext(new(bool)))

	rec := do(b, "1.2.3.4:1234", `x"><b>evil</b>.example`, map[string]string{"Accept": browserAccept})

	body := rec.Body.String()
	if strings.Contains(body, "<b>evil</b>") {
		t.Error("host was written into the page unescaped")
	}
	if !strings.Contains(body, "&lt;b&gt;evil&lt;/b&gt;") {
		t.Error("escaped host missing from the page")
	}
}

func TestAppsecBlockServesRequestBlockedPage(t *testing.T) {
	f := newFakeAppsec(t, http.StatusForbidden)
	b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(new(bool)))

	rec := do(b, "203.0.113.9:4444", "app.viktorbarzin.me", map[string]string{"Accept": browserAccept})

	if rec.Code != http.StatusForbidden {
		t.Fatalf("want 403, got %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "This request was blocked") {
		t.Error("AppSec page lacks its heading")
	}
	if strings.Contains(body, "Your address is blocked") {
		t.Error("AppSec page claims the address is banned")
	}
	if !strings.Contains(body, "203.0.113.9") {
		t.Error("AppSec page lacks the client address")
	}
}
