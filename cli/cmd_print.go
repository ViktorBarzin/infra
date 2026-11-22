package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
)

// readmeNotesHTML renders a project README as the HTML that Bambuddy's
// project notes hold (its notes editor stores HTML and sanitises it on
// display). Raw HTML in the Markdown is dropped, goldmark's default.
func readmeNotesHTML(md []byte) (string, error) {
	var buf bytes.Buffer
	if err := goldmark.New(goldmark.WithExtensions(extension.GFM)).Convert(md, &buf); err != nil {
		return "", err
	}
	return buf.String(), nil
}

// `homelab print` publishes designed 3D parts into Bambuddy
// (bambuddy.viktorbarzin.me, stacks/bambuddy), where people preview, slice
// and print them. One Bambuddy project per part, with a library folder of the
// same name linked to it; the files go in that folder. Starting a print stays
// with a person in the web app.

const defaultBambuddyURL = "https://bambuddy.viktorbarzin.me"

// bambuddyAgentKeyPath holds the API key of Bambuddy's local `agent` user
// (library and projects scopes, no printer control). Readable by admins and,
// through projects-emo, by emo.
const bambuddyAgentKeyPath = "secret/bambuddy-agent"

// printVaultRunner reads the key from Vault when BAMBUDDY_API_KEY is unset; a
// seam for tests.
var printVaultRunner cmdRunner = realRunner

func printCommands() []Command {
	return []Command{
		{Path: []string{"print", "projects"}, Tier: TierRead,
			Summary: "list the 3D-print projects in Bambuddy with their page URLs",
			Run:     printProjects},
		{Path: []string{"print", "publish"}, Tier: TierWrite,
			Summary: "publish a designed part into Bambuddy: --project NAME [--description D] [--url U] [--cover IMG] <file|dir>... (same filename = new revision)",
			Run:     printPublish},
	}
}

type bambuddyClient struct {
	base string
	key  string
	http *http.Client
}

func newBambuddyClient() (*bambuddyClient, error) {
	base := strings.TrimRight(firstEnv("BAMBUDDY_URL"), "/")
	if base == "" {
		base = defaultBambuddyURL
	}
	key := firstEnv("BAMBUDDY_API_KEY")
	if key == "" {
		key = readVaultField(printVaultRunner, "api_key", bambuddyAgentKeyPath)
	}
	if key == "" {
		return nil, fmt.Errorf("no Bambuddy API key: set BAMBUDDY_API_KEY, or log in to Vault with read on %s", bambuddyAgentKeyPath)
	}
	return &bambuddyClient{base: base, key: key, http: &http.Client{Timeout: 5 * time.Minute}}, nil
}

func (c *bambuddyClient) send(req *http.Request, out any) error {
	req.Header.Set("X-API-Key", c.key)
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return fmt.Errorf("Bambuddy %s %s -> %d: %s", req.Method, req.URL.Path, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	if out != nil && len(body) > 0 {
		return json.Unmarshal(body, out)
	}
	return nil
}

func (c *bambuddyClient) json(method, path string, in, out any) error {
	var r io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.base+path, r)
	if err != nil {
		return err
	}
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return c.send(req, out)
}

// upload posts one file as the multipart field "file".
func (c *bambuddyClient) upload(path, local string, out any) error {
	f, err := os.Open(local)
	if err != nil {
		return err
	}
	defer f.Close()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	part, err := mw.CreateFormFile("file", filepath.Base(local))
	if err != nil {
		return err
	}
	if _, err := io.Copy(part, f); err != nil {
		return err
	}
	if err := mw.Close(); err != nil {
		return err
	}
	req, err := http.NewRequest("POST", c.base+path, &buf)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	return c.send(req, out)
}

func (c *bambuddyClient) projectURL(id int) string {
	return fmt.Sprintf("%s/projects/%d", c.base, id)
}

type bambuddyProject struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

type bambuddyFolder struct {
	ID        int    `json:"id"`
	Name      string `json:"name"`
	ParentID  *int   `json:"parent_id"`
	ProjectID *int   `json:"project_id"`
}

type bambuddyFile struct {
	ID       int    `json:"id"`
	Filename string `json:"filename"`
	FolderID *int   `json:"folder_id"`
}

func printProjects(args []string) error {
	c, err := newBambuddyClient()
	if err != nil {
		return err
	}
	var ps []bambuddyProject
	if err := c.json("GET", "/api/v1/projects/", nil, &ps); err != nil {
		return err
	}
	if len(ps) == 0 {
		fmt.Println("no projects yet")
		return nil
	}
	for _, p := range ps {
		fmt.Printf("%-40s %s\n", p.Name, c.projectURL(p.ID))
	}
	return nil
}

