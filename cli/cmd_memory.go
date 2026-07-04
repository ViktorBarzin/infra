package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
)

func memoryCommands() []Command {
	return []Command{
		{Path: []string{"memory", "recall"}, Tier: TierRead,
			Summary: `semantic search of memory: memory recall "<context>" [--query …] [--category] [--sort] [--limit]`, Run: memoryRecall},
		{Path: []string{"memory", "list"}, Tier: TierRead,
			Summary: "list recent memories [--category C] [--tag T] [--limit N]", Run: memoryList},
		{Path: []string{"memory", "categories"}, Tier: TierRead,
			Summary: "list memory categories", Run: memorySimpleGet("/api/categories")},
		{Path: []string{"memory", "tags"}, Tier: TierRead,
			Summary: "list memory tags", Run: memorySimpleGet("/api/tags")},
		{Path: []string{"memory", "stats"}, Tier: TierRead,
			Summary: "memory store stats", Run: memorySimpleGet("/api/stats")},
		{Path: []string{"memory", "secret"}, Tier: TierRead,
			Summary: "reveal a sensitive memory's content: memory secret <id>", Run: memorySecret},
		{Path: []string{"memory", "store"}, Tier: TierWrite,
			Summary: `store a memory: memory store "<content>" [--category --tags --keywords --importance --sensitive]`, Run: memoryStore},
		{Path: []string{"memory", "update"}, Tier: TierWrite,
			Summary: "update a memory: memory update <id> [--content --tags --importance --keywords]", Run: memoryUpdate},
		{Path: []string{"memory", "delete"}, Tier: TierWrite,
			Summary: "delete a memory: memory delete <id>", Run: memoryDelete},
	}
}

// printMemories renders a {memories:[…]} response as one line per memory, or raw JSON.
func printMemories(raw []byte, jsonOut bool) error {
	fmt.Print(renderMemories(raw, jsonOut))
	return nil
}

