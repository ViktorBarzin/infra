package main

import (
	"encoding/json"
	"fmt"
	"path"
	"strconv"
	"strings"
	"time"
)

// nextcloudHost is where shares are minted. Kept here rather than in a flag:
// the point of the verb is that there is one obvious place for this.
const nextcloudHost = "https://nextcloud.viktorbarzin.me"

// shareUploadDir keeps agent uploads in one place, so they are easy to find and
// prune and never collide with a user's own files.
const shareUploadDir = "/_share/"

// defaultShareExpireDays matches the TTL the visualize skill already uses for
// Nextcloud public links.
const defaultShareExpireDays = 30

// nextcloudCredCandidates lists the Vault paths to try, in order, for the
// calling user's Nextcloud credential. Every user reads their own tree
// (`personal-<user>` already grants that, so no policy change is needed);
// wizard additionally falls back to the admin credential that predates this
// verb so it works with no setup.
func nextcloudCredCandidates(user string) []string {
	paths := []string{"secret/" + user + "/nextcloud"}
	if user == "wizard" {
		paths = append(paths, "secret/nextcloud/caldav")
	}
	return paths
}

// remoteSharePath builds the destination path inside Nextcloud. The name is
// flattened to its base and prefixed with a stamp, so a repeated upload of the
// same filename does not overwrite the previous share and a caller-supplied
// path can never escape the upload directory.
func remoteSharePath(localName, stamp string) string {
	base := path.Base(strings.ReplaceAll(localName, "\\", "/"))
	base = strings.TrimLeft(base, ".")
	if base == "" || base == "/" {
		base = "file"
	}
	return shareUploadDir + stamp + "-" + base
}

// ocsShareResponse is the envelope every OCS endpoint returns.
type ocsShareResponse struct {
	OCS struct {
		Meta struct {
			Status     string `json:"status"`
			StatusCode int    `json:"statuscode"`
			Message    string `json:"message"`
		} `json:"meta"`
		Data struct {
			ID         string `json:"id"`
			URL        string `json:"url"`
			Expiration string `json:"expiration"`
		} `json:"data"`
	} `json:"ocs"`
}

// parseOCSShare pulls the public URL out of a share-creation response, turning
// an OCS-level failure into an error rather than an empty URL.
func parseOCSShare(body string) (url, expiration string, err error) {
	var r ocsShareResponse
	if e := json.Unmarshal([]byte(body), &r); e != nil {
		return "", "", fmt.Errorf("unexpected response from Nextcloud (not OCS JSON): %s", truncateForError(body))
	}
	if r.OCS.Meta.Status != "ok" {
		msg := r.OCS.Meta.Message
		if msg == "" {
			msg = fmt.Sprintf("status %d", r.OCS.Meta.StatusCode)
		}
		return "", "", fmt.Errorf("Nextcloud refused the share: %s", msg)
	}
	if r.OCS.Data.URL == "" {
		return "", "", fmt.Errorf("Nextcloud returned no share URL")
	}
	return r.OCS.Data.URL, r.OCS.Data.Expiration, nil
}

// truncateForError keeps an unexpected response readable in an error message.
func truncateForError(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > 120 {
		return s[:120] + "…"
	}
	return s
}

// ocsExpireDate renders the expiry the OCS API expects (YYYY-MM-DD).
func ocsExpireDate(now time.Time, days int) string {
	return now.AddDate(0, 0, days).Format("2006-01-02")
}

type shareArgs struct {
	path       string
	expireDays int
	force      bool
}

func parseShareArgs(args []string) (shareArgs, error) {
	out := shareArgs{expireDays: defaultShareExpireDays}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--force":
			out.force = true
		case a == "--expire" && i+1 < len(args):
			d, err := strconv.Atoi(args[i+1])
			if err != nil {
				return out, fmt.Errorf("--expire wants a number of days, got %q", args[i+1])
			}
			out.expireDays = d
			i++
		case !strings.HasPrefix(a, "-") && out.path == "":
			out.path = a
		}
	}
	if out.path == "" {
		return out, fmt.Errorf("usage: homelab share <file> [--expire DAYS] [--force]")
	}
	return out, nil
}
