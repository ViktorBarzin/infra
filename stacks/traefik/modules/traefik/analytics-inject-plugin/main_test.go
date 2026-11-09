package analytics_inject_plugin

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

const wantTag = `<script src="/_t/r/script.js" data-site-id="7" defer></script>`

func newPlugin(t *testing.T, cfg *Config, next http.Handler) http.Handler {
	t.Helper()
	h, err := New(context.Background(), next, cfg, "test")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return h
}

func defaultCfg() *Config {
	c := CreateConfig()
	c.SiteID = "7"
	return c
}

// htmlNav is a request a browser sends when navigating to a page.
func htmlNav(method string) *http.Request {
	req := httptest.NewRequest(method, "http://app.example/", nil)
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
	req.Header.Set("Accept-Encoding", "gzip, deflate, br")
	return req
}

// backend answers with the given status, headers and body. A Content-Length
// header is set to the real body length unless the headers already carry one
// (use "-" to send no Content-Length at all).
func backend(status int, hdr map[string]string, body []byte) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for k, v := range hdr {
			if k == "Content-Length" && v == "-" {
				continue
			}
			w.Header().Set(k, v)
		}
		if _, ok := hdr["Content-Length"]; !ok {
			w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		}
		w.WriteHeader(status)
		_, _ = w.Write(body)
	})
}

