package analytics_inject_plugin

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

const page = `<html><head><title>t</title></head><body></body></html>`

var injectedPage = strings.Replace(page, "</head>", wantTag+"</head>", 1)

// observed is what the backend saw and what the client got.
type observed struct {
	wrapped        bool
	acceptEncoding string
	rec            *httptest.ResponseRecorder
}

// run sends an HTML navigation for host through a plugin built from cfg, with
// a backend answering 200 text/html with body and the extra response headers.
func run(t *testing.T, cfg *Config, host string, respHdr map[string]string, body string) observed {
	t.Helper()
	var o observed
	o.rec = httptest.NewRecorder()
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		o.wrapped = w != http.ResponseWriter(o.rec)
		o.acceptEncoding = r.Header.Get("Accept-Encoding")
		w.Header().Set("Content-Type", "text/html")
		for k, v := range respHdr {
			w.Header().Set(k, v)
		}
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		_, _ = io.WriteString(w, body)
	})
	req := htmlNav("GET")
	req.Host = host
	newPlugin(t, cfg, next).ServeHTTP(o.rec, req)
	return o
}

func (o observed) injected() bool { return strings.Contains(o.rec.Body.String(), wantTag) }

// untouched asserts the request was handed on as it came: writer not
// wrapped, Accept-Encoding kept, body unchanged.
func (o observed) assertUntouched(t *testing.T, body string) {
	t.Helper()
	if o.wrapped || o.acceptEncoding != "gzip, deflate, br" || o.rec.Body.String() != body {
		t.Fatalf("want untouched: wrapped=%v Accept-Encoding=%q body=%q", o.wrapped, o.acceptEncoding, o.rec.Body.String())
	}
}

func TestHostPatterns(t *testing.T) {
	cases := []struct {
		pattern, host string
		match         bool
	}{
		{"vault.viktorbarzin.me", "vault.viktorbarzin.me", true},
		{"vault.viktorbarzin.me", "VAULT.ViktorBarzin.ME", true},
		{"Vault.ViktorBarzin.me", "vault.viktorbarzin.me", true},
		{"vault.viktorbarzin.me", "vault.viktorbarzin.me:443", true},
		{"vault.viktorbarzin.me", "vault.viktorbarzin.me.", true},
		{"vault.viktorbarzin.me", "xvault.viktorbarzin.me", false},
		{"vault.viktorbarzin.me", "vault.viktorbarzin.me.evil.example", false},
		{"*.authentik.viktorbarzin.me", "outpost.authentik.viktorbarzin.me", true},
		{"*.authentik.viktorbarzin.me", "a.b.authentik.viktorbarzin.me:8443", true},
		{"*.authentik.viktorbarzin.me", "authentik.viktorbarzin.me", false},
		{"*.authentik.viktorbarzin.me", "evilauthentik.viktorbarzin.me", false},
		{"10.0.20.5", "10.0.20.5:8080", true},
	}
	for in, want := range map[string]string{"[::1]:443": "::1", "[2001:db8::1]": "2001:db8::1", "A.Example.:80": "a.example", "": ""} {
		if got := normalizeHost(in); got != want {
			t.Errorf("normalizeHost(%q) = %q, want %q", in, got, want)
		}
	}
	for _, tc := range cases {
		t.Run(tc.pattern+" vs "+tc.host, func(t *testing.T) {
			m, err := newHostMatcher([]string{tc.pattern})
			if err != nil {
				t.Fatal(err)
			}
			if got := m.match(normalizeHost(tc.host)); got != tc.match {
				t.Fatalf("match = %v, want %v", got, tc.match)
			}
		})
	}

	for _, bad := range []string{"", "  ", "*", "*.", "foo.*", "a*.example", "*example.com", "vault example", "https://vault.example", "vault.example/x"} {
		t.Run("rejects "+strconv.Quote(bad), func(t *testing.T) {
			c := defaultCfg()
			c.ExcludeHosts = []string{bad}
			if _, err := New(context.Background(), http.NotFoundHandler(), c, "t"); err == nil {
				t.Fatal("excludeHosts accepted an invalid pattern")
			}
			c = defaultCfg()
			c.IncludeHosts = []string{bad}
			if _, err := New(context.Background(), http.NotFoundHandler(), c, "t"); err == nil {
				t.Fatal("includeHosts accepted an invalid pattern")
			}
		})
	}
}

