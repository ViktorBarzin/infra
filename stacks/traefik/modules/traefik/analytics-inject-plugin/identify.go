package analytics_inject_plugin

import (
	"errors"
	"net/http"
	"strings"
)

const (
	defaultIdentifyHeader     = "X-authentik-uid"
	defaultIdentifyStorageKey = "rybbit-user-id"
	maxUserIDLen              = 128
)

// Identifier answers a request for the identify script. It sits behind
// forward auth, which puts the signed-in user's id in a request header. The
// script stores that id under the key the Rybbit script reads at start, so
// the pageviews and replay that follow carry it as the identified user.
// It never calls the next handler.
type Identifier struct {
	header     string
	storageKey string
}

func newIdentifier(cfg *Config) (http.Handler, error) {
	header := strings.TrimSpace(cfg.IdentifyHeader)
	if header == "" {
		header = defaultIdentifyHeader
	}
	key := strings.TrimSpace(cfg.IdentifyStorageKey)
	if key == "" {
		key = defaultIdentifyStorageKey
	}
	if !safeID(key) {
		return nil, errors.New("analytics-inject: identifyStorageKey may hold only letters, digits and . _ @ -")
	}
	return &Identifier{header: header, storageKey: key}, nil
}

func (p *Identifier) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet && req.Method != http.MethodHead {
		rw.Header().Set("Allow", "GET, HEAD")
		http.Error(rw, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	h := rw.Header()
	h.Set("Content-Type", "text/javascript; charset=utf-8")
	// The body names one user: no shared cache may keep it.
	h.Set("Cache-Control", "no-store, private")
	h.Set("X-Content-Type-Options", "nosniff")
	rw.WriteHeader(http.StatusOK)
	if req.Method == http.MethodHead {
		return
	}
	// No id (the forward-auth break-glass fallback sends none) or an id with
	// characters outside the safe set: leave the stored id as it is.
	body := "/* no user */\n"
	if id := strings.TrimSpace(req.Header.Get(p.header)); safeID(id) {
		body = `try{localStorage.setItem("` + p.storageKey + `","` + id + `")}catch(e){}` + "\n"
	}
	_, _ = rw.Write([]byte(body))
}

// safeID accepts 1 to 128 ASCII letters, digits, '.', '_', '@' and '-', so the
// value can sit inside a JavaScript string literal without escaping.
// Authentik's uid is 64 hex digits.
func safeID(s string) bool {
	if s == "" || len(s) > maxUserIDLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == '.' || c == '_' || c == '@' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}
