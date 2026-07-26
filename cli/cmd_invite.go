package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// The `invite` verbs mint / list / revoke authentik invite codes for the
// invite-gated scoped-access model (ViktorBarzin/infra#82): each code maps to ONE
// authentik group, and the enrollment flow drops the new user into that group.
// A code is a native authentik Invitation whose fixed_data carries {code,
// target_group}; the enrollment flow validates the typed code against fixed_data
// and assigns the group. The authentik API token is read from Vault
// (secret/authentik tf_api_token) using the caller's own Vault token.
func inviteCommands() []Command {
	return []Command{
		{Path: []string{"invite", "create"}, Tier: TierWrite,
			Summary: "mint an invite code for a group: invite create --group <name> [--uses N] [--expires 7d] [--label who]", Run: inviteCreate},
		{Path: []string{"invite", "list"}, Tier: TierRead,
			Summary: "list outstanding invite codes (code, group, single-use, expiry)", Run: inviteList},
		{Path: []string{"invite", "revoke"}, Tier: TierWrite,
			Summary: "revoke an invite code: invite revoke <code>", Run: inviteRevoke},
		{Path: []string{"invite"}, Tier: TierRead,
			Summary: "authentik invite codes -> scoped groups (run `homelab invite` for help)",
			Run:     func([]string) error { fmt.Print(inviteHelp()); return nil }},
	}
}

func inviteHelp() string {
	return `homelab invite — authentik invite codes that drop a new user into ONE group

  homelab invite create --group "<name>" [--uses N] [--expires 7d] [--label who]
        mint a code tied to <name>. Defaults: single-use, 7-day expiry.
        --uses 0 = multi-use (until it expires). Prints the code to share.
  homelab invite list                 outstanding codes: code, group, uses, expiry
  homelab invite revoke <code>        delete the invite for <code>

The invitee opens any gated service (e.g. proxy.viktorbarzin.me), signs in with
Google/passkey, and enters the code — they land in <name> and nothing else.
`
}

// --- pure, tested helpers --------------------------------------------------

// inviteAlphabet is 32 unambiguous chars (no 0/O/1/I/L) for a typeable code.
const inviteAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

// genInviteCode returns an 8-char code from inviteAlphabet (~10^12 space).
func genInviteCode() (string, error) {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	out := make([]byte, 8)
	for i, c := range b {
		out[i] = inviteAlphabet[int(c)%len(inviteAlphabet)]
	}
	return string(out), nil
}

// parseExpiry turns "7d" / "48h" / "30m" into a Duration ("d" = 24h; the Go
// time package has no day unit).
func parseExpiry(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("empty expiry")
	}
	if strings.HasSuffix(s, "d") {
		n, err := strconv.Atoi(strings.TrimSuffix(s, "d"))
		if err != nil || n <= 0 {
			return 0, fmt.Errorf("bad expiry %q (want e.g. 7d, 48h, 30m)", s)
		}
		return time.Duration(n) * 24 * time.Hour, nil
	}
	d, err := time.ParseDuration(s)
	if err != nil || d <= 0 {
		return 0, fmt.Errorf("bad expiry %q (want e.g. 7d, 48h, 30m)", s)
	}
	return d, nil
}

// buildInvitePayload is the authentik Invitation create body. authentik requires
// a unique name; the code carries the group in fixed_data for the enrollment flow.
func buildInvitePayload(code, group string, singleUse bool, expiresAt time.Time) map[string]interface{} {
	return map[string]interface{}{
		"name":       "invite-" + strings.ToLower(code),
		"expires":    expiresAt.UTC().Format(time.RFC3339),
		"single_use": singleUse,
		"fixed_data": map[string]interface{}{"code": code, "target_group": group},
	}
}

// akInvite is the slice of an authentik Invitation we care about.
type akInvite struct {
	PK        string         `json:"pk"`
	Name      string         `json:"name"`
	Expires   string         `json:"expires"`
	SingleUse bool           `json:"single_use"`
	FixedData map[string]interface{} `json:"fixed_data"`
}

func (i akInvite) code() string {
	if i.FixedData == nil {
		return ""
	}
	c, _ := i.FixedData["code"].(string)
	return c
}
func (i akInvite) group() string {
	if i.FixedData == nil {
		return ""
	}
	g, _ := i.FixedData["target_group"].(string)
	return g
}

// parseInviteList extracts the invites (that carry an invite code) from the
// authentik list envelope {results:[...]}.
func parseInviteList(jsonOut string) ([]akInvite, error) {
	var env struct {
		Results []akInvite `json:"results"`
	}
	if err := json.Unmarshal([]byte(jsonOut), &env); err != nil {
		return nil, fmt.Errorf("parse authentik invitations json: %w", err)
	}
	out := make([]akInvite, 0, len(env.Results))
	for _, i := range env.Results {
		if i.code() != "" {
			out = append(out, i)
		}
	}
	return out, nil
}

// --- authentik API client --------------------------------------------------

type akClient struct {
	base   string
	token  string
	client *http.Client
}

func newAkClient() (*akClient, error) {
	ensureVaultAddr()
	tok, err := kvGetField(realRunner, "secret/authentik", "tf_api_token")
	if err != nil {
		return nil, fmt.Errorf("read authentik API token (vault kv get secret/authentik --field tf_api_token): %w", err)
	}
	tok = strings.TrimSpace(tok)
	if tok == "" {
		return nil, fmt.Errorf("authentik API token (secret/authentik tf_api_token) is empty")
	}
	base := os.Getenv("AUTHENTIK_URL")
	if base == "" {
		base = "https://authentik.viktorbarzin.me"
	}
	return &akClient{base: strings.TrimRight(base, "/") + "/api/v3", token: tok, client: &http.Client{Timeout: 20 * time.Second}}, nil
}

