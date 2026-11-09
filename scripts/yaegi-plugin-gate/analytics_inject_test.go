package main

// Runs analytics-inject-plugin under Yaegi, loaded the way Traefik loads a
// local plugin, and checks the behaviour that only shows up there: what
// compiled code can still see on the wrapped writer, and the cost of
// interpreted code on a 5 MiB body. The plugin's own unit tests run compiled
// and cannot see either.

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/traefik/yaegi/interp"
	"github.com/traefik/yaegi/stdlib"
)

const (
	analyticsDir    = "../../stacks/traefik/modules/traefik/analytics-inject-plugin"
	analyticsImport = "github.com/viktorbarzin/analytics-inject-plugin"
	analyticsTag    = `<script src="/_t/r/script.js" data-site-id="7" defer></script>`
)

// loadAnalytics returns a constructor for the interpreted middleware.
func loadAnalytics(t *testing.T) func(next http.Handler) http.Handler {
	t.Helper()
	goPath, err := stageGoPath(analyticsDir, analyticsImport)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(goPath) })

	i := interp.New(interp.Options{GoPath: goPath, Env: os.Environ()})
	if err := i.Use(stdlib.Symbols); err != nil {
		t.Fatal(err)
	}
	if _, err := i.Eval(`import "` + analyticsImport + `"`); err != nil {
		t.Fatalf("import under yaegi: %v", err)
	}
	vCreate, err := i.Eval("analytics_inject_plugin.CreateConfig")
	if err != nil {
		t.Fatal(err)
	}
	vNew, err := i.Eval("analytics_inject_plugin.New")
	if err != nil {
		t.Fatal(err)
	}

	return func(next http.Handler) http.Handler {
		cfg := vCreate.Call(nil)[0]
		if err := json.Unmarshal([]byte(`{"siteId":"7"}`), cfg.Interface()); err != nil {
			t.Fatal(err)
		}
		out := vNew.Call([]reflect.Value{
			reflect.ValueOf(context.Background()), reflect.ValueOf(next), cfg, reflect.ValueOf("yaegi"),
		})
		if e := out[1].Interface(); e != nil {
			t.Fatalf("New: %v", e)
		}
		return out[0].Interface().(http.Handler)
	}
}

func navRequest() *http.Request {
	req := httptest.NewRequest(http.MethodGet, "http://app.example/", nil)
	req.Header.Set("Accept", "text/html,*/*;q=0.8")
	req.Header.Set("Accept-Encoding", "gzip, br")
	return req
}

func htmlBackend(hdr map[string]string, body []byte) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for k, v := range hdr {
			w.Header().Set(k, v)
		}
		_, _ = w.Write(body)
	})
}

func TestAnalyticsUnderYaegi(t *testing.T) {
	newMW := loadAnalytics(t)

	t.Run("injects before </head> and fixes Content-Length", func(t *testing.T) {
		page := `<!doctype html><html><head><title>t</title></head><body></body></html>`
		rec := httptest.NewRecorder()
		newMW(htmlBackend(map[string]string{"Content-Type": "text/html"}, []byte(page))).ServeHTTP(rec, navRequest())
		want := strings.Replace(page, "</head>", analyticsTag+"</head>", 1)
		if rec.Body.String() != want {
			t.Fatalf("body = %q", rec.Body.String())
		}
		if got := rec.Header().Get("Content-Length"); got != strconv.Itoa(len(want)) {
			t.Fatalf("Content-Length = %q, body %d", got, len(want))
		}
	})

	t.Run("gzip response passes through byte for byte", func(t *testing.T) {
		var gz bytes.Buffer
		zw := gzip.NewWriter(&gz)
		_, _ = zw.Write([]byte("<html><head></head></html>"))
		_ = zw.Close()
		rec := httptest.NewRecorder()
		newMW(htmlBackend(map[string]string{"Content-Type": "text/html", "Content-Encoding": "gzip"}, gz.Bytes())).
			ServeHTTP(rec, navRequest())
		if !bytes.Equal(rec.Body.Bytes(), gz.Bytes()) || rec.Header().Get("Content-Encoding") != "gzip" {
			t.Fatal("gzip body or header changed")
		}
	})

	t.Run("wrapped writer keeps Hijacker for websockets", func(t *testing.T) {
		var hijacker, flusher bool
		next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, hijacker = w.(http.Hijacker)
			_, flusher = w.(http.Flusher)
			w.WriteHeader(204)
		})
		newMW(next).ServeHTTP(hijackableRecorder{httptest.NewRecorder()}, navRequest())
		if !hijacker {
			t.Fatal("compiled code cannot see Hijack on the writer the plugin passes on")
		}
		// Yaegi v0.16.1 has a composed wrapper for ResponseWriter+Hijacker
		// only, so compiled code cannot see Flush on a wrapped writer. That
		// limits only HTML navigations (the requests that get wrapped); log it
		// so a yaegi bump that adds Flusher is noticed.
		t.Logf("compiled code sees Flusher on the wrapped writer: %v", flusher)
	})

	t.Run("non-qualifying request gets the original writer", func(t *testing.T) {
		orig := hijackableRecorder{httptest.NewRecorder()}
		var same bool
		var ae string
		next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, same = w.(hijackableRecorder)
			ae = r.Header.Get("Accept-Encoding")
		})
		req := navRequest()
		req.Header.Set("Accept", "text/event-stream")
		newMW(next).ServeHTTP(orig, req)
		if !same || ae != "gzip, br" {
			t.Fatalf("SSE request was wrapped=%v or had Accept-Encoding changed to %q", !same, ae)
		}
	})

	// The tag search must stay in native stdlib calls. An interpreted
	// byte-by-byte scan took 12.6 s on a fragment like the one below, and an
	// interpreted loop over "<header" false hits took 1.1 s on it.
	for _, tc := range []struct {
		name string
		body []byte
	}{
		{"5 MiB page", []byte("<html><head></head><body>" + strings.Repeat("<p>a</p>", 640000) + "</body></html>")},
		{"5 MiB fragment, no head or body", []byte(strings.Repeat("<p><header>a</header></p>", 200000))},
	} {
		t.Run("cost: "+tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			h := newMW(htmlBackend(map[string]string{"Content-Type": "text/html"}, tc.body))
			start := time.Now()
			h.ServeHTTP(rec, navRequest())
			took := time.Since(start)
			t.Logf("%d bytes in %v", len(tc.body), took)
			if took > time.Second {
				t.Fatalf("took %v under yaegi, budget 1s", took)
			}
		})
	}
}