func TestResponses(t *testing.T) {
	html := map[string]string{"Content-Type": "text/html; charset=utf-8"}
	gz := func(s string) []byte {
		var b bytes.Buffer
		zw := gzip.NewWriter(&b)
		_, _ = zw.Write([]byte(s))
		_ = zw.Close()
		return b.Bytes()
	}

	cases := []struct {
		name     string
		method   string
		status   int
		hdr      map[string]string
		body     []byte
		wantBody string // "" means: body must be returned byte-for-byte unchanged
	}{
		{
			name: "inject before </head>", method: "GET", status: 200, hdr: html,
			body:     []byte(`<!doctype html><html><head><title>x</title></head><body>hi</body></html>`),
			wantBody: `<!doctype html><html><head><title>x</title>` + wantTag + `</head><body>hi</body></html>`,
		},
		{
			name: "uppercase </HEAD>", method: "GET", status: 200, hdr: map[string]string{"Content-Type": "TEXT/HTML"},
			body:     []byte(`<HTML><HEAD><TITLE>x</TITLE></HEAD><BODY></BODY></HTML>`),
			wantBody: `<HTML><HEAD><TITLE>x</TITLE>` + wantTag + `</HEAD><BODY></BODY></HTML>`,
		},
		{
			name: "title-case <Head> wins over a later lowercase one", method: "GET", status: 200, hdr: html,
			body:     []byte(`<Head><Title>x</Title></Head><body><p>"</head>"</p></body>`),
			wantBody: `<Head><Title>x</Title>` + wantTag + `</Head><body><p>"</head>"</p></body>`,
		},
		{
			name: "no </head>: after the <head> open tag", method: "GET", status: 200, hdr: html,
			body:     []byte(`<html><head lang="en"><meta charset="utf-8"><body><header>h</header></body>`),
			wantBody: `<html><head lang="en">` + wantTag + `<meta charset="utf-8"><body><header>h</header></body>`,
		},
		{
			name: "no head at all: start of <body>", method: "GET", status: 200, hdr: html,
			body:     []byte(`<!doctype html><body class="a"><header>x</header></body>`),
			wantBody: `<!doctype html><body class="a">` + wantTag + `<header>x</header></body>`,
		},
		{
			name: "</header> is not </head>", method: "GET", status: 200, hdr: html,
			body:     []byte(`<html><head><title>t</title></head><body><header>a</header></body>`),
			wantBody: `<html><head><title>t</title>` + wantTag + `</head><body><header>a</header></body>`,
		},
		{
			name: "</header> with no </head> or <body>: after <head>", method: "GET", status: 200, hdr: html,
			body:     []byte(`<html><head><title>t</title><header>a</header>`),
			wantBody: `<html><head>` + wantTag + `<title>t</title><header>a</header>`,
		},
		{
			name: "fragment with no head or body: untouched", method: "GET", status: 200, hdr: html,
			body: []byte(`<div>partial</div>`),
		},
		{
			name: "already injected: untouched", method: "GET", status: 200, hdr: html,
			body: []byte(`<html><head><script src="/_t/r/script.js" data-site-id="other" defer></script></head></html>`),
		},
		{
			name: "gzip response: passthrough", method: "GET", status: 200,
			hdr:  map[string]string{"Content-Type": "text/html", "Content-Encoding": "gzip"},
			body: gz(`<html><head></head></html>`),
		},
		{
			name: "br response: passthrough", method: "GET", status: 200,
			hdr:  map[string]string{"Content-Type": "text/html", "Content-Encoding": "br"},
			body: []byte("\x0b\x02\x80<html><head></head></html>\x03"),
		},
		{
			name: "identity encoding still injects", method: "GET", status: 200,
			hdr:      map[string]string{"Content-Type": "text/html", "Content-Encoding": "identity"},
			body:     []byte(`<head></head>`),
			wantBody: `<head>` + wantTag + `</head>`,
		},
		{
			name: "non-HTML: untouched", method: "GET", status: 200,
			hdr:  map[string]string{"Content-Type": "application/json"},
			body: []byte(`{"html":"<head></head>"}`),
		},
		{
			name: "no Content-Type: untouched", method: "GET", status: 200,
			hdr:  map[string]string{},
			body: []byte(`<html><head></head></html>`),
		},
		{
			name: "non-200: untouched", method: "GET", status: 404, hdr: html,
			body: []byte(`<html><head></head><body>not found</body></html>`),
		},
		{
			name: "HEAD: untouched", method: "HEAD", status: 200, hdr: html,
			body: nil,
		},
		{
			name: "POST: untouched", method: "POST", status: 200, hdr: html,
			body: []byte(`<html><head></head></html>`),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newPlugin(t, defaultCfg(), backend(tc.status, tc.hdr, tc.body))
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, htmlNav(tc.method))

			if rec.Code != tc.status {
				t.Fatalf("status = %d, want %d", rec.Code, tc.status)
			}
			want := string(tc.body)
			if tc.wantBody != "" {
				want = tc.wantBody
			}
			if got := rec.Body.String(); got != want {
				t.Fatalf("body\n got: %q\nwant: %q", got, want)
			}
			if cl := rec.Header().Get("Content-Length"); cl != strconv.Itoa(len(want)) && tc.method != "HEAD" {
				t.Fatalf("Content-Length = %q, body is %d bytes", cl, len(want))
			}
			for k, v := range tc.hdr {
				if k == "Content-Length" {
					continue
				}
				if got := rec.Header().Get(k); got != v {
					t.Fatalf("header %s = %q, want %q", k, got, v)
				}
			}
		})
	}
}

func TestOtherHeadersKept(t *testing.T) {
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.Header().Set("X-App", "immich")
		w.Header().Add("Set-Cookie", "a=1")
		w.Header().Add("Set-Cookie", "b=2")
		w.Header().Set("Content-Security-Policy", "script-src 'self'")
		_, _ = io.WriteString(w, "<head></head>")
	})
	rec := httptest.NewRecorder()
	newPlugin(t, defaultCfg(), next).ServeHTTP(rec, htmlNav("GET"))

	if got := rec.Body.String(); got != "<head>"+wantTag+"</head>" {
		t.Fatalf("body = %q", got)
	}
	if rec.Header().Get("X-App") != "immich" ||
		strings.Join(rec.Header().Values("Set-Cookie"), ",") != "a=1,b=2" ||
		rec.Header().Get("Content-Security-Policy") != "script-src 'self'" {
		t.Fatalf("headers lost: %v", rec.Header())
	}
	if rec.Header().Get("Content-Length") != strconv.Itoa(rec.Body.Len()) {
		t.Fatalf("Content-Length = %q, body %d", rec.Header().Get("Content-Length"), rec.Body.Len())
	}
}

