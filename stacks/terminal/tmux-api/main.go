package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"regexp"
	"strconv"
	"strings"
)

const (
	listenAddr   = "0.0.0.0:7684"
	mapPath      = "/etc/ttyd-user-map"
	authHeader   = "X-Authentik-Username"
	tmuxBinary   = "/usr/bin/tmux"
	sudoBinary   = "/usr/bin/sudo"
	tmuxListFmt  = "#{session_name}|#{session_attached}|#{session_activity}|#{session_created}"
)

var sessionNameRe = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,32}$`)

var selfUser = func() string {
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return ""
}()

type Session struct {
	Name         string `json:"name"`
	Attached     int    `json:"attached"`
	LastActivity int64  `json:"lastActivity"`
	Created      int64  `json:"created"`
}

// loadUserMap reads /etc/ttyd-user-map → map[authentik_local]os_user.
// Format: "<auth>=<os_user>[:<cwd>]" per line. Comments (#) and blanks ignored.
// Re-read on every request — file is small and changes are rare.
func loadUserMap() map[string]string {
	m := map[string]string{}
	f, err := os.Open(mapPath)
	if err != nil {
		log.Printf("loadUserMap: %v", err)
		return m
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			continue
		}
		auth := strings.TrimSpace(line[:eq])
		rhs := strings.TrimSpace(line[eq+1:])
		if c := strings.IndexByte(rhs, ':'); c > 0 {
			rhs = rhs[:c]
		}
		if auth != "" && rhs != "" {
			m[auth] = rhs
		}
	}
	return m
}

// resolveOSUser → mapped OS user from the Authentik header, or "" after
// writing the appropriate 401/403/500 to w.
func resolveOSUser(w http.ResponseWriter, r *http.Request) string {
	authUser := r.Header.Get(authHeader)
	if authUser == "" {
		http.Error(w, "missing "+authHeader, http.StatusUnauthorized)
		return ""
	}
	local := authUser
	if i := strings.IndexByte(local, '@'); i > 0 {
		local = local[:i]
	}
	osUser := loadUserMap()[local]
	if osUser == "" {
		http.Error(w, fmt.Sprintf("no terminal account for '%s'", authUser), http.StatusForbidden)
		return ""
	}
	if _, err := user.Lookup(osUser); err != nil {
		log.Printf("mapped OS user %q missing on this host: %v", osUser, err)
		http.Error(w, "mapped OS user missing on this host", http.StatusInternalServerError)
		return ""
	}
	return osUser
}

// tmuxCmd builds an exec.Cmd that runs `tmux <args...>` AS osUser. When
// osUser is the current process owner, sudo is skipped; otherwise we use
// `sudo -n -u <user> tmux ...` (passwordless grant via /etc/sudoers.d/ttyd-users).
func tmuxCmd(osUser string, args ...string) *exec.Cmd {
	if osUser == selfUser {
		return exec.Command(tmuxBinary, args...)
	}
	full := append([]string{"-n", "-u", osUser, tmuxBinary}, args...)
	return exec.Command(sudoBinary, full...)
}

func main() {
	http.HandleFunc("/sessions", handleSessions)
	http.HandleFunc("/sessions/", handleSessionByName)
	http.HandleFunc("/whoami", handleWhoami)
	http.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok"))
	})

	log.Printf("tmux-api listening on %s (self=%s)", listenAddr, selfUser)
	log.Fatal(http.ListenAndServe(listenAddr, nil))
}

// /whoami → {authentik, osUser}. Used by the lobby HTML to render the
// current identity and to preflight access before opening a session.
func handleWhoami(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	authUser := r.Header.Get(authHeader)
	osUser := resolveOSUser(w, r)
	if osUser == "" {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"authentik": authUser,
		"osUser":    osUser,
	})
}

func handleSessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	osUser := resolveOSUser(w, r)
	if osUser == "" {
		return
	}

	out, err := tmuxCmd(osUser, "list-sessions", "-F", tmuxListFmt).Output()
	w.Header().Set("Content-Type", "application/json")
	if err != nil {
		// tmux exits non-zero when no server is running or there are no
		// sessions for this uid — treat both as an empty list.
		w.Write([]byte("[]"))
		return
	}

	sessions := make([]Session, 0)
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if line == "" {
			continue
		}
		parts := strings.Split(line, "|")
		if len(parts) != 4 {
			continue
		}
		attached, _ := strconv.Atoi(parts[1])
		activity, _ := strconv.ParseInt(parts[2], 10, 64)
		created, _ := strconv.ParseInt(parts[3], 10, 64)
		sessions = append(sessions, Session{
			Name:         parts[0],
			Attached:     attached,
			LastActivity: activity,
			Created:      created,
		})
	}
	json.NewEncoder(w).Encode(sessions)
}

func handleSessionByName(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/sessions/")
	name = strings.TrimSuffix(name, "/")
	if !sessionNameRe.MatchString(name) {
		http.Error(w, "invalid session name", http.StatusBadRequest)
		return
	}
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	osUser := resolveOSUser(w, r)
	if osUser == "" {
		return
	}

	out, err := tmuxCmd(osUser, "kill-session", "-t", name).CombinedOutput()
	if err != nil {
		msg := string(out)
		if strings.Contains(msg, "can't find session") || strings.Contains(msg, "no server running") {
			http.Error(w, "session not found", http.StatusNotFound)
			return
		}
		log.Printf("kill-session %s as %s failed: %v: %s", name, osUser, err, msg)
		http.Error(w, "kill-session failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
