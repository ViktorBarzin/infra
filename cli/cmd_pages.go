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