func (c *akClient) do(method, path string, body interface{}) ([]byte, int, error) {
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, 0, err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.base+path, r)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return b, resp.StatusCode, nil
}

func (c *akClient) groupExists(name string) (bool, error) {
	b, code, err := c.do("GET", "/core/groups/?name="+url.QueryEscape(name), nil)
	if err != nil {
		return false, err
	}
	if code != 200 {
		return false, fmt.Errorf("authentik groups query %d: %s", code, strings.TrimSpace(string(b)))
	}
	var env struct {
		Results []struct {
			Name string `json:"name"`
		} `json:"results"`
	}
	if err := json.Unmarshal(b, &env); err != nil {
		return false, err
	}
	for _, g := range env.Results {
		if g.Name == name {
			return true, nil
		}
	}
	return false, nil
}

func (c *akClient) listInvites() ([]akInvite, error) {
	b, code, err := c.do("GET", "/stages/invitation/invitations/?page_size=200", nil)
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("authentik invitations list %d: %s", code, strings.TrimSpace(string(b)))
	}
	return parseInviteList(string(b))
}

func (c *akClient) createInvite(payload map[string]interface{}) error {
	b, code, err := c.do("POST", "/stages/invitation/invitations/", payload)
	if err != nil {
		return err
	}
	if code != 201 {
		return fmt.Errorf("authentik create invitation %d: %s", code, strings.TrimSpace(string(b)))
	}
	return nil
}

func (c *akClient) deleteInvite(pk string) error {
	b, code, err := c.do("DELETE", "/stages/invitation/invitations/"+pk+"/", nil)
	if err != nil {
		return err
	}
	if code != 204 {
		return fmt.Errorf("authentik delete invitation %d: %s", code, strings.TrimSpace(string(b)))
	}
	return nil
}

// --- handlers --------------------------------------------------------------

func inviteCreate(args []string) error {
	var group, expires, label string
	uses := 1
	for i := 0; i < len(args); i++ {
		a := args[i]
		next := func() string {
			if i+1 < len(args) {
				i++
				return args[i]
			}
			return ""
		}
		switch {
		case a == "--group":
			group = next()
		case strings.HasPrefix(a, "--group="):
			group = strings.TrimPrefix(a, "--group=")
		case a == "--expires":
			expires = next()
		case strings.HasPrefix(a, "--expires="):
			expires = strings.TrimPrefix(a, "--expires=")
		case a == "--uses":
			uses, _ = strconv.Atoi(next())
		case strings.HasPrefix(a, "--uses="):
			uses, _ = strconv.Atoi(strings.TrimPrefix(a, "--uses="))
		case a == "--label":
			label = next()
		case strings.HasPrefix(a, "--label="):
			label = strings.TrimPrefix(a, "--label=")
		}
	}
	if group == "" {
		return fmt.Errorf(`usage: homelab invite create --group "<name>" [--uses N] [--expires 7d] [--label who]`)
	}
	if expires == "" {
		expires = "7d"
	}
	dur, err := parseExpiry(expires)
	if err != nil {
		return err
	}
	c, err := newAkClient()
	if err != nil {
		return err
	}
	ok, err := c.groupExists(group)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("authentik group %q does not exist — create it first or check the name", group)
	}
	code, err := genInviteCode()
	if err != nil {
		return err
	}
	payload := buildInvitePayload(code, group, uses == 1, time.Now().Add(dur))
	if label != "" {
		payload["fixed_data"].(map[string]interface{})["label"] = label
	}
	if err := c.createInvite(payload); err != nil {
		return err
	}
	fmt.Printf("invite code: %s\n", code)
	fmt.Printf("  group:     %s\n", group)
	fmt.Printf("  single-use: %v   expires: %s\n", uses == 1, time.Now().Add(dur).Format("2006-01-02 15:04 MST"))
	fmt.Printf("  → share the code; the invitee signs in at any gated service (Google/passkey) and enters it.\n")
	return nil
}

func inviteList(args []string) error {
	c, err := newAkClient()
	if err != nil {
		return err
	}
	invites, err := c.listInvites()
	if err != nil {
		return err
	}
	if len(invites) == 0 {
		fmt.Println("(no outstanding invite codes)")
		return nil
	}
	for _, i := range invites {
		fmt.Printf("%-8s  group=%-20s single-use=%-5v expires=%s\n", i.code(), i.group(), i.SingleUse, i.Expires)
	}
	return nil
}

func inviteRevoke(args []string) error {
	code, _ := firstPositional(args)
	if code == "" {
		return fmt.Errorf("usage: homelab invite revoke <code>")
	}
	c, err := newAkClient()
	if err != nil {
		return err
	}
	invites, err := c.listInvites()
	if err != nil {
		return err
	}
	for _, i := range invites {
		if strings.EqualFold(i.code(), code) {
			if err := c.deleteInvite(i.PK); err != nil {
				return err
			}
			fmt.Printf("revoked invite %s (group %s)\n", i.code(), i.group())
			return nil
		}
	}
	return fmt.Errorf("no outstanding invite with code %q", code)
}