// renderMemories formats each memory as a single line with its FULL content
// (newlines flattened to spaces). Content is deliberately never truncated: the
// old 240-rune preview cut memories mid-sentence, misled agents into believing
// no full-content read-back existed, and made blind `update --content` from
// the preview silently destroy the stored tail. Full passthrough also can't
// produce invalid UTF-8 (the old mid-rune cut crashed the recall hook).
func renderMemories(raw []byte, jsonOut bool) string {
	if jsonOut {
		return string(raw) + "\n"
	}
	var r struct {
		Memories []struct {
			ID         int     `json:"id"`
			Content    string  `json:"content"`
			Category   string  `json:"category"`
			Tags       string  `json:"tags"`
			Importance float64 `json:"importance"`
		} `json:"memories"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return string(raw) + "\n"
	}
	if len(r.Memories) == 0 {
		return "(no memories)\n"
	}
	var b strings.Builder
	for _, m := range r.Memories {
		c := strings.ReplaceAll(m.Content, "\n", " ")
		fmt.Fprintf(&b, "#%d [%s] (%.2f) %s\n", m.ID, m.Category, m.Importance, c)
		if m.Tags != "" {
			fmt.Fprintf(&b, "       tags: %s\n", m.Tags)
		}
	}
	return b.String()
}

func memoryRecall(args []string) error {
	req := memRecallReq{}
	jsonOut := false
	var pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--query":
			if i+1 < len(args) {
				req.ExpandedQuery = args[i+1]
				i++
			}
		case a == "--category":
			if i+1 < len(args) {
				req.Category = args[i+1]
				i++
			}
		case a == "--sort":
			if i+1 < len(args) {
				req.SortBy = args[i+1]
				i++
			}
		case a == "--limit":
			if i+1 < len(args) {
				fmt.Sscanf(args[i+1], "%d", &req.Limit)
				i++
			}
		case a == "--json":
			jsonOut = true
		case !strings.HasPrefix(a, "-"):
			pos = append(pos, a)
		}
	}
	req.Context = strings.Join(pos, " ")
	if req.Context == "" {
		return fmt.Errorf(`usage: homelab memory recall "<context>" [--query …] [--category C] [--sort importance|relevance|recency] [--limit N]`)
	}
	c, err := newMemoryClient()
	if err != nil {
		return err
	}
	raw, err := c.do("POST", "/api/memories/recall", req)
	if err != nil {
		return err
	}
	return printMemories(raw, jsonOut)
}

func memoryList(args []string) error {
	q := url.Values{}
	jsonOut := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--category":
			if i+1 < len(args) {
				q.Set("category", args[i+1])
				i++
			}
		case a == "--tag":
			if i+1 < len(args) {
				q.Set("tag", args[i+1])
				i++
			}
		case a == "--limit":
			if i+1 < len(args) {
				q.Set("limit", args[i+1])
				i++
			}
		case a == "--json":
			jsonOut = true
		}
	}
	c, err := newMemoryClient()
	if err != nil {
		return err
	}
	path := "/api/memories"
	if len(q) > 0 {
		path += "?" + q.Encode()
	}
	raw, err := c.do("GET", path, nil)
	if err != nil {
		return err
	}
	return printMemories(raw, jsonOut)
}

func memorySimpleGet(path string) func([]string) error {
	return func(args []string) error {
		c, err := newMemoryClient()
		if err != nil {
			return err
		}
		raw, err := c.do("GET", path, nil)
		if err != nil {
			return err
		}
		fmt.Println(string(raw))
		return nil
	}
}

func memorySecret(args []string) error {
	id, _ := firstPositional(args)
	if id == "" {
		return fmt.Errorf("usage: homelab memory secret <id>")
	}
	c, err := newMemoryClient()
	if err != nil {
		return err
	}
	raw, err := c.do("POST", "/api/memories/"+id+"/secret", nil)
	if err != nil {
		return err
	}
	fmt.Println(string(raw))
	return nil
}

func memoryStore(args []string) error {
	req := memStoreReq{Category: "facts", Importance: 0.5}
	var pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--category":
			if i+1 < len(args) {
				req.Category = args[i+1]
				i++
			}
		case a == "--tags":
			if i+1 < len(args) {
				req.Tags = args[i+1]
				i++
			}
		case a == "--keywords":
			if i+1 < len(args) {
				req.ExpandedKeywords = args[i+1]
				i++
			}
		case a == "--importance":
			if i+1 < len(args) {
				fmt.Sscanf(args[i+1], "%f", &req.Importance)
				i++
			}
		case a == "--sensitive":
			req.ForceSensitive = true
		case !strings.HasPrefix(a, "-"):
			pos = append(pos, a)
		}
	}
	req.Content = strings.Join(pos, " ")
	if req.Content == "" {
		return fmt.Errorf(`usage: homelab memory store "<content>" [--category C] [--tags ...] [--keywords ...] [--importance 0.5] [--sensitive]`)
	}
	c, err := newMemoryClient()
	if err != nil {
		return err
	}
	raw, err := c.do("POST", "/api/memories", req)
	if err != nil {
		return err
	}
	fmt.Println(string(raw))
	return nil
}

func memoryUpdate(args []string) error {
	var id string
	req := memUpdateReq{}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--content":
			if i+1 < len(args) {
				v := args[i+1]
				req.Content = &v
				i++
			}
		case a == "--tags":
			if i+1 < len(args) {
				v := args[i+1]
				req.Tags = &v
				i++
			}
		case a == "--keywords":
			if i+1 < len(args) {
				v := args[i+1]
				req.ExpandedKeywords = &v
				i++
			}
		case a == "--importance":
			if i+1 < len(args) {
				var f float64
				fmt.Sscanf(args[i+1], "%f", &f)
				req.Importance = &f
				i++
			}
		case !strings.HasPrefix(a, "-") && id == "":
			id = a
		}
	}
	if id == "" {
		return fmt.Errorf("usage: homelab memory update <id> [--content ...] [--tags ...] [--importance N] [--keywords ...]")
	}
	c, err := newMemoryClient()
	if err != nil {
		return err
	}
	raw, err := c.do("PUT", "/api/memories/"+id, req)
	if err != nil {
		return err
	}
	fmt.Println(string(raw))
	return nil
}

func memoryDelete(args []string) error {
	id, _ := firstPositional(args)
	if id == "" {
		return fmt.Errorf("usage: homelab memory delete <id>")
	}
	c, err := newMemoryClient()
	if err != nil {
		return err
	}
	raw, err := c.do("DELETE", "/api/memories/"+id, nil)
	if err != nil {
		return err
	}
	fmt.Println(string(raw))
	return nil
}