// printPublishFiles expands the arguments: a file stands for itself, a
// directory for its visible top-level files (no recursion, so a folder of old
// revisions next to the current files is not swept in).
func printPublishFiles(args []string) ([]string, error) {
	var files []string
	for _, a := range args {
		st, err := os.Stat(a)
		if err != nil {
			return nil, err
		}
		if !st.IsDir() {
			files = append(files, a)
			continue
		}
		entries, err := os.ReadDir(a)
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			if e.IsDir() || strings.HasPrefix(e.Name(), ".") {
				continue
			}
			files = append(files, filepath.Join(a, e.Name()))
		}
	}
	return files, nil
}

func printPublish(args []string) error {
	fs := flag.NewFlagSet("print publish", flag.ContinueOnError)
	project := fs.String("project", "", "project name; created with a library folder of the same name when absent")
	desc := fs.String("description", "", "project description, set when the project is created")
	link := fs.String("url", "", "a link for the project (MakerWorld, Printables, a design page), set when the project is created")
	cover := fs.String("cover", "", "an image to use as the project's cover photo")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *project == "" {
		return fmt.Errorf("--project is required: homelab print publish --project NAME <file|dir>...")
	}
	files, err := printPublishFiles(fs.Args())
	if err != nil {
		return err
	}
	if len(files) == 0 {
		return fmt.Errorf("no files to publish: give one or more files or directories")
	}
	c, err := newBambuddyClient()
	if err != nil {
		return err
	}

	// The project, found by exact name or created.
	var ps []bambuddyProject
	if err := c.json("GET", "/api/v1/projects/", nil, &ps); err != nil {
		return err
	}
	var proj *bambuddyProject
	for i := range ps {
		if ps[i].Name == *project {
			proj = &ps[i]
			break
		}
	}
	if proj == nil {
		in := map[string]any{"name": *project}
		if *desc != "" {
			in["description"] = *desc
		}
		if *link != "" {
			in["url"] = *link
		}
		var created bambuddyProject
		if err := c.json("POST", "/api/v1/projects/", in, &created); err != nil {
			return err
		}
		proj = &created
		fmt.Printf("created project %q\n", *project)
	}

	// The library folder linked to it: a top-level folder of the same name.
	var folders []bambuddyFolder
	if err := c.json("GET", "/api/v1/library/folders/", nil, &folders); err != nil {
		return err
	}
	folderID := 0
	for _, f := range folders {
		if f.ParentID == nil && f.ProjectID != nil && *f.ProjectID == proj.ID {
			folderID = f.ID
			break
		}
	}
	if folderID == 0 {
		var created bambuddyFolder
		in := map[string]any{"name": *project, "project_id": proj.ID}
		if err := c.json("POST", "/api/v1/library/folders/", in, &created); err != nil {
			return err
		}
		folderID = created.ID
	}

	// A file with the same name is the previous revision: replace it.
	var existing []bambuddyFile
	if err := c.json("GET", "/api/v1/library/files/?folder_id="+url.QueryEscape(fmt.Sprint(folderID)), nil, &existing); err != nil {
		return err
	}
	for _, local := range files {
		name := filepath.Base(local)
		for _, e := range existing {
			if e.Filename == name && e.FolderID != nil && *e.FolderID == folderID {
				if err := c.json("DELETE", fmt.Sprintf("/api/v1/library/files/%d", e.ID), nil, nil); err != nil {
					return err
				}
				fmt.Printf("replacing %s\n", name)
			}
		}
		if err := c.upload(fmt.Sprintf("/api/v1/library/files/?folder_id=%d", folderID), local, nil); err != nil {
			return err
		}
		fmt.Printf("uploaded %s\n", name)
	}

	// The README is also the project's notes, so the project page shows it,
	// not only the File Manager. Republishing the README updates them.
	for _, local := range files {
		if !strings.EqualFold(filepath.Base(local), "README.md") {
			continue
		}
		md, err := os.ReadFile(local)
		if err != nil {
			return err
		}
		html, err := readmeNotesHTML(md)
		if err != nil {
			return err
		}
		if err := c.json("PATCH", fmt.Sprintf("/api/v1/projects/%d", proj.ID), map[string]any{"notes": html}, nil); err != nil {
			return err
		}
		fmt.Println("project notes set from README.md")
	}

	if *cover != "" {
		if err := c.upload(fmt.Sprintf("/api/v1/projects/%d/cover-image", proj.ID), *cover, nil); err != nil {
			return err
		}
		fmt.Printf("cover set from %s\n", filepath.Base(*cover))
	}
	fmt.Println(c.projectURL(proj.ID))
	return nil
}