func TestHostFilters(t *testing.T) {
	exclude := []string{"vault.viktorbarzin.me", "*.authentik.viktorbarzin.me"}
	cases := []struct {
		name     string
		include  []string
		exclude  []string
		host     string
		eligible bool
	}{
		{"no lists: every host", nil, nil, "immich.viktorbarzin.me", true},
		{"excluded exact host", nil, exclude, "vault.viktorbarzin.me", false},
		{"excluded host with port and caps", nil, exclude, "Vault.Viktorbarzin.me:443", false},
		{"excluded wildcard", nil, exclude, "outpost.authentik.viktorbarzin.me", false},
		{"not excluded", nil, exclude, "immich.viktorbarzin.me", true},
		{"include list: listed host", []string{"immich.viktorbarzin.me"}, nil, "immich.viktorbarzin.me", true},
		{"include list: unlisted host", []string{"immich.viktorbarzin.me"}, nil, "forgejo.viktorbarzin.me", false},
		{"include wildcard", []string{"*.viktorbarzin.me"}, nil, "forgejo.viktorbarzin.me", true},
		{"exclude wins over include", []string{"*.viktorbarzin.me"}, exclude, "vault.viktorbarzin.me", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := defaultCfg()
			c.IncludeHosts = tc.include
			c.ExcludeHosts = tc.exclude
			o := run(t, c, tc.host, nil, page)
			if tc.eligible {
				if !o.wrapped || o.acceptEncoding != "" || o.rec.Body.String() != injectedPage {
					t.Fatalf("want injected: wrapped=%v Accept-Encoding=%q body=%q", o.wrapped, o.acceptEncoding, o.rec.Body.String())
				}
				return
			}
			o.assertUntouched(t, page)
		})
	}
}

func TestSDKOptOutHeader(t *testing.T) {
	for _, v := range []string{"sdk", "SDK", " Sdk "} {
		t.Run("X-Analytics: "+strconv.Quote(v), func(t *testing.T) {
			o := run(t, defaultCfg(), "app.example", map[string]string{"X-Analytics": v, "X-Other": "kept"}, page)
			if o.injected() || o.rec.Body.String() != page {
				t.Fatalf("injected despite X-Analytics: sdk: %q", o.rec.Body.String())
			}
			if _, ok := o.rec.Header()["X-Analytics"]; ok {
				t.Fatal("X-Analytics reached the client")
			}
			if o.rec.Header().Get("X-Other") != "kept" || o.rec.Header().Get("Content-Length") != strconv.Itoa(len(page)) {
				t.Fatalf("headers changed: %v", o.rec.Header())
			}
		})
	}

	t.Run("other X-Analytics value: injects, header still stripped", func(t *testing.T) {
		o := run(t, defaultCfg(), "app.example", map[string]string{"X-Analytics": "on"}, page)
		if o.rec.Body.String() != injectedPage {
			t.Fatalf("body = %q", o.rec.Body.String())
		}
		if _, ok := o.rec.Header()["X-Analytics"]; ok {
			t.Fatal("X-Analytics reached the client")
		}
	})

	t.Run("stripped on a passthrough response too", func(t *testing.T) {
		rec := httptest.NewRecorder()
		next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/html")
			w.Header().Set("X-Analytics", "sdk")
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, "nope")
		})
		newPlugin(t, defaultCfg(), next).ServeHTTP(rec, htmlNav("GET"))
		if _, ok := rec.Header()["X-Analytics"]; ok || rec.Code != 404 || rec.Body.String() != "nope" {
			t.Fatalf("code=%d header=%v body=%q", rec.Code, rec.Header(), rec.Body.String())
		}
	})

	t.Run("stripped when the backend writes nothing", func(t *testing.T) {
		rec := httptest.NewRecorder()
		next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("X-Analytics", "sdk")
		})
		newPlugin(t, defaultCfg(), next).ServeHTTP(rec, htmlNav("GET"))
		if _, ok := rec.Header()["X-Analytics"]; ok {
			t.Fatal("X-Analytics reached the client")
		}
	})
}

func TestSDKOptOutMeta(t *testing.T) {
	cases := []struct {
		name   string
		meta   string
		optOut bool
	}{
		{"double quotes", `<meta name="analytics" content="sdk">`, true},
		{"reversed order, single quotes, self-closing", `<meta content='sdk' name='analytics'/>`, true},
		{"upper-case tag and value", `<META name="analytics" CONTENT="SDK">`, true},
		{"unquoted", `<meta name=analytics content=sdk>`, true},
		{"extra attributes and newlines", "<meta\n  data-x=\"1\"\n  name=\"analytics\"\n  content=\"sdk\" >", true},
		{"other content value", `<meta name="analytics" content="off">`, false},
		{"other meta name", `<meta name="description" content="sdk">`, false},
		{"words in text", `<meta name="description" content="analytics sdk">`, false},
		{"not a meta tag", `<link name="analytics" content="sdk">`, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := `<html><head>` + tc.meta + `<title>t</title></head><body></body></html>`
			o := run(t, defaultCfg(), "app.example", nil, body)
			if tc.optOut {
				if o.rec.Body.String() != body {
					t.Fatalf("injected despite the opt-out meta: %q", o.rec.Body.String())
				}
				return
			}
			if !o.injected() {
				t.Fatalf("did not inject: %q", o.rec.Body.String())
			}
		})
	}
}
