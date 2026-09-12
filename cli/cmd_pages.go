package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func pagesCommands() []Command {
	return []Command{
		{Path: []string{"pages", "publish"}, Tier: TierWrite,
			Summary: "publish a markdown doc as an HTML page: pages publish <path/to/doc.md> [--shared] [--status draft|approved|executing|done]", Run: pagesPublish},
		{Path: []string{"pages", "preview"}, Tier: TierRead,
			Summary: "render a doc to local files you can open and screenshot, without publishing: pages preview <path/to/doc.md> [--status ...] [--out DIR]", Run: pagesPreview},
	}
}

func pagesPublish(args []string) error {
	req := pagesPublishReq{Status: "draft"}
	var path string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--shared":
			req.Shared = true
		case a == "--status":
			if i+1 < len(args) {
				req.Status = args[i+1]
				i++
			}
		case !strings.HasPrefix(a, "-") && path == "":
			path = a
		}
	}
	if path == "" {
		return fmt.Errorf("usage: homelab pages publish <path/to/doc.md> [--shared] [--status draft|approved|executing|done]")
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("cannot read %s: %w", path, err)
	}
	req.Content = string(content)
	req.Filename = filepath.Base(path)
	c, err := newPagesClient()
	if err != nil {
		return err
	}
	raw, err := c.do("POST", "/publish", req)
	if err != nil {
		return err
	}
	var resp pagesPublishResp
	if err := json.Unmarshal(raw, &resp); err != nil || resp.URL == "" {
		// 2xx but not the expected {url,path} shape — show it raw rather than
		// swallow whatever the server actually said.
		fmt.Println(strings.TrimSpace(string(raw)))
		return nil
	}
	fmt.Println(resp.URL)
	if resp.Path != "" {
		fmt.Println(resp.Path)
	}
	return nil
}

// pagesPreview renders a doc through the same service and writes the result to
// disk instead of publishing it. The point is verification: pages.viktorbarzin.me
// is owner-gated and 403s every automated client, and a user without a monorepo
// checkout has no renderer of their own, so this is the only way for them to
// SEE a page before it is on the site.
//
// The layout written is the site's own — assets at <dir>/assets/, page at
// <dir>/<file>.html — because the page links them as absolute /assets/... So
// serving <dir> as the document root reproduces the published page exactly,
// which a flat dump of one file would not.
func pagesPreview(args []string) error {
	req := pagesPreviewReq{Status: "draft"}
	var path, outDir string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--shared":
			req.Shared = true
		case a == "--status":
			if i+1 < len(args) {
				req.Status = args[i+1]
				i++
			}
		case a == "--out":
			if i+1 < len(args) {
				outDir = args[i+1]
				i++
			}
		case !strings.HasPrefix(a, "-") && path == "":
			path = a
		}
	}
	if path == "" {
		return fmt.Errorf("usage: homelab pages preview <path/to/doc.md> [--shared] [--status draft|approved|executing|done] [--out DIR]")
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("cannot read %s: %w", path, err)
	}
	req.Content = string(content)
	req.Filename = filepath.Base(path)
	c, err := newPagesClient()
	if err != nil {
		return err
	}
	raw, err := c.do("POST", "/preview", req)
	if err != nil {
		return err
	}
	var resp pagesPreviewResp
	if err := json.Unmarshal(raw, &resp); err != nil {
		return fmt.Errorf("pages API returned a body this CLI cannot read: %w", err)
	}
	if resp.Filename == "" || resp.HTML == "" {
		return fmt.Errorf("pages API returned no rendered page")
	}
	if outDir == "" {
		outDir = defaultPreviewDir(strings.TrimSuffix(resp.Filename, ".html"))
	}
	pagePath, err := writePreview(outDir, resp)
	if err != nil {
		return err
	}
	fmt.Println(pagePath)
	fmt.Println(outDir)
	return nil
}

// defaultPreviewDir is where a preview lands when --out is not given: one
// directory per page, so re-previewing the same doc replaces the last render
// instead of leaving a trail.
//
// It must be PER USER. The devvm is shared, and a single /tmp/homelab-pages-preview
// owned by whoever ran the verb first is a directory every other user gets
// EACCES from — measured, not theorised: the first run as a second user failed
// exactly that way. The cache dir is per-user by construction; the uid-suffixed
// temp path is the fallback for an account with no HOME.
func defaultPreviewDir(slug string) string {
	if cache, err := os.UserCacheDir(); err == nil && cache != "" {
		return filepath.Join(cache, "homelab", "pages-preview", slug)
	}
	return filepath.Join(os.TempDir(), fmt.Sprintf("homelab-pages-preview-%d", os.Getuid()), slug)
}

// safeAssetPath accepts only a plain relative path, which is what the server
// sends ("assets/page.css"). Refusing the rest is deliberate: filepath.Clean
// would quietly rewrite "../../.ssh/id_rsa" into the output dir and write a
// file called id_rsa, and a silent rewrite is a worse answer than an error.
func safeAssetPath(name string) bool {
	if name == "" || filepath.IsAbs(name) || strings.ContainsRune(name, '\\') {
		return false
	}
	for _, seg := range strings.Split(name, "/") {
		if seg == "" || seg == "." || seg == ".." {
			return false
		}
	}
	return true
}

// writePreview lays the page and its assets out under dir and returns the page
// path. Asset keys come from the server; each one is re-checked here so a
// server that ever returned "../../.ssh/id_rsa" could not write through this
// client.
func writePreview(dir string, resp pagesPreviewResp) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("cannot create %s: %w", dir, err)
	}
	root, err := filepath.Abs(dir)
	if err != nil {
		return "", err
	}
	for name, body := range resp.Assets {
		if !safeAssetPath(name) {
			return "", fmt.Errorf("refusing asset path outside %s: %q", root, name)
		}
		dest := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return "", fmt.Errorf("cannot create %s: %w", filepath.Dir(dest), err)
		}
		if err := os.WriteFile(dest, []byte(body), 0o644); err != nil {
			return "", fmt.Errorf("cannot write %s: %w", dest, err)
		}
	}
	page := filepath.Join(root, filepath.Base(resp.Filename))
	if err := os.WriteFile(page, []byte(resp.HTML), 0o644); err != nil {
		return "", fmt.Errorf("cannot write %s: %w", page, err)
	}
	return page, nil
}
