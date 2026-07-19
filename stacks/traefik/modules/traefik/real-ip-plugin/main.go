package real_ip_plugin

import (
	"context"
	"net"
	"net/http"
	"strings"
)

type Config struct{}

func CreateConfig() *Config { return &Config{} }

type RealIP struct {
	next http.Handler
	name string
}

func New(ctx context.Context, next http.Handler, cfg *Config, name string) (http.Handler, error) {
	return &RealIP{next: next, name: name}, nil
}

func isPublic(ip string) bool {
	p := net.ParseIP(strings.TrimSpace(ip))
	if p == nil || !p.IsGlobalUnicast() || p.IsPrivate() {
		return false
	}
	// exclude CGNAT 100.64.0.0/10 (global-unicast but not real client space)
	if p4 := p.To4(); p4 != nil && p4[0] == 100 && p4[1]&0xC0 == 64 {
		return false
	}
	return true
}

func (r *RealIP) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	if cf := strings.TrimSpace(req.Header.Get("Cf-Connecting-Ip")); isPublic(cf) {
		req.Header.Set("X-Real-Ip", cf)
	} else if xff := strings.Join(req.Header.Values("X-Forwarded-For"), ","); xff != "" {
		for _, part := range strings.Split(xff, ",") {
			if isPublic(part) {
				req.Header.Set("X-Real-Ip", strings.TrimSpace(part))
				break
			}
		}
	}
	r.next.ServeHTTP(rw, req)
}
