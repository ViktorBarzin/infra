package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// makeInfraCheckout lays down the two markers findInfraRoot looks for, plus
// the tool file, under dir.
func makeInfraCheckout(t *testing.T, dir, tool string) {
	t.Helper()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(dir, "stacks"), 0o755))
	must(os.WriteFile(filepath.Join(dir, "terragrunt.hcl"), nil, 0o644))
	if tool != "" {
		p := filepath.Join(dir, "scripts", tool)
		must(os.MkdirAll(filepath.Dir(p), 0o755))
		must(os.WriteFile(p, nil, 0o644))
	}
}

// The reflect and quality tooling lives in infra under scripts/. Two home
// layouts exist on the devvm: a workspace (~/code/infra is the infra clone,
// wizard) and a single layout (~/code IS the infra clone, emo). Both must
// resolve, and a plain workspace directory that merely has a scripts/ folder
// must not be mistaken for infra.
func TestFindInfraToolLayouts(t *testing.T) {
	for _, tool := range []string{
		filepath.Join("session-reflection", "reflect.py"),
		filepath.Join("code-quality", "quality.py"),
	} {
		cases := []struct {
			name   string
			layout func(t *testing.T, home string)
			want   string // relative to home; "" means not found
		}{
			{"workspace layout", func(t *testing.T, home string) {
				makeInfraCheckout(t, filepath.Join(home, "code", "infra"), tool)
			}, filepath.Join("code", "infra", "scripts", tool)},
			{"single layout", func(t *testing.T, home string) {
				makeInfraCheckout(t, filepath.Join(home, "code"), tool)
			}, filepath.Join("code", "scripts", tool)},
			{"workspace scripts dir that is not infra", func(t *testing.T, home string) {
				p := filepath.Join(home, "code", "scripts", tool)
				if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(p, nil, 0o644); err != nil {
					t.Fatal(err)
				}
			}, ""},
			{"infra clone without the tool", func(t *testing.T, home string) {
				makeInfraCheckout(t, filepath.Join(home, "code", "infra"), "")
			}, ""},
			{"no code dir", func(t *testing.T, home string) {}, ""},
		}
		for _, c := range cases {
			t.Run(filepath.Base(tool)+"/"+c.name, func(t *testing.T) {
				home := t.TempDir()
				c.layout(t, home)
				got, err := findInfraTool(home, tool)
				if c.want == "" {
					if err == nil {
						t.Fatalf("want not found, got %q", got)
					}
					if !strings.Contains(err.Error(), filepath.Join("scripts", tool)) {
						t.Errorf("error should name scripts/%s, got %q", tool, err)
					}
					return
				}
				if err != nil {
					t.Fatalf("want %s, got error %v", c.want, err)
				}
				if got != filepath.Join(home, c.want) {
					t.Errorf("got %q, want %q", got, filepath.Join(home, c.want))
				}
			})
		}
	}
}

// When both exist (a workspace whose root also happens to be an infra clone),
// the dedicated ~/code/infra clone wins.
func TestFindInfraToolPrefersWorkspaceClone(t *testing.T) {
	home := t.TempDir()
	tool := filepath.Join("session-reflection", "reflect.py")
	makeInfraCheckout(t, filepath.Join(home, "code", "infra"), tool)
	makeInfraCheckout(t, filepath.Join(home, "code"), tool)
	got, err := findInfraTool(home, tool)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(home, "code", "infra", "scripts", tool); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}