// Write without WriteHeader is an implicit 200 and must still be injected,
// including when the body arrives in several writes.
func TestImplicit200MultipleWrites(t *testing.T) {
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = io.WriteString(w, "<html><head><ti")
		_, _ = io.WriteString(w, "tle>x</title></he")
		_, _ = io.WriteString(w, "ad><body></body></html>")
	})
	rec := httptest.NewRecorder()
	newPlugin(t, defaultCfg(), next).ServeHTTP(rec, htmlNav("GET"))
	want := "<html><head><title>x</title>" + wantTag + "</head><body></body></html>"
	if rec.Code != 200 || rec.Body.String() != want {
		t.Fatalf("got %d %q", rec.Code, rec.Body.String())
	}
}

func TestOversize(t *testing.T) {
	page := "<html><head></head><body>" + strings.Repeat("x", 200) + "</body></html>"
	cfg := defaultCfg()
	cfg.MaxBodyBytes = 64

	t.Run("declared Content-Length over the limit", func(t *testing.T) {
		var sawBuffering bool
		next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/html")
			w.Header().Set("Content-Length", strconv.Itoa(len(page)))
			w.WriteHeader(200)
			// The headers must already be on the wire: no buffering at all.
			sawBuffering = !w.(interface{ committed() bool }).committed()
			_, _ = io.WriteString(w, page)
		})
		rec := httptest.NewRecorder()
		newPlugin(t, cfg, next).ServeHTTP(rec, htmlNav("GET"))
		if sawBuffering {
			t.Fatal("response with Content-Length over maxBodyBytes was buffered")
		}
		if rec.Body.String() != page || rec.Header().Get("Content-Length") != strconv.Itoa(len(page)) {
			t.Fatalf("got %q CL=%s", rec.Body.String(), rec.Header().Get("Content-Length"))
		}
	})

	t.Run("no Content-Length, body grows past the limit", func(t *testing.T) {
		next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/html")
			for i := 0; i < len(page); i += 10 {
				end := i + 10
				if end > len(page) {
					end = len(page)
				}
				_, _ = io.WriteString(w, page[i:end])
			}
		})
		rec := httptest.NewRecorder()
		newPlugin(t, cfg, next).ServeHTTP(rec, htmlNav("GET"))
		if rec.Body.String() != page {
			t.Fatalf("oversize body changed: %q", rec.Body.String())
		}
		if cl := rec.Header().Get("Content-Length"); cl != "" {
			t.Fatalf("Content-Length %q invented for a streamed body", cl)
		}
	})
}

// The request the backend sees: Accept-Encoding is removed only for requests
// that qualify, and those requests are the only ones whose writer is wrapped.
func TestRequestQualification(t *testing.T) {
	cases := []struct {
		name      string
		method    string
		hdr       map[string]string
		qualifies bool
	}{
		{"GET Accept text/html", "GET", map[string]string{"Accept": "text/html"}, true},
		{"GET Sec-Fetch-Dest document", "GET", map[string]string{"Accept": "*/*", "Sec-Fetch-Dest": "document"}, true},
		{"GET Accept json", "GET", map[string]string{"Accept": "application/json"}, false},
		{"GET Accept */* only", "GET", map[string]string{"Accept": "*/*"}, false},
		{"SSE", "GET", map[string]string{"Accept": "text/event-stream"}, false},
		{"HEAD", "HEAD", map[string]string{"Accept": "text/html"}, false},
		{"POST form", "POST", map[string]string{"Accept": "text/html"}, false},
		{"range request", "GET", map[string]string{"Accept": "text/html", "Range": "bytes=0-99"}, false},
		{"websocket upgrade", "GET", map[string]string{
			"Accept": "text/html", "Connection": "keep-alive, Upgrade", "Upgrade": "websocket",
		}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(tc.method, "http://app.example/", nil)
			req.Header.Set("Accept-Encoding", "gzip, br")
			for k, v := range tc.hdr {
				req.Header.Set(k, v)
			}
			rec := httptest.NewRecorder()
			var gotAE string
			var wrapped bool
			next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				gotAE = r.Header.Get("Accept-Encoding")
				wrapped = w != http.ResponseWriter(rec)
				w.WriteHeader(204)
			})
			newPlugin(t, defaultCfg(), next).ServeHTTP(rec, req)

			if tc.qualifies {
				if gotAE != "" || !wrapped {
					t.Fatalf("qualifying request: Accept-Encoding=%q wrapped=%v; want stripped and wrapped", gotAE, wrapped)
				}
			} else if gotAE != "gzip, br" || wrapped {
				t.Fatalf("non-qualifying request: Accept-Encoding=%q wrapped=%v; want untouched and unwrapped", gotAE, wrapped)
			}
		})
	}
}

