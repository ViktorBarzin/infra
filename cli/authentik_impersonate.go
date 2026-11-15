package main

// `homelab browser run|open --as <user> --reason <why>`: open a clean browser
// context signed in to Authentik as another user, to see an app the way that
// user sees it.
//
// How: sign in as the agent's own service account svc-agent through
// default-authentication-flow (app password, then a TOTP code), call
// POST /api/v3/core/users/<pk>/impersonate/ with the reason, and hand the
// resulting Authentik session cookies to the browser as its only cookies. Every
// app the browser opens then signs in through Authentik as the target user.
// When the run ends, the session is logged out, which ends the impersonation.
//
// Impersonation is session state in Authentik, so an API token cannot start it;
// that is why this signs in through the flow. Authentik records each start as an
// impersonation_started event carrying the reason. Terraform for the account and
// its role: stacks/authentik/agent-service-account.tf.

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const (
	authentikBaseURL   = "https://authentik.viktorbarzin.me"
	agentCredsVaultKV  = "secret/authentik-agent"
	authFlowSlug       = "default-authentication-flow"
	invalidationFlow   = "default-invalidation-flow"
	totpStep           = 30 * time.Second
	impersonateTimeout = 30 * time.Second
)

// agentCreds is svc-agent's sign-in: username, app password and TOTP secret.
type agentCreds struct {
	Username, Password, TOTPSecret string
}

