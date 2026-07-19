package real_ip_plugin

import (
	"context"
	"net"
	"net/http"
	"strings"
)

// Config is the plugin configuration.
type Config struct {
	// TrustedProxyCIDRs lists the peer networks (matched against the real TCP
	// peer, req.RemoteAddr) whose client-supplied X-Forwarded-For /
	// Cf-Connecting-Ip headers are trusted. Any other peer is treated as the
	// real client itself and ALL of its forwarding headers are ignored, so a
	// client cannot spoof X-Real-Ip by sending its own headers.
	TrustedProxyCIDRs []string `json:"trustedProxyCIDRs,omitempty" yaml:"trustedProxyCIDRs,omitempty"`
}

// CreateConfig defaults the trusted set to the in-cluster pod CIDR where the
// cloudflared proxies run.
func CreateConfig() *Config {
	return &Config{TrustedProxyCIDRs: []string{"10.10.0.0/16"}}
}

type RealIP struct {
	next        http.Handler
	name        string
	trustedNets []*net.IPNet
}

func New(ctx context.Context, next http.Handler, cfg *Config, name string) (http.Handler, error) {
	var trustedNets []*net.IPNet
	for _, c := range cfg.TrustedProxyCIDRs {
		c = strings.TrimSpace(c)
		if c == "" {
			continue
		}
		// Fail loud on a malformed CIDR rather than silently ignoring it.
		_, ipNet, err := net.ParseCIDR(c)
		if err != nil {
			return nil, err
		}
		trustedNets = append(trustedNets, ipNet)
	}
	// Never become trust-everything: an empty parsed list falls back to the
	// in-cluster pod CIDR.
	if len(trustedNets) == 0 {
		_, ipNet, _ := net.ParseCIDR("10.10.0.0/16")
		trustedNets = append(trustedNets, ipNet)
	}
	return &RealIP{next: next, name: name, trustedNets: trustedNets}, nil
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
	// The real TCP peer is unspoofable; trust is decided by it, not by headers.
	host, _, err := net.SplitHostPort(req.RemoteAddr)
	if err != nil {
		host = req.RemoteAddr
	}
	peerIP := net.ParseIP(strings.TrimSpace(host))

	trusted := false
	if peerIP != nil {
		for _, n := range r.trustedNets {
			if n.Contains(peerIP) {
				trusted = true
				break
			}
		}
	}

	if trusted {
		// Genuine in-cluster proxy (cloudflared): the real client is in the
		// CF / XFF headers it set.
		if cf := strings.TrimSpace(req.Header.Get("Cf-Connecting-Ip")); isPublic(cf) {
			req.Header.Set("X-Real-Ip", cf)
			r.next.ServeHTTP(rw, req)
			return
		}
		// No usable CF header: first public X-Forwarded-For entry.
		for _, part := range strings.Split(strings.Join(req.Header.Values("X-Forwarded-For"), ","), ",") {
			if isPublic(part) {
				req.Header.Set("X-Real-Ip", strings.TrimSpace(part))
				r.next.ServeHTTP(rw, req)
				return
			}
		}
		// Trusted peer but no usable header: fall back to the peer itself.
		if peerIP != nil {
			req.Header.Set("X-Real-Ip", host)
		}
	} else {
		// Untrusted peer = the real client itself (pfSense PROXY-protocol
		// rewrote RemoteAddr, or direct/internal). Ignore ALL client-supplied
		// headers to prevent spoofing.
		if peerIP != nil {
			req.Header.Set("X-Real-Ip", host)
		}
		// peerIP == nil (shouldn't happen): leave X-Real-Ip untouched.
	}
	r.next.ServeHTTP(rw, req)
}