func TestStatusesStreamThrough(t *testing.T) {
	for _, code := range []int{http.StatusNotModified, http.StatusPartialContent, http.StatusFound, http.StatusInternalServerError} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			var committedEarly bool
			next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/html")
				w.WriteHeader(code)
				committedEarly = w.(interface{ committed() bool }).committed()
			})
			rec := httptest.NewRecorder()
			newPlugin(t, defaultCfg(), next).ServeHTTP(rec, htmlNav("GET"))
			if rec.Code != code || !committedEarly || rec.Body.Len() != 0 {
				t.Fatalf("code=%d committedEarly=%v body=%q", rec.Code, committedEarly, rec.Body.String())
			}
		})
	}
}

// Flush on the wrapper must reach the client: in passthrough mode it flushes
// the underlying writer; while buffering HTML it injects into what it has (if
// an insertion point is there), sends it, and streams the rest.
func TestFlush(t *testing.T) {
	t.Run("passthrough response flushes underlying writer", func(t *testing.T) {
		rec := httptest.NewRecorder()
		next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, "{")
			w.(http.Flusher).Flush()
			if !rec.Flushed || rec.Body.String() != "{" {
				t.Errorf("flush did not reach the client: flushed=%v body=%q", rec.Flushed, rec.Body.String())
			}
			_, _ = io.WriteString(w, "}")
		})
		newPlugin(t, defaultCfg(), next).ServeHTTP(rec, htmlNav("GET"))
		if rec.Body.String() != "{}" {
			t.Fatalf("body = %q", rec.Body.String())
		}
	})

	t.Run("streamed HTML: inject at the first flush, then stream", func(t *testing.T) {
		rec := httptest.NewRecorder()
		head := "<html><head><title>x</title></head>"
		tail := "<body>streamed</body></html>"
		next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/html")
			w.Header().Set("Content-Length", strconv.Itoa(len(head)+len(tail)))
			_, _ = io.WriteString(w, head)
			w.(http.Flusher).Flush()
			if !rec.Flushed || !strings.Contains(rec.Body.String(), wantTag) {
				t.Errorf("first flush did not send the injected head: %q", rec.Body.String())
			}
			_, _ = io.WriteString(w, tail)
			if !strings.HasSuffix(rec.Body.String(), tail) {
				t.Errorf("write after flush was buffered: %q", rec.Body.String())
			}
		})
		newPlugin(t, defaultCfg(), next).ServeHTTP(rec, htmlNav("GET"))
		want := "<html><head><title>x</title>" + wantTag + "</head>" + tail
		if rec.Body.String() != want {
			t.Fatalf("body = %q", rec.Body.String())
		}
		if rec.Header().Get("Content-Length") != strconv.Itoa(len(want)) {
			t.Fatalf("Content-Length = %q, want %d", rec.Header().Get("Content-Length"), len(want))
		}
	})

	t.Run("flush before any insertion point: give up and stream", func(t *testing.T) {
		rec := httptest.NewRecorder()
		next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/html")
			_, _ = io.WriteString(w, "<!doctype html>")
			w.(http.Flusher).Flush()
			_, _ = io.WriteString(w, "<html><head></head></html>")
		})
		newPlugin(t, defaultCfg(), next).ServeHTTP(rec, htmlNav("GET"))
		if rec.Body.String() != "<!doctype html><html><head></head></html>" {
			t.Fatalf("body = %q", rec.Body.String())
		}
	})
}

