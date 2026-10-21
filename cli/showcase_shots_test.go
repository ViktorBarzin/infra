package main

import (
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestParseShotsArgs(t *testing.T) {
	now := time.Date(2026, 10, 21, 4, 5, 6, 0, time.UTC)
	o, err := parseShotsArgs(nil, now)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(o.Dashboards, []string{"energy", "heating", "it"}) {
		t.Fatalf("default dashboards = %v", o.Dashboards)
	}
	if filepath.Base(o.Out) != "showcase-shots-20261021-040506" {
		t.Fatalf("default out = %s", o.Out)
	}

	o, err = parseShotsArgs([]string{"--out", "/tmp/x", "--dashboards", "it, energy"}, now)
	if err != nil {
		t.Fatal(err)
	}
	if o.Out != "/tmp/x" || !reflect.DeepEqual(o.Dashboards, []string{"it", "energy"}) {
		t.Fatalf("got %+v", o)
	}

	if _, err := parseShotsArgs([]string{"--dashboards", "cctv"}, now); err == nil {
		t.Fatal("an unknown dashboard (e.g. the camera one) must be refused")
	}
}

func TestMapShotDashboards(t *testing.T) {
	list := []lovelaceDashboard{
		{URLPath: "el-energiia-i-zahranvane", Title: "Енергия и захранване"},
		{URLPath: "heating-renamed", Title: "Отопление и климат"},
		{URLPath: "dashboard-it", Title: "Мрежа и IT"},
		{URLPath: "dashboard-videonabliudenie", Title: "Видеонаблюдение"},
	}
	got, err := mapShotDashboards(list, []string{"energy", "heating", "it"})
	if err != nil {
		t.Fatal(err)
	}
	if got["energy"].URLPath != "el-energiia-i-zahranvane" || got["it"].URLPath != "dashboard-it" {
		t.Fatalf("url_path match: %+v", got)
	}
	if got["heating"].URLPath != "heating-renamed" {
		t.Fatalf("title fallback: %+v", got["heating"])
	}

	_, err = mapShotDashboards(list[3:], []string{"energy"})
	if err == nil || !strings.Contains(err.Error(), "energy") {
		t.Fatalf("a missing dashboard must name itself, got %v", err)
	}
}

func TestShotFileNames(t *testing.T) {
	var names []string
	for _, v := range shotVariants {
		names = append(names, shotFileName("heating", v))
	}
	want := []string{"heating-desktop-light.png", "heating-desktop-dark.png", "heating-phone-light.png", "heating-phone-dark.png"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("got %v", names)
	}
}

func TestMaskScriptIsAFunctionExpression(t *testing.T) {
	s := strings.TrimSpace(showcaseMaskJS)
	for strings.HasPrefix(s, "//") {
		s = strings.TrimSpace(s[strings.Index(s, "\n"):])
	}
	if !strings.HasPrefix(s, "(dark, given) =>") {
		t.Fatalf("showcase_mask.js must be one function expression, starts %q", s[:20])
	}
}

func TestResolveMaskWords(t *testing.T) {
	env := func(v string) func(string) string { return func(string) string { return v } }
	vaultOK := func() (string, error) { return " Den, Gnome Room ,, Shed B ", nil }
	vaultDown := func() (string, error) { return "", errors.New("permission denied") }

	got, err := resolveMaskWords(env(""), vaultOK)
	if err != nil || !reflect.DeepEqual(got, []string{"Den", "Gnome Room", "Shed B"}) {
		t.Fatalf("from vault: %v %v", got, err)
	}
	got, err = resolveMaskWords(env("Attic"), vaultDown)
	if err != nil || !reflect.DeepEqual(got, []string{"Attic"}) {
		t.Fatalf("env must win and skip vault: %v %v", got, err)
	}
	if _, err := resolveMaskWords(env(""), vaultDown); err == nil {
		t.Fatal("no env and no vault must refuse to capture")
	}
	if _, err := resolveMaskWords(env(" , "), func() (string, error) { return "", nil }); err == nil {
		t.Fatal("an empty list must refuse to capture")
	}
}