// readAgentCreds reads svc-agent's credentials from Vault. Values never reach
// a command line or stdout.
func readAgentCreds() (agentCreds, error) {
	cmd := exec.Command("vault", "kv", "get", "-format=json", agentCredsVaultKV)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if i := strings.Index(msg, "\n"); i >= 0 {
			msg = msg[:i]
		}
		return agentCreds{}, fmt.Errorf("cannot read Vault %s (%s). --as needs read on that path, "+
			"which admins hold; run vault login -method=oidc if your token expired", agentCredsVaultKV, msg)
	}
	var v struct {
		Data struct {
			Data map[string]string `json:"data"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &v); err != nil {
		return agentCreds{}, fmt.Errorf("Vault %s: unreadable answer", agentCredsVaultKV)
	}
	c := agentCreds{v.Data.Data["username"], v.Data.Data["app_password"], v.Data.Data["totp_secret"]}
	if c.Username == "" || c.Password == "" || c.TOTPSecret == "" {
		return agentCreds{}, fmt.Errorf("Vault %s must hold username, app_password and totp_secret", agentCredsVaultKV)
	}
	return c, nil
}

// totpCode is the RFC 6238 code (SHA1, 6 digits, 30 s step) for a base32 secret.
func totpCode(secretB32 string, t time.Time) (string, error) {
	s := strings.ToUpper(strings.TrimRight(strings.TrimSpace(secretB32), "="))
	key, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(s)
	if err != nil {
		return "", fmt.Errorf("TOTP secret is not base32: %w", err)
	}
	var msg [8]byte
	binary.BigEndian.PutUint64(msg[:], uint64(t.Unix()/int64(totpStep/time.Second)))
	h := hmac.New(sha1.New, key)
	h.Write(msg[:])
	sum := h.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	n := binary.BigEndian.Uint32(sum[off:off+4]) & 0x7fffffff
	return fmt.Sprintf("%06d", n%1000000), nil
}

type impersonationConfig struct {
	BaseURL string
	Creds   agentCreds
	Target  string // username, email or numeric pk
	Reason  string
	Now     func() time.Time
	Sleep   func(time.Duration)
}

// impersonation is a live Authentik session of svc-agent impersonating a user.
type impersonation struct {
	TargetPK       int
	TargetUsername string

	base   *url.URL
	client *http.Client
}

type flowChallenge struct {
	Component        string `json:"component"`
	DeviceChallenges []struct {
		DeviceClass string `json:"device_class"`
	} `json:"device_challenges"`
	ResponseErrors json.RawMessage `json:"response_errors"`
}

func startImpersonation(cfg impersonationConfig) (*impersonation, error) {
	if strings.TrimSpace(cfg.Reason) == "" {
		return nil, errors.New("--as needs --reason: Authentik records it with the impersonation")
	}
	if cfg.Target == "" {
		return nil, errors.New("--as needs a user")
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Sleep == nil {
		cfg.Sleep = time.Sleep
	}
	base, err := url.Parse(strings.TrimRight(cfg.BaseURL, "/"))
	if err != nil {
		return nil, err
	}
	jar, _ := cookiejar.New(nil)
	im := &impersonation{base: base, client: &http.Client{Jar: jar, Timeout: impersonateTimeout}}

	if err := im.login(cfg); err != nil {
		return nil, err
	}
	pk, username, err := im.resolveUser(cfg.Target)
	if err != nil {
		_ = im.End()
		return nil, err
	}
	if err := im.impersonate(pk, cfg.Reason); err != nil {
		_ = im.End()
		return nil, err
	}
	who, orig, err := im.me()
	if err != nil {
		_ = im.End()
		return nil, err
	}
	if orig != cfg.Creds.Username || (username != "" && who != username) {
		_ = im.End()
		return nil, fmt.Errorf("after impersonate Authentik reports user %q (original %q), want %q as %q", who, orig, username, cfg.Creds.Username)
	}
	im.TargetPK, im.TargetUsername = pk, who
	return im, nil
}

func (im *impersonation) url(path string) string { return im.base.String() + path }

func (im *impersonation) do(method, path string, body any) (*http.Response, []byte, error) {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, nil, err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, im.url(path), rd)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Origin", im.base.String())
	req.Header.Set("Referer", im.base.String()+"/")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if method != http.MethodGet {
		if c := im.cookie("authentik_csrf"); c != "" {
			req.Header.Set("X-authentik-CSRF", c)
		}
	}
	resp, err := im.client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp, b, err
}

func (im *impersonation) cookie(name string) string {
	for _, c := range im.client.Jar.Cookies(im.base) {
		if c.Name == name {
			return c.Value
		}
	}
	return ""
}

func (im *impersonation) flow(method string, body any) (flowChallenge, error) {
	path := "/api/v3/flows/executor/" + authFlowSlug + "/?query=" + url.QueryEscape("next=/")
	resp, b, err := im.do(method, path, body)
	if err != nil {
		return flowChallenge{}, err
	}
	var ch flowChallenge
	if resp.StatusCode != http.StatusOK || json.Unmarshal(b, &ch) != nil {
		return flowChallenge{}, fmt.Errorf("authentication flow answered HTTP %d", resp.StatusCode)
	}
	return ch, nil
}

// login signs in as svc-agent. One identification post with the embedded
// password, then the TOTP code. A code Authentik already accepted in this
// 30 s step is refused (another login just used it), so a refused code gets
// one retry with the next step's code.
func (im *impersonation) login(cfg impersonationConfig) error {
	if _, err := im.flow(http.MethodGet, nil); err != nil {
		return err
	}
	ch, err := im.flow(http.MethodPost, map[string]string{
		"component": "ak-stage-identification", "uid_field": cfg.Creds.Username, "password": cfg.Creds.Password,
	})
	if err != nil {
		return err
	}
	for attempt := 0; ; attempt++ {
		switch ch.Component {
		case "xak-flow-redirect":
			return nil
		case "ak-stage-identification", "ak-stage-password":
			return fmt.Errorf("Authentik refused %s's password (Vault %s app_password)", cfg.Creds.Username, agentCredsVaultKV)
		case "ak-stage-authenticator-validate":
			hasTOTP := false
			for _, d := range ch.DeviceChallenges {
				hasTOTP = hasTOTP || d.DeviceClass == "totp"
			}
			if !hasTOTP {
				return fmt.Errorf("Authentik offers %s no TOTP device; re-create it (docs/architecture/authentication.md, Agent impersonation)", cfg.Creds.Username)
			}
			if attempt == 2 {
				return fmt.Errorf("Authentik refused two TOTP codes for %s; check the device against Vault %s totp_secret", cfg.Creds.Username, agentCredsVaultKV)
			}
			if attempt == 1 {
				now := cfg.Now()
				step := int64(totpStep / time.Second)
				cfg.Sleep(time.Duration(step-now.Unix()%step)*time.Second + time.Second)
			}
			code, err := totpCode(cfg.Creds.TOTPSecret, cfg.Now())
			if err != nil {
				return err
			}
			if ch, err = im.flow(http.MethodPost, map[string]string{
				"component": "ak-stage-authenticator-validate", "code": code,
			}); err != nil {
				return err
			}
		default:
			return fmt.Errorf("sign-in as %s stopped at Authentik stage %q", cfg.Creds.Username, ch.Component)
		}
	}
}

// resolveUser finds the target by pk, username, then email.
func (im *impersonation) resolveUser(target string) (int, string, error) {
	if pk, err := strconv.Atoi(target); err == nil {
		return pk, "", nil
	}
	for _, field := range []string{"username", "email"} {
		resp, b, err := im.do(http.MethodGet, "/api/v3/core/users/?"+field+"="+url.QueryEscape(target), nil)
		if err != nil {
			return 0, "", err
		}
		if resp.StatusCode != http.StatusOK {
			return 0, "", fmt.Errorf("listing Authentik users answered HTTP %d", resp.StatusCode)
		}
		var v struct {
			Results []struct {
				PK       int    `json:"pk"`
				Username string `json:"username"`
			} `json:"results"`
		}
		if err := json.Unmarshal(b, &v); err != nil {
			return 0, "", err
		}
		if len(v.Results) == 1 {
			return v.Results[0].PK, v.Results[0].Username, nil
		}
		if len(v.Results) > 1 {
			return 0, "", fmt.Errorf("%d Authentik users match %s %q; pass the pk", len(v.Results), field, target)
		}
	}
	return 0, "", fmt.Errorf("no Authentik user with username or email %q (usernames are often the email address)", target)
}

func (im *impersonation) impersonate(pk int, reason string) error {
	resp, b, err := im.do(http.MethodPost, fmt.Sprintf("/api/v3/core/users/%d/impersonate/", pk), map[string]string{"reason": reason})
	if err != nil {
		return err
	}
	switch resp.StatusCode {
	case http.StatusNoContent, http.StatusOK:
		return nil
	case http.StatusForbidden:
		return errors.New("Authentik denied impersonation (HTTP 403): svc-agent may impersonate only members of the Authentik group \"Agent impersonatable\" (stacks/authentik/agent-service-account.tf)")
	case http.StatusUnauthorized:
		return errors.New("Authentik refused impersonation (HTTP 401): impersonation is off in system settings, or the target is svc-agent itself")
	default:
		return fmt.Errorf("impersonate answered HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
}

// me returns the session's user and, while impersonating, the original user.
func (im *impersonation) me() (user, original string, err error) {
	resp, b, err := im.do(http.MethodGet, "/api/v3/core/users/me/", nil)
	if err != nil {
		return "", "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("users/me answered HTTP %d", resp.StatusCode)
	}
	var v struct {
		User struct {
			Username string `json:"username"`
		} `json:"user"`
		Original *struct {
			Username string `json:"username"`
		} `json:"original"`
	}
	if err := json.Unmarshal(b, &v); err != nil {
		return "", "", err
	}
	if v.Original != nil {
		original = v.Original.Username
	}
	return v.User.Username, original, nil
}

// pwCookie is a cookie in Playwright's shape, as addCookies and storage state take it.
type pwCookie struct {
	Name     string  `json:"name"`
	Value    string  `json:"value"`
	Domain   string  `json:"domain"`
	Path     string  `json:"path"`
	Expires  float64 `json:"expires"`
	HTTPOnly bool    `json:"httpOnly"`
	Secure   bool    `json:"secure"`
	SameSite string  `json:"sameSite"`
}

// cookies is the session's Authentik cookies in Playwright's shape.
func (im *impersonation) cookies() []pwCookie {
	out := []pwCookie{}
	for _, c := range im.client.Jar.Cookies(im.base) {
		out = append(out, pwCookie{
			Name: c.Name, Value: c.Value, Domain: im.base.Hostname(), Path: "/", Expires: -1,
			// The Authentik UI reads authentik_csrf from document.cookie.
			HTTPOnly: c.Name != "authentik_csrf",
			Secure:   im.base.Scheme == "https", SameSite: "Lax",
		})
	}
	return out
}

// WriteStorageState writes the session as a Playwright storage state, mode
// 0600: the Authentik cookies and nothing else.
func (im *impersonation) WriteStorageState(path string) error {
	state := struct {
		Cookies []pwCookie `json:"cookies"`
		Origins []any      `json:"origins"`
	}{Cookies: im.cookies(), Origins: []any{}}
	b, err := json.Marshal(state)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// End logs the session out through the invalidation flow, which ends the
// impersonation with it, and checks that the session no longer authenticates.
func (im *impersonation) End() error {
	if _, _, err := im.do(http.MethodGet, "/api/v3/flows/executor/"+invalidationFlow+"/?query=", nil); err != nil {
		return err
	}
	resp, _, err := im.do(http.MethodGet, "/api/v3/core/users/me/", nil)
	if err != nil {
		return err
	}
	if resp.StatusCode == http.StatusOK {
		return errors.New("the Authentik session still authenticates after logout")
	}
	return nil
}

// startBrowserImpersonation starts the impersonation for a browser run and
// returns the storage state file the runner seeds its fresh context from.
// Teardowns run in reverse, so the logout runs after the browser has closed
// and the file is removed after that.
func startBrowserImpersonation(o browserOpts, addTeardown func(func())) (string, error) {
	creds, err := readAgentCreds()
	if err != nil {
		return "", err
	}
	im, err := startImpersonation(impersonationConfig{
		BaseURL: authentikBaseURL, Creds: creds, Target: o.asUser, Reason: o.asReason,
	})
	if err != nil {
		return "", fmt.Errorf("--as %s: %w", o.asUser, err)
	}
	path := fmt.Sprintf("%s/homelab-browser-as-%d.json", os.TempDir(), os.Getpid())
	addTeardown(func() { _ = os.Remove(path) })
	addTeardown(func() {
		if err := im.End(); err != nil {
			fmt.Fprintf(os.Stderr, "homelab browser: could not end the impersonation of %s: %v\n"+
				"  end it in the Authentik admin UI, Directory > Users > %s > Sessions\n", im.TargetUsername, err, im.TargetUsername)
			return
		}
		fmt.Fprintf(os.Stderr, "homelab browser: impersonation of %s ended, session logged out\n", im.TargetUsername)
	})
	if err := im.WriteStorageState(path); err != nil {
		return "", err
	}
	fmt.Fprintf(os.Stderr, "homelab browser: signed in as %s, impersonating %s (pk %d); reason recorded in Authentik\n",
		creds.Username, im.TargetUsername, im.TargetPK)
	return path, nil
}
