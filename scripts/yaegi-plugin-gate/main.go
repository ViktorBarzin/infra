// Command yaegi-plugin-gate loads a vendored Traefik middleware plugin under the
// same Yaegi interpreter version Traefik embeds, and serves one request through
// it. See README.md for why `go build` + `go test` are not enough.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/traefik/yaegi/interp"
	"github.com/traefik/yaegi/stdlib"
)

func main() {
	dir := flag.String("dir", "", "plugin source directory (the one Terraform vendors)")
	importPath := flag.String("import", "", "plugin import path, as in .traefik.yml")
	basePkg := flag.String("basePkg", "", "override the package name (default: last import element, - => _)")
	cfgJSON := flag.String("config", "", "JSON overlaid onto CreateConfig(), as a Middleware CRD's plugin block is")
	host := flag.String("host", "gate.example.invalid", "Host header for the probe request")
	remote := flag.String("remote", "203.0.113.7:34567", "RemoteAddr for the probe request")
	accept := flag.String("accept", "", "Accept header for the probe request")
	backendType := flag.String("backend-type", "", "Content-Type the probe backend answers with")
	backendBody := flag.String("backend-body", "", "body the probe backend answers with")
	wantBody := flag.String("want-body", "", "fail unless the response body contains this")
	wantHijacker := flag.Bool("want-hijacker", false, "fail unless the writer the backend gets implements http.Hijacker")
	flag.Parse()

	if *dir == "" || *importPath == "" {
		fmt.Fprintln(os.Stderr, "usage: yaegi-plugin-gate -dir <plugin dir> -import <import path> [-config JSON]")
		os.Exit(2)
	}

	pkg := *basePkg
	if pkg == "" {
		// Traefik's own derivation for a plugin's base package name.
		pkg = strings.ReplaceAll(path.Base(*importPath), "-", "_")
	}

	p := probe{
		host: *host, remote: *remote, accept: *accept,
		backendType: *backendType, backendBody: *backendBody,
		wantBody: *wantBody, wantHijacker: *wantHijacker,
	}
	if err := run(*dir, *importPath, pkg, *cfgJSON, p); err != nil {
		fmt.Printf("FAIL  %v\n", err)
		// The failure classes have very different blast radii, so say which.
		switch {
		case errors.Is(err, errLoad):
			fmt.Println("\nYaegi could not load this plugin, which disables ALL Traefik plugins at")
			fmt.Println("startup (api-token-middleware included). Do not apply.")
		case errors.Is(err, errProbe):
			fmt.Println("\nThe plugin loads and serves under Yaegi, but its behaviour on the probe")
			fmt.Println("request did not match -want-body / -want-hijacker.")
		default:
			fmt.Println("\nThe plugin itself loads under Yaegi; this config was rejected. In production")
			fmt.Println("that is a per-middleware error, not a fleet-wide plugin outage. Fix -config,")
			fmt.Println("or the Middleware CRD if the same values are what you intend to ship.")
		}
		os.Exit(1)
	}
	fmt.Printf("\nPASS  %s loads and serves under yaegi (the interpreter Traefik embeds)\n", *importPath)
}

// errLoad marks the failures that would take every Traefik plugin down with
// them: staging, interpreting, importing, or resolving the plugin's entrypoints.
// Anything after that is this plugin's own config or behaviour.
var errLoad = errors.New("plugin failed to load under yaegi")

// errProbe marks a -want-body or -want-hijacker expectation that did not hold.
var errProbe = errors.New("probe expectation failed")

// hijackableRecorder stands in for Traefik's real writer, which can hijack.
// The probe can then tell whether the writer the backend receives still can:
// a plugin that wraps the writer keeps only what Yaegi's wrapper exposes.
type hijackableRecorder struct {
	*httptest.ResponseRecorder
}

func (hijackableRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return nil, nil, errors.New("yaegi-plugin-gate: probe connection cannot be hijacked")
}

// probe describes the one request the gate sends through the plugin, the
// backend's answer, and what must hold afterwards.
type probe struct {
	host, remote, accept     string
	backendType, backendBody string
	wantBody                 string
	wantHijacker             bool
}

