// Command yaegi-plugin-gate loads a vendored Traefik middleware plugin under the
// same Yaegi interpreter version Traefik embeds, and serves one request through
// it. See README.md for why `go build` + `go test` are not enough.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
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

	if err := run(*dir, *importPath, pkg, *cfgJSON, *host, *remote); err != nil {
		fmt.Printf("FAIL  %v\n", err)
		// The two failure classes have very different blast radii, so say which.
		if errors.Is(err, errLoad) {
			fmt.Println("\nYaegi could not load this plugin, which disables ALL Traefik plugins at")
			fmt.Println("startup (api-token-middleware included). Do not apply.")
		} else {
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

func run(dir, importPath, basePkg, cfgJSON, host, remote string) (err error) {
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

	var reached bool
	next := http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		reached = true
		rw.WriteHeader(http.StatusOK)
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

	req := httptest.NewRequest(http.MethodGet, "http://"+host+"/", nil)
	req.Host = host
	req.RemoteAddr = remote
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	fmt.Printf("ok    ServeHTTP ran: status=%d reached-backend=%v\n", rec.Code, reached)
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
