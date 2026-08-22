package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

func shareCommands() []Command {
	return []Command{
		{Path: []string{"share"}, Tier: TierWrite,
			Summary: "share a file as an expiring Nextcloud link: share <file> [--expire DAYS] [--force]", Run: shareFile},
	}
}

// nextcloudCreds resolves the caller's Nextcloud username + app password from
// Vault, trying their own tree first. Returns a setup hint rather than a raw
// Vault error when nothing is configured, since that is the common case for a
// user who has not set this up yet.
func nextcloudCreds() (user, pass string, err error) {
	ensureVaultAddr() // the caller's own token, like `homelab vault kv`
	me := currentUser()
	var tried []string
	for _, p := range nextcloudCredCandidates(me) {
		tried = append(tried, p)
		u, uErr := kvGetField(realRunner, p, "username")
		pw, pErr := kvGetField(realRunner, p, "app_password")
		if uErr == nil && pErr == nil && strings.TrimSpace(u) != "" && strings.TrimSpace(pw) != "" {
			return strings.TrimSpace(u), strings.TrimSpace(pw), nil
		}
	}
	return "", "", fmt.Errorf("no Nextcloud credential found (looked in %s).\n"+
		"Set one up once with:\n"+
		"  printf '%%s' '<your-nextcloud-username>' | homelab vault kv put %s username\n"+
		"  printf '%%s' '<app-password>' | homelab vault kv put %s app_password\n"+
		"Create the app password in Nextcloud under Settings → Security → Devices & sessions.",
		strings.Join(tried, ", "), tried[0], tried[0])
}

func shareFile(args []string) error {
	opts, err := parseShareArgs(args)
	if err != nil {
		return err
	}
	content, err := os.ReadFile(opts.path)
	if err != nil {
		return fmt.Errorf("cannot read %s: %w", opts.path, err)
	}
	if err := guardContent(gitleaksScan, content, opts.force, "share"); err != nil {
		return err
	}
	user, pass, err := nextcloudCreds()
	if err != nil {
		return err
	}

	remote := remoteSharePath(opts.path, time.Now().Format("20060102-150405"))
	if err := webdavPut(user, pass, remote, content); err != nil {
		return err
	}
	link, expiration, err := createPublicShare(user, pass, remote, opts.expireDays)
	if err != nil {
		return err
	}
	fmt.Println(link)
	if expiration != "" {
		fmt.Fprintf(os.Stderr, "expires %s\n", expiration)
	}
	return nil
}

// webdavPut uploads the content to the caller's Nextcloud files tree, creating
// the upload directory first (MKCOL is idempotent enough here — an existing
// directory answers 405, which is not an error for our purposes).
func webdavPut(user, pass, remote string, content []byte) error {
	base := nextcloudHost + "/remote.php/dav/files/" + url.PathEscape(user)

	mk, _ := http.NewRequest("MKCOL", base+strings.TrimSuffix(shareUploadDir, "/"), nil)
	mk.SetBasicAuth(user, pass)
	mk.Header.Set("User-Agent", homelabUserAgent())
	if resp, err := http.DefaultClient.Do(mk); err == nil {
		resp.Body.Close()
	}

	req, err := http.NewRequest("PUT", base+encodePath(remote), bytes.NewReader(content))
	if err != nil {
		return err
	}
	req.SetBasicAuth(user, pass)
	req.Header.Set("User-Agent", homelabUserAgent())
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("upload to Nextcloud failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		if resp.StatusCode == 401 {
			return fmt.Errorf("Nextcloud rejected the credential (401) — is the app password still valid?")
		}
		return fmt.Errorf("upload failed: %s %s", resp.Status, truncateForError(string(body)))
	}
	return nil
}

// encodePath percent-encodes each path segment, leaving the separators intact.
func encodePath(p string) string {
	parts := strings.Split(p, "/")
	for i, s := range parts {
		parts[i] = url.PathEscape(s)
	}
	return strings.Join(parts, "/")
}

// createPublicShare mints a read-only public link. expireDays <= 0 creates a
// link with no expiry, which the caller has to ask for explicitly.
func createPublicShare(user, pass, remote string, expireDays int) (link, expiration string, err error) {
	form := url.Values{}
	form.Set("path", remote)
	form.Set("shareType", "3") // public link
	form.Set("permissions", "1")
	if expireDays > 0 {
		form.Set("expireDate", ocsExpireDate(time.Now(), expireDays))
	}
	endpoint := nextcloudHost + "/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json"
	req, err := http.NewRequest("POST", endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return "", "", err
	}
	req.SetBasicAuth(user, pass)
	req.Header.Set("OCS-APIRequest", "true")
	req.Header.Set("User-Agent", homelabUserAgent())
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("creating the share failed: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	return parseOCSShare(string(body))
}