func run(dir, importPath, basePkg, cfgJSON string, p probe) (err error) {
	// A Yaegi rejection can be a panic rather than an error, and a panic here is
	// a PASS/FAIL signal, not a crash.
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("%w: yaegi panicked: %v", errLoad, r)
		}
	}()

	goPath, err := stageGoPath(dir, importPath)
	if err != nil {
		return fmt.Errorf("%w: %v", errLoad, err)
	}
	defer os.RemoveAll(goPath)

	i := interp.New(interp.Options{GoPath: goPath, Env: os.Environ()})
	if err := i.Use(stdlib.Symbols); err != nil {
		return fmt.Errorf("%w: Use(stdlib.Symbols): %v", errLoad, err)
	}
	if _, err := i.Eval(`import "` + importPath + `"`); err != nil {
		return fmt.Errorf("%w: import: %v", errLoad, err)
	}
	fmt.Println("ok    interpreted and imported")

	vCreate, err := i.Eval(basePkg + `.CreateConfig`)
	if err != nil {
		return fmt.Errorf("%w: eval %s.CreateConfig (wrong -basePkg?): %v", errLoad, basePkg, err)
	}
	vNew, err := i.Eval(basePkg + `.New`)
	if err != nil {
		return fmt.Errorf("%w: eval %s.New: %v", errLoad, basePkg, err)
	}

	cfg := vCreate.Call(nil)[0]
	fmt.Println("ok    CreateConfig() ->", cfg.Type())

	if cfgJSON != "" {
		if err := json.Unmarshal([]byte(cfgJSON), cfg.Interface()); err != nil {
			return fmt.Errorf("overlay -config onto the plugin Config: %w", err)
		}
		fmt.Println("ok    -config overlaid onto Config")
	}

	var reached, flusher, hijacker bool
	next := http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		reached = true
		// What compiled code (Traefik's proxy) can see on the writer the plugin
		// passes on. A plugin that wraps the writer keeps only what Yaegi's
		// wrapper for it exposes, and websockets need Hijacker.
		_, flusher = rw.(http.Flusher)
		_, hijacker = rw.(http.Hijacker)
		if p.backendType != "" {
			rw.Header().Set("Content-Type", p.backendType)
		}
		rw.WriteHeader(http.StatusOK)
		if p.backendBody != "" {
			_, _ = rw.Write([]byte(p.backendBody))
		}
	})

	out := vNew.Call([]reflect.Value{
		reflect.ValueOf(context.Background()),
		reflect.ValueOf(next),
		cfg,
		reflect.ValueOf("gate"),
	})
	if e := out[1].Interface(); e != nil {
		return fmt.Errorf("New() rejected the config: %w", e.(error))
	}
	h, ok := out[0].Interface().(http.Handler)
	if !ok {
		return fmt.Errorf("New() returned %T, not an http.Handler", out[0].Interface())
	}
	fmt.Println("ok    New() returned an http.Handler")

	req := httptest.NewRequest(http.MethodGet, "http://"+p.host+"/", nil)
	req.Host = p.host
	req.RemoteAddr = p.remote
	if p.accept != "" {
		req.Header.Set("Accept", p.accept)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(hijackableRecorder{rec}, req)
	fmt.Printf("ok    ServeHTTP ran: status=%d reached-backend=%v\n", rec.Code, reached)
	if reached {
		fmt.Printf("info  backend writer implements Flusher=%v Hijacker=%v\n", flusher, hijacker)
	}

	if p.wantHijacker && !hijacker {
		return fmt.Errorf("%w: the writer the backend got does not implement http.Hijacker, so websockets through this plugin would fail", errProbe)
	}
	if p.wantBody != "" {
		if !strings.Contains(rec.Body.String(), p.wantBody) {
			return fmt.Errorf("%w: response body does not contain -want-body\n  body: %q", errProbe, rec.Body.String())
		}
		fmt.Printf("ok    response body contains -want-body (%d bytes, Content-Length %q)\n",
			rec.Body.Len(), rec.Header().Get("Content-Length"))
	}
	return nil
}

// stageGoPath lays the plugin out the way the chart mounts it:
// <goPath>/src/<importPath>. Only the files Terraform vendors are copied, so the
// gate cannot pass on a *_test.go that production never ships.
func stageGoPath(dir, importPath string) (string, error) {
	goPath, err := os.MkdirTemp("", "yaegi-gate-")
	if err != nil {
		return "", err
	}
	target := filepath.Join(goPath, "src", filepath.FromSlash(importPath))
	if err := os.MkdirAll(target, 0o755); err != nil {
		return "", err
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	var staged int
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || strings.HasSuffix(name, "_test.go") {
			continue
		}
		if !strings.HasSuffix(name, ".go") && name != "go.mod" && name != ".traefik.yml" {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return "", err
		}
		if err := os.WriteFile(filepath.Join(target, name), b, 0o644); err != nil {
			return "", err
		}
		staged++
	}
	if staged == 0 {
		return "", fmt.Errorf("no plugin sources found in %s", dir)
	}
	fmt.Printf("ok    staged %d vendored file(s) at src/%s\n", staged, importPath)
	return goPath, nil
}
