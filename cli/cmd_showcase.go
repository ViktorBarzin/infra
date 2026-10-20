package main

import (
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

func showcaseCommands() []Command {
	return []Command{
		{Path: []string{"showcase", "build"}, Tier: TierRead,
			Summary: "generate the public homelab Showcase from live state: showcase build --out DIR [--src INFRA] [--data-only]",
			Run:     showcaseBuild},
	}
}

const (
	forgejoInfraAPI = "https://forgejo.viktorbarzin.me/api/v1/repos/viktor/infra"
	woodpeckerAPI   = "https://ci.viktorbarzin.me/api/repos/1"
)

// snapshot is data.json, the one file every Variant reads (ADR-0037).
type snapshot struct {
	Generated struct {
		At     string `json:"at"`
		Commit string `json:"commit"`
	} `json:"generated"`
	Stats    map[string]float64 `json:"stats"`
	Hardware showcaseHardware   `json:"hardware"`
	Layers   []layer            `json:"layers"`
	Services []showcaseService  `json:"services"`
	Graph    graph              `json:"graph"`
}

type showcaseHardware struct {
	Sites []hardwareSite `json:"sites"`
	Host  struct {
		Threads   float64 `json:"threads"`
		MemoryGiB float64 `json:"memory_gib"`
		StorageTB float64 `json:"storage_tb"`
	} `json:"host"`
	VMs   []string       `json:"vms"`
	Nodes []showcaseNode `json:"nodes"`
}

type showcaseNode struct {
	Name      string  `json:"name"`
	Role      string  `json:"role"`
	CPU       float64 `json:"cpu"`
	MemoryGiB float64 `json:"memory_gib"`
	GPU       bool    `json:"gpu"`
}

// showcaseBuild collects the Snapshot and writes it, plus the Variant files
// from showcase/web, into --out. Any source failing fails the build: the
// pipeline then keeps the last good page instead of publishing a partial one.
func showcaseBuild(args []string) error {
	out := flagValue(args, "--out")
	if out == "" {
		return fmt.Errorf("usage: homelab showcase build --out DIR [--src INFRA] [--data-only]")
	}
	src := flagValue(args, "--src")
	if src == "" {
		wd, _ := os.Getwd()
		root, err := findInfraRoot(wd)
		if err != nil {
			return err
		}
		src = root
	}

	var s snapshot
	s.Generated.At = time.Now().UTC().Format(time.RFC3339)
	s.Generated.Commit = os.Getenv("CI_COMMIT_SHA")
	if s.Generated.Commit == "" {
		c, _ := exec.Command("git", "-C", src, "rev-parse", "HEAD").Output()
		s.Generated.Commit = strings.TrimSpace(string(c))
	}

	stacks := map[string]bool{}
	for _, st := range listStacks(src) {
		if st != "_template" {
			stacks[st] = true
		}
	}

	hiddenNS, err := showcaseHiddenNamespaces()
	if err != nil {
		return err
	}
	ing, err := exec.Command("kubectl", "get", "ingress", "-A", "-o", "json").Output()
	if err != nil {
		return fmt.Errorf("cannot list ingresses: %w", err)
	}
	if s.Services, err = parseShowcaseServices(string(ing), stacks, hiddenNS); err != nil {
		return err
	}
	storage, err := showcaseStorageClasses()
	if err != nil {
		return err
	}
	visible := map[string]bool{}
	for i := range s.Services {
		s.Services[i].Route.Storage = append([]string{}, storage[s.Services[i].Namespace]...)
		visible[s.Services[i].Namespace] = true
	}

	rows, err := showcaseEdgeRows()
	if err != nil {
		return err
	}
	s.Graph = buildGraph(rows, visible)

	if s.Layers, err = buildLayers(func(p string) (string, error) {
		b, err := os.ReadFile(filepath.Join(src, p))
		return string(b), err
	}); err != nil {
		return err
	}

	hw, err := os.ReadFile(filepath.Join(src, "showcase", "hardware.yaml"))
	if err != nil {
		return err
	}
	if s.Hardware.Sites, err = parseHardware(hw); err != nil {
		return err
	}
	if err := showcaseLiveHardware(&s.Hardware); err != nil {
		return err
	}

	if s.Stats, err = showcaseStats(); err != nil {
		return err
	}
	s.Stats["services"] = float64(len(s.Services))
	s.Stats["stacks"] = float64(len(stacks))
	s.Stats["vms"] = float64(len(s.Hardware.VMs))

	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	if !containsArg(args, "--data-only") {
		if err := copyTree(filepath.Join(src, "showcase", "web"), out); err != nil {
			return err
		}
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(out, "data.json"), b, 0o644); err != nil {
		return err
	}
	fmt.Printf("showcase: %d services, %d graph nodes, %d edges -> %s\n",
		len(s.Services), len(s.Graph.Nodes), len(s.Graph.Edges), out)
	return nil
}

func showcaseHiddenNamespaces() (map[string]bool, error) {
	raw, err := exec.Command("kubectl", "get", "namespaces", "-o", "json").Output()
	if err != nil {
		return nil, fmt.Errorf("cannot list namespaces: %w", err)
	}
	var list struct {
		Items []struct {
			Metadata struct {
				Name        string            `json:"name"`
				Annotations map[string]string `json:"annotations"`
			} `json:"metadata"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		return nil, err
	}
	hidden := map[string]bool{}
	for _, it := range list.Items {
		if it.Metadata.Annotations[showcaseHiddenAnnotation] == "true" {
			hidden[it.Metadata.Name] = true
		}
	}
	return hidden, nil
}

// showcaseStorageClasses maps each namespace to the storage classes its PVCs use.
func showcaseStorageClasses() (map[string][]string, error) {
	raw, err := exec.Command("kubectl", "get", "pvc", "-A", "-o", "json").Output()
	if err != nil {
		return nil, fmt.Errorf("cannot list PVCs: %w", err)
	}
	var list struct {
		Items []struct {
			Metadata struct {
				Namespace string `json:"namespace"`
			} `json:"metadata"`
			Spec struct {
				StorageClassName string `json:"storageClassName"`
			} `json:"spec"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		return nil, err
	}
	seen := map[string]map[string]bool{}
	out := map[string][]string{}
	for _, it := range list.Items {
		ns, sc := it.Metadata.Namespace, it.Spec.StorageClassName
		if sc == "" {
			continue
		}
		if seen[ns] == nil {
			seen[ns] = map[string]bool{}
		}
		if !seen[ns][sc] {
			seen[ns][sc] = true
			out[ns] = append(out[ns], sc)
		}
	}
	return out, nil
}

// showcaseEdgeQuery reads goldmane_edges directly rather than through `homelab
// edges`: that verb's JSON drops dst_port, which the Plumbing filter needs, and
// caps rows at 200 by default.
const showcaseEdgeQuery = "SELECT coalesce(json_agg(row_to_json(t)), '[]') FROM (" +
	"SELECT src_ns, dst_ns, coalesce(dst_port, 0) AS dst_port, sum(flow_count) AS flows FROM edge " +
	"WHERE action = 'allow' AND last_seen > now() - interval '30 days' " +
	"GROUP BY src_ns, dst_ns, dst_port) t"

func showcaseEdgeRows() ([]edgeRow, error) {
	pod, err := resolveServicePod("dbaas", "postgresql")
	if err != nil {
		return nil, fmt.Errorf("could not resolve the Postgres primary pod: %v", err)
	}
	raw, err := kubectlCapture("dbaas", "exec", pod, "-c", "postgres", "--",
		"psql", "-U", "postgres", "-d", "goldmane_edges", "-tAc", showcaseEdgeQuery)
	if err != nil {
		return nil, fmt.Errorf("edges query failed: %w", err)
	}
	var rows []edgeRow
	if err := json.Unmarshal([]byte(raw), &rows); err != nil {
		return nil, fmt.Errorf("cannot parse edges: %w", err)
	}
	return rows, nil
}

func promScalar(q string) (float64, error) {
	body, err := lbGetBody(promHost, "/api/v1/query", url.Values{"query": {q}})
	if err != nil {
		return 0, err
	}
	var r struct {
		Data struct {
			Result []struct {
				Value []any `json:"value"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return 0, err
	}
	if len(r.Data.Result) != 1 || len(r.Data.Result[0].Value) != 2 {
		return 0, fmt.Errorf("query %q returned %d series, want 1", q, len(r.Data.Result))
	}
	v, _ := r.Data.Result[0].Value[1].(string)
	return strconv.ParseFloat(v, 64)
}

// showcaseQueries are the pinned queries from the design doc. Storage comes from
// the Proxmox exporter: kubelet volume stats count each NFS export once per PVC.
var showcaseQueries = map[string]string{
	"pods":             `sum(kube_pod_status_phase{phase="Running"})`,
	"nodes":            `count(kube_node_info)`,
	"cores":            `sum(kube_node_status_capacity{resource="cpu"})`,
	"memory_gib":       `sum(kube_node_status_capacity{resource="memory"}) / 2^30`,
	"requests_per_day": `sum(increase(traefik_service_requests_total[1d]))`,
	"storage_tb":       `sum(pve_disk_size_bytes{id=~"storage/.*"}) / 1e12`,
	"host_threads":     `pve_cpu_usage_limit{id="node/pve"}`,
	"host_memory_gib":  `pve_memory_size_bytes{id="node/pve"} / 2^30`,
}

func showcaseStats() (map[string]float64, error) {
	stats := map[string]float64{}
	for k, q := range showcaseQueries {
		v, err := promScalar(q)
		if err != nil {
			return nil, fmt.Errorf("stat %s: %w", k, err)
		}
		stats[k] = v
	}
	var err error
	if stats["commits_per_week"], err = forgejoCommitsSince(time.Now().AddDate(0, 0, -7)); err != nil {
		return nil, fmt.Errorf("stat commits_per_week: %w", err)
	}
	if stats["ci_runs_per_week"], err = woodpeckerRunsSince(time.Now().AddDate(0, 0, -7)); err != nil {
		return nil, fmt.Errorf("stat ci_runs_per_week: %w", err)
	}
	if stats["agent_fixes_30d"], err = agentFixesSince(time.Now().AddDate(0, 0, -30)); err != nil {
		return nil, fmt.Errorf("stat agent_fixes_30d: %w", err)
	}
	return stats, nil
}

func fetchJSONInto(u string, v any) error {
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Get(u)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s -> %d", u, resp.StatusCode)
	}
	return json.Unmarshal(body, v)
}

// forgejoCommitsSince counts infra commits since t. The API ignores `since`
// when paging (X-Total-Count is the whole history), so this walks newest-first
// and stops at the first older commit.
func forgejoCommitsSince(t time.Time) (float64, error) {
	n := 0
	for page := 1; page < 200; page++ {
		var commits []struct {
			Created time.Time `json:"created"`
		}
		u := fmt.Sprintf("%s/commits?sha=master&limit=50&page=%d&stat=false&verification=false&files=false",
			forgejoInfraAPI, page)
		if err := fetchJSONInto(u, &commits); err != nil {
			return 0, err
		}
		for _, c := range commits {
			if c.Created.Before(t) {
				return float64(n), nil
			}
			n++
		}
		if len(commits) < 50 {
			break
		}
	}
	return float64(n), nil
}

// woodpeckerRunsSince counts infra pipelines created since t, newest first.
func woodpeckerRunsSince(t time.Time) (float64, error) {
	n := 0
	for page := 1; page < 100; page++ {
		var runs []struct {
			Created int64 `json:"created"`
		}
		if err := fetchJSONInto(fmt.Sprintf("%s/pipelines?per_page=50&page=%d", woodpeckerAPI, page), &runs); err != nil {
			return 0, err
		}
		for _, r := range runs {
			if r.Created < t.Unix() {
				return float64(n), nil
			}
			n++
		}
		if len(runs) < 50 {
			break
		}
	}
	return float64(n), nil
}

// agentFixesSince counts `broken` issues closed by the fixer agent since t. No
// label marks an agent fix, so the close event's author in the timeline decides.
func agentFixesSince(t time.Time) (float64, error) {
	var issues []struct {
		Number   int       `json:"number"`
		ClosedAt time.Time `json:"closed_at"`
	}
	u := fmt.Sprintf("%s/issues?state=closed&labels=broken&type=issues&since=%s&limit=50",
		forgejoInfraAPI, t.UTC().Format(time.RFC3339))
	if err := fetchJSONInto(u, &issues); err != nil {
		return 0, err
	}
	n := 0
	for _, is := range issues {
		if is.ClosedAt.Before(t) {
			continue
		}
		var events []struct {
			Type string `json:"type"`
			User struct {
				Login string `json:"login"`
			} `json:"user"`
		}
		if err := fetchJSONInto(fmt.Sprintf("%s/issues/%d/timeline", forgejoInfraAPI, is.Number), &events); err != nil {
			return 0, err
		}
		for _, e := range events {
			if e.Type == "close" && e.User.Login == "infra-agent" {
				n++
				break
			}
		}
	}
	return float64(n), nil
}

func showcaseLiveHardware(h *showcaseHardware) error {
	var err error
	if h.Host.Threads, err = promScalar(showcaseQueries["host_threads"]); err != nil {
		return err
	}
	if h.Host.MemoryGiB, err = promScalar(showcaseQueries["host_memory_gib"]); err != nil {
		return err
	}
	if h.Host.StorageTB, err = promScalar(showcaseQueries["storage_tb"]); err != nil {
		return err
	}
	body, err := lbGetBody(promHost, "/api/v1/query",
		url.Values{"query": {`pve_guest_info{type="qemu",template="0"} * on(id) group_left pve_up == 1`}})
	if err != nil {
		return err
	}
	var r struct {
		Data struct {
			Result []struct {
				Metric map[string]string `json:"metric"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return err
	}
	for _, s := range r.Data.Result {
		h.VMs = append(h.VMs, s.Metric["name"])
	}
	sort.Strings(h.VMs)

	raw, err := exec.Command("kubectl", "get", "nodes", "-o", "json").Output()
	if err != nil {
		return fmt.Errorf("cannot list nodes: %w", err)
	}
	var nodes struct {
		Items []struct {
			Metadata struct {
				Name   string            `json:"name"`
				Labels map[string]string `json:"labels"`
			} `json:"metadata"`
			Status struct {
				Capacity map[string]string `json:"capacity"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &nodes); err != nil {
		return err
	}
	for _, n := range nodes.Items {
		role := "worker"
		if _, ok := n.Metadata.Labels["node-role.kubernetes.io/control-plane"]; ok {
			role = "control-plane"
		}
		cpu, _ := strconv.ParseFloat(n.Status.Capacity["cpu"], 64)
		mem := strings.TrimSuffix(n.Status.Capacity["memory"], "Ki")
		kib, _ := strconv.ParseFloat(mem, 64)
		h.Nodes = append(h.Nodes, showcaseNode{
			Name: n.Metadata.Name, Role: role, CPU: cpu, MemoryGiB: kib / (1 << 20),
			GPU: n.Status.Capacity["nvidia.com/gpu"] != "" && n.Status.Capacity["nvidia.com/gpu"] != "0",
		})
	}
	return nil
}

// copyTree copies the Variant source tree into the output directory.
func copyTree(from, to string) error {
	return filepath.WalkDir(from, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(from, p)
		dst := filepath.Join(to, rel)
		if d.IsDir() {
			return os.MkdirAll(dst, 0o755)
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(dst, b, 0o644)
	})
}