// A wrapped writer must still hand the connection over when the backend
// hijacks it, over a real server connection.
func TestHijackPassthrough(t *testing.T) {
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hj, ok := w.(http.Hijacker)
		if !ok {
			t.Error("wrapped writer does not implement http.Hijacker")
			return
		}
		conn, brw, err := hj.Hijack()
		if err != nil {
			t.Errorf("Hijack: %v", err)
			return
		}
		defer conn.Close()
		_, _ = brw.WriteString("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 8\r\nConnection: close\r\n\r\nhijacked")
		_ = brw.Flush()
	})
	srv := httptest.NewServer(newPlugin(t, defaultCfg(), next))
	defer srv.Close()

	conn, err := net.Dial("tcp", srv.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_, _ = io.WriteString(conn, "GET / HTTP/1.1\r\nHost: x\r\nAccept: text/html\r\n\r\n")
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	if string(b) != "hijacked" {
		t.Fatalf("body = %q", b)
	}
}

func TestConfig(t *testing.T) {
	t.Run("defaults", func(t *testing.T) {
		c := CreateConfig()
		if c.ScriptSrc != "/_t/r/script.js" || c.MaxBodyBytes != 5<<20 {
			t.Fatalf("defaults = %+v", c)
		}
	})

	t.Run("extra attributes are sorted and escaped", func(t *testing.T) {
		c := defaultCfg()
		c.ScriptSrc = "/_t/r/script.js?v=1&x=2"
		c.ExtraAttributes = map[string]string{"data-track-errors": "true", "data-api-host": `"/x"`, "data-debounce": ""}
		next := backend(200, map[string]string{"Content-Type": "text/html"}, []byte("<head></head>"))
		rec := httptest.NewRecorder()
		newPlugin(t, c, next).ServeHTTP(rec, htmlNav("GET"))
		want := `<head><script src="/_t/r/script.js?v=1&amp;x=2" data-site-id="7" data-api-host="&#34;/x&#34;" data-debounce data-track-errors="true" defer></script></head>`
		if rec.Body.String() != want {
			t.Fatalf("\n got: %s\nwant: %s", rec.Body.String(), want)
		}
	})

	t.Run("already-injected check uses the configured src", func(t *testing.T) {
		c := defaultCfg()
		c.ScriptSrc = "/analytics.js"
		body := `<head><script src="/analytics.js"></script></head>`
		rec := httptest.NewRecorder()
		newPlugin(t, c, backend(200, map[string]string{"Content-Type": "text/html"}, []byte(body))).ServeHTTP(rec, htmlNav("GET"))
		if rec.Body.String() != body {
			t.Fatalf("body = %q", rec.Body.String())
		}
	})

	t.Run("empty scriptSrc and zero maxBodyBytes fall back to the defaults", func(t *testing.T) {
		c := defaultCfg()
		c.ScriptSrc = ""
		c.MaxBodyBytes = 0
		rec := httptest.NewRecorder()
		newPlugin(t, c, backend(200, map[string]string{"Content-Type": "text/html"}, []byte("<head></head>"))).ServeHTTP(rec, htmlNav("GET"))
		if !strings.Contains(rec.Body.String(), wantTag) {
			t.Fatalf("body = %q", rec.Body.String())
		}
	})

	bad := []struct {
		name string
		mod  func(*Config)
	}{
		{"missing siteId", func(c *Config) { c.SiteID = "" }},
		{"blank siteId", func(c *Config) { c.SiteID = "  " }},
		{"attribute name with a space", func(c *Config) { c.ExtraAttributes = map[string]string{"data x": "1"} }},
		{"attribute name with a quote", func(c *Config) { c.ExtraAttributes = map[string]string{`a"b`: "1"} }},
		{"attribute overriding src", func(c *Config) { c.ExtraAttributes = map[string]string{"SRC": "/evil.js"} }},
		{"attribute overriding data-site-id", func(c *Config) { c.ExtraAttributes = map[string]string{"data-site-id": "2"} }},
	}
	for _, tc := range bad {
		t.Run("rejects "+tc.name, func(t *testing.T) {
			c := defaultCfg()
			tc.mod(c)
			if _, err := New(context.Background(), http.NotFoundHandler(), c, "test"); err == nil {
				t.Fatal("New accepted an invalid config")
			}
		})
	}
}
