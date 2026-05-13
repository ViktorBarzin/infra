package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

const listenAddr = "0.0.0.0:7684"

var sessionNameRe = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,32}$`)

type Session struct {
	Name         string `json:"name"`
	Attached     int    `json:"attached"`
	LastActivity int64  `json:"lastActivity"`
	Created      int64  `json:"created"`
}

func main() {
	http.HandleFunc("/sessions", handleSessions)
	http.HandleFunc("/sessions/", handleSessionByName)
	http.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok"))
	})

	log.Printf("tmux-api listening on %s", listenAddr)
	log.Fatal(http.ListenAndServe(listenAddr, nil))
}

func handleSessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}

	out, err := exec.Command(
		"tmux", "list-sessions", "-F",
		"#{session_name}|#{session_attached}|#{session_activity}|#{session_created}",
	).Output()

	w.Header().Set("Content-Type", "application/json")

	// tmux exits non-zero when no server is running or no sessions exist.
	// Treat both as "empty list" rather than a 500.
	if err != nil {
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

	out, err := exec.Command("tmux", "kill-session", "-t", name).CombinedOutput()
	if err != nil {
		msg := string(out)
		if strings.Contains(msg, "can't find session") || strings.Contains(msg, "no server running") {
			http.Error(w, "session not found", http.StatusNotFound)
			return
		}
		log.Printf("kill-session %s failed: %v: %s", name, err, msg)
		http.Error(w, "kill-session failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
