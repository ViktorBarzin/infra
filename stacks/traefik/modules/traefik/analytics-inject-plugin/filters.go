package analytics_inject_plugin

import (
	"bytes"
	"fmt"
	"net/http"
	"strings"
)

// optOutHeader is the response header a first-party app sends when it loads
// Rybbit itself. "X-Analytics: sdk" stops injection; the header is removed
// from every response this plugin wraps.
const optOutHeader = "X-Analytics"

// hostMatcher matches host names against exact names and "*.suffix" patterns.
type hostMatcher struct {
	exact    map[string]bool
	suffixes []string // ".example.com" for "*.example.com"
}

// newHostMatcher validates and compiles patterns. A pattern is a host name
// (letters, digits, '-', '_', '.') or "*." followed by one. "*.example.com"
// matches subdomains of example.com, not example.com itself.
func newHostMatcher(patterns []string) (*hostMatcher, error) {
	m := &hostMatcher{exact: map[string]bool{}}
	for _, raw := range patterns {
		p := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(raw)), ".")
		if strings.HasPrefix(p, "*.") {
			rest := p[2:]
			if !validHostName(rest) {
				return nil, fmt.Errorf("invalid host pattern %q", raw)
			}
			m.suffixes = append(m.suffixes, "."+rest)
			continue
		}
		if !validHostName(p) {
			return nil, fmt.Errorf("invalid host pattern %q", raw)
		}
		m.exact[p] = true
	}
	return m, nil
}

func validHostName(s string) bool {
	if s == "" || s[0] == '.' || s[len(s)-1] == '.' || strings.Contains(s, "..") {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') && c != '-' && c != '_' && c != '.' {
			return false
		}
	}
	return true
}

func (m *hostMatcher) empty() bool {
	return len(m.exact) == 0 && len(m.suffixes) == 0
}

// match takes a host already passed through normalizeHost.
func (m *hostMatcher) match(host string) bool {
	if host == "" {
		return false
	}
	if m.exact[host] {
		return true
	}
	for _, s := range m.suffixes {
		if len(host) > len(s) && strings.HasSuffix(host, s) {
			return true
		}
	}
	return false
}

// normalizeHost lower-cases a Host header value and drops its port, IPv6
// brackets and trailing dot.
func normalizeHost(h string) string {
	h = strings.TrimSpace(h)
	if strings.HasPrefix(h, "[") {
		if end := strings.IndexByte(h, ']'); end > 0 {
			h = h[1:end]
		}
	} else if strings.Count(h, ":") == 1 {
		h = h[:strings.IndexByte(h, ':')]
	}
	return strings.TrimSuffix(strings.ToLower(h), ".")
}

// hostEligible applies excludeHosts, then includeHosts when it is set.
func (p *Injector) hostEligible(req *http.Request) bool {
	raw := req.Host
	if raw == "" && req.URL != nil {
		raw = req.URL.Host
	}
	host := normalizeHost(raw)
	if p.exclude.match(host) {
		return false
	}
	if !p.include.empty() && !p.include.match(host) {
		return false
	}
	return true
}

// Patterns for the name attribute of the opt-out meta tag. Found with
// bytes.Index (native under Yaegi); the loop below runs once per occurrence of
// name="analytics", which a page holds at most a few times.
var optOutNamePatterns = func() [][]byte {
	var out [][]byte
	for _, attr := range []string{"name=", "NAME=", "Name="} {
		for _, v := range []string{`"analytics"`, `'analytics'`, `analytics`} {
			out = append(out, []byte(attr+v))
		}
	}
	return out
}()

// hasOptOutMeta reports whether b holds <meta name="analytics" content="sdk">,
// in either attribute order, with double, single or no quotes, and any case
// for the tag name and the value.
func hasOptOutMeta(b []byte) bool {
	for _, pat := range optOutNamePatterns {
		off := 0
		for {
			k := bytes.Index(b[off:], pat)
			if k < 0 {
				break
			}
			k += off
			off = k + 1
			end := k + len(pat)
			// "name=analytics" unquoted must end there; any name must be a
			// whole attribute, not the tail of "data-name".
			if q := pat[len(pat)-1]; q != '"' && q != '\'' && !isAttrEnd(b, end) {
				continue
			}
			if k == 0 || !isSpace(b[k-1]) {
				continue
			}
			if tag := enclosingTag(b, k); isMetaTag(tag) && contentIsSDK(tag) {
				return true
			}
		}
	}
	return false
}

// enclosingTag returns the "<...>" tag that contains offset k, or nil.
func enclosingTag(b []byte, k int) []byte {
	lt := bytes.LastIndexByte(b[:k], '<')
	if lt < 0 || bytes.IndexByte(b[lt:k], '>') >= 0 {
		return nil
	}
	gt := bytes.IndexByte(b[k:], '>')
	if gt < 0 {
		return nil
	}
	return b[lt : k+gt+1]
}

func isMetaTag(tag []byte) bool {
	return len(tag) > 5 && bytes.EqualFold(tag[:5], []byte("<meta")) && isSpace(tag[5])
}

// contentIsSDK reports whether the tag has content="sdk" (any quoting, any
// case).
func contentIsSDK(tag []byte) bool {
	lower := bytes.ToLower(tag)
	needle := []byte("content=")
	off := 0
	for {
		k := bytes.Index(lower[off:], needle)
		if k < 0 {
			return false
		}
		k += off
		off = k + 1
		if k == 0 || !isSpace(lower[k-1]) {
			continue
		}
		v := lower[k+len(needle):]
		// Separate ifs on purpose: under Yaegi v0.16.1 a tagless switch case
		// with two expressions ("case a, b:") only evaluated the first, so
		// content='sdk' was missed while the compiled tests passed.
		if bytes.HasPrefix(v, []byte(`"sdk"`)) || bytes.HasPrefix(v, []byte(`'sdk'`)) {
			return true
		}
		if bytes.HasPrefix(v, []byte("sdk")) && isAttrEnd(v, 3) {
			return true
		}
	}
}

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

// isAttrEnd reports whether an unquoted attribute value ends at b[i].
func isAttrEnd(b []byte, i int) bool {
	return i < len(b) && (isSpace(b[i]) || b[i] == '>' || b[i] == '/')
}
