// Package analytics_inject_plugin is a Traefik middleware plugin that inserts
// the Rybbit analytics <script> into the HTML documents of third-party apps
// (infra ADR-0041). The script is served from the app's own origin
// (/_t/r/script.js by default), so a CSP of script-src 'self' allows it.
//
// It runs under Yaegi inside Traefik, so it uses the standard library only.
// Traefik disables every plugin when one fails to load: run
// scripts/yaegi-plugin-gate against this directory before shipping a change.
package analytics_inject_plugin

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"html"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
)

const (
	defaultScriptSrc    = "/_t/r/script.js"
	defaultMaxBodyBytes = 5 << 20 // 5 MiB
)

// Config is the plugin configuration (Middleware.spec.plugin.<key>).
type Config struct {
	// SiteID is the Rybbit site id written to data-site-id. Required.
	SiteID string `json:"siteId,omitempty" yaml:"siteId,omitempty"`
	// ScriptSrc is the script URL. Also the marker for "already injected":
	// a body that contains it is left alone.
	ScriptSrc string `json:"scriptSrc,omitempty" yaml:"scriptSrc,omitempty"`
	// MaxBodyBytes caps how much of an HTML body is held in memory. Larger
	// bodies pass through unmodified.
	MaxBodyBytes int64 `json:"maxBodyBytes,omitempty" yaml:"maxBodyBytes,omitempty"`
	// ExtraAttributes are added to the tag, sorted by name, for example
	// data-track-errors: "true". An empty value renders a bare attribute.
	ExtraAttributes map[string]string `json:"extraAttributes,omitempty" yaml:"extraAttributes,omitempty"`
	// ExcludeHosts are never touched: no wrapping, no Accept-Encoding change.
	// Exact names or "*.suffix" (subdomains only), case-insensitive, matched
	// against req.Host without its port. Exclusion wins over IncludeHosts.
	ExcludeHosts []string `json:"excludeHosts,omitempty" yaml:"excludeHosts,omitempty"`
	// IncludeHosts, when non-empty, are the only eligible hosts. Same syntax.
	IncludeHosts []string `json:"includeHosts,omitempty" yaml:"includeHosts,omitempty"`
}

// CreateConfig returns the defaults Traefik overlays the Middleware config on.
func CreateConfig() *Config {
	return &Config{
		ScriptSrc:       defaultScriptSrc,
		MaxBodyBytes:    defaultMaxBodyBytes,
		ExtraAttributes: map[string]string{},
	}
}

// Injector is the middleware.
type Injector struct {
	next         http.Handler
	name         string
	tag          []byte
	marker       []byte
	maxBodyBytes int64
	exclude      *hostMatcher
	include      *hostMatcher
}

// New builds the middleware. It rejects a config it cannot render safely.
func New(ctx context.Context, next http.Handler, cfg *Config, name string) (http.Handler, error) {
	siteID := strings.TrimSpace(cfg.SiteID)
	if siteID == "" {
		return nil, errors.New("analytics-inject: siteId is required")
	}
	src := strings.TrimSpace(cfg.ScriptSrc)
	if src == "" {
		src = defaultScriptSrc
	}
	maxBody := cfg.MaxBodyBytes
	if maxBody <= 0 {
		maxBody = defaultMaxBodyBytes
	}

	names := make([]string, 0, len(cfg.ExtraAttributes))
	for k := range cfg.ExtraAttributes {
		if !validAttrName(k) {
			return nil, fmt.Errorf("analytics-inject: invalid attribute name %q", k)
		}
		switch strings.ToLower(k) {
		case "src", "data-site-id", "defer":
			return nil, fmt.Errorf("analytics-inject: attribute %q is set by the plugin", k)
		}
		names = append(names, k)
	}
	sort.Strings(names)

	var b strings.Builder
	b.WriteString(`<script src="`)
	b.WriteString(html.EscapeString(src))
	b.WriteString(`" data-site-id="`)
	b.WriteString(html.EscapeString(siteID))
	b.WriteString(`"`)
	for _, k := range names {
		b.WriteString(" ")
		b.WriteString(k)
		if v := cfg.ExtraAttributes[k]; v != "" {
			b.WriteString(`="`)
			b.WriteString(html.EscapeString(v))
			b.WriteString(`"`)
		}
	}
	b.WriteString(` defer></script>`)

	exclude, err := newHostMatcher(cfg.ExcludeHosts)
	if err != nil {
		return nil, fmt.Errorf("analytics-inject: excludeHosts: %w", err)
	}
	include, err := newHostMatcher(cfg.IncludeHosts)
	if err != nil {
		return nil, fmt.Errorf("analytics-inject: includeHosts: %w", err)
	}

	return &Injector{
		next:         next,
		name:         name,
		tag:          []byte(b.String()),
		marker:       []byte(src),
		maxBodyBytes: maxBody,
		exclude:      exclude,
		include:      include,
	}, nil
}

// validAttrName accepts ASCII letters, digits, '-', '_', ':' and '.', starting
// with a letter. That covers every data-* attribute Rybbit documents.
func validAttrName(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		isLetter := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		if i == 0 && !isLetter {
			return false
		}
		if !isLetter && !(c >= '0' && c <= '9') && c != '-' && c != '_' && c != ':' && c != '.' {
			return false
		}
	}
	return true
}

func (p *Injector) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	if !qualifies(req) || !p.hostEligible(req) {
		p.next.ServeHTTP(rw, req)
		return
	}
	// Ask the backend for an uncompressed body so it can be edited. Traefik's
	// compress middleware must run outside this plugin (earlier in the
	// websecure entrypoint list): it has then already read the client's
	// Accept-Encoding and compresses what this plugin writes.
	req.Header.Del("Accept-Encoding")
	w := &injectWriter{p: p, rw: rw}
	p.next.ServeHTTP(w, req)
	w.finish()
}

// qualifies reports whether req is a browser navigation to a document. Only
// those requests are touched at all; everything else goes to next with the
// original writer.
func qualifies(req *http.Request) bool {
	if req.Method != http.MethodGet {
		return false
	}
	if req.Header.Get("Range") != "" || req.Header.Get("Upgrade") != "" {
		return false
	}
	for _, v := range req.Header.Values("Connection") {
		if strings.Contains(strings.ToLower(v), "upgrade") {
			return false
		}
	}
	if strings.EqualFold(strings.TrimSpace(req.Header.Get("Sec-Fetch-Dest")), "document") {
		return true
	}
	for _, v := range req.Header.Values("Accept") {
		if strings.Contains(strings.ToLower(v), "text/html") {
			return true
		}
	}
	return false
}

const (
	stateUndecided   = iota // no status line yet
	stateBuffering          // holding an HTML body
	statePassthrough        // headers sent, writes go straight through
	stateDone               // finished or hijacked
)

// injectWriter buffers a qualifying HTML response and passes everything else
// through. Headers are shared with the underlying writer; while buffering,
// the status line is held back so Content-Length can still be corrected.
type injectWriter struct {
	p     *Injector
	rw    http.ResponseWriter
	state int
	code  int
	buf   *bytes.Buffer
	sdk   bool // the backend sent X-Analytics: sdk
}

func (w *injectWriter) Header() http.Header {
	return w.rw.Header()
}

// takeOptOutHeader records and removes X-Analytics before any header block
// goes to the client.
func (w *injectWriter) takeOptOutHeader() {
	h := w.rw.Header()
	if vs, ok := h[optOutHeader]; ok {
		for _, v := range vs {
			if strings.EqualFold(strings.TrimSpace(v), "sdk") {
				w.sdk = true
			}
		}
		delete(h, optOutHeader)
	}
}

func (w *injectWriter) WriteHeader(code int) {
	if w.state != stateUndecided {
		return
	}
	w.takeOptOutHeader()
	// 1xx informational responses (103 Early Hints) go out immediately and
	// the final status is still to come. 101 is final.
	if code >= 100 && code < 200 && code != http.StatusSwitchingProtocols {
		w.rw.WriteHeader(code)
		return
	}
	w.code = code
	if size, ok := w.bufferable(code); ok && !w.sdk {
		w.state = stateBuffering
		w.buf = &bytes.Buffer{}
		if size > 0 {
			w.buf.Grow(int(size) + len(w.p.tag))
		}
		return
	}
	w.state = statePassthrough
	w.rw.WriteHeader(code)
}

// bufferable decides from the status and response headers whether to hold the
// body. It returns the declared Content-Length, or 0 if none was declared.
func (w *injectWriter) bufferable(code int) (int64, bool) {
	if code != http.StatusOK {
		return 0, false
	}
	h := w.rw.Header()
	ct := strings.ToLower(strings.TrimSpace(h.Get("Content-Type")))
	if !strings.HasPrefix(ct, "text/html") {
		return 0, false
	}
	if ce := strings.TrimSpace(h.Get("Content-Encoding")); ce != "" && !strings.EqualFold(ce, "identity") {
		return 0, false
	}
	cl := h.Get("Content-Length")
	if cl == "" {
		return 0, true
	}
	n, err := strconv.ParseInt(strings.TrimSpace(cl), 10, 64)
	if err != nil || n < 0 || n > w.p.maxBodyBytes {
		return 0, false
	}
	return n, true
}

func (w *injectWriter) Write(b []byte) (int, error) {
	if w.state == stateUndecided {
		w.WriteHeader(http.StatusOK)
	}
	if w.state != stateBuffering {
		return w.rw.Write(b)
	}
	if int64(w.buf.Len())+int64(len(b)) > w.p.maxBodyBytes {
		// Too big to hold: send what was held, unmodified, then stream.
		if err := w.release(); err != nil {
			return 0, err
		}
		return w.rw.Write(b)
	}
	return w.buf.Write(b)
}

// Flush sends what the backend has written so far. While buffering HTML it
// injects into the held bytes if they already contain an insertion point,
// otherwise it gives up on this response; either way the rest streams.
func (w *injectWriter) Flush() {
	if w.state == stateUndecided {
		w.WriteHeader(http.StatusOK)
	}
	if w.state == stateBuffering {
		w.commit(false)
		w.state = statePassthrough
	}
	if f, ok := w.rw.(http.Flusher); ok {
		f.Flush()
	}
}

// Hijack hands the connection to the backend (websockets and other upgrades).
func (w *injectWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hj, ok := w.rw.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("analytics-inject: %T does not implement http.Hijacker", w.rw)
	}
	conn, brw, err := hj.Hijack()
	if err == nil {
		w.state = stateDone
	}
	return conn, brw, err
}

// committed reports whether the status line has gone to the underlying writer.
func (w *injectWriter) committed() bool {
	return w.state == statePassthrough || w.state == stateDone
}

// finish runs after the backend returns and sends a still-held body.
func (w *injectWriter) finish() {
	switch w.state {
	case stateUndecided:
		// The backend wrote nothing; net/http will send the header map as is.
		w.takeOptOutHeader()
	case stateBuffering:
		w.commit(true)
	}
	w.state = stateDone
}

// release sends the held body unmodified and switches to passthrough.
func (w *injectWriter) release() error {
	w.state = statePassthrough
	w.rw.WriteHeader(w.code)
	body := w.buf.Bytes()
	w.buf = nil
	if len(body) == 0 {
		return nil
	}
	_, err := w.rw.Write(body)
	return err
}

// commit sends the held bytes with the tag inserted when there is an insertion
// point, the script is not already present, and the page has no SDK opt-out
// meta tag. final means the held bytes are
// the whole body, so Content-Length is set from them; otherwise a declared
// Content-Length grows by the tag length and an absent one stays absent.
func (w *injectWriter) commit(final bool) {
	body := w.buf.Bytes()
	w.buf = nil
	pos := -1
	if !bytes.Contains(body, w.p.marker) && !hasOptOutMeta(body) {
		pos = injectionPoint(body)
	}
	if pos < 0 {
		w.rw.WriteHeader(w.code)
		if len(body) > 0 {
			_, _ = w.rw.Write(body)
		}
		return
	}

	h := w.rw.Header()
	if final {
		h.Set("Content-Length", strconv.Itoa(len(body)+len(w.p.tag)))
	} else if cl := h.Get("Content-Length"); cl != "" {
		if n, err := strconv.ParseInt(strings.TrimSpace(cl), 10, 64); err == nil {
			h.Set("Content-Length", strconv.FormatInt(n+int64(len(w.p.tag)), 10))
		}
	}
	w.rw.WriteHeader(w.code)
	if _, err := w.rw.Write(body[:pos]); err != nil {
		return
	}
	if _, err := w.rw.Write(w.p.tag); err != nil {
		return
	}
	_, _ = w.rw.Write(body[pos:])
}

// Byte patterns searched for: each tag name in three spellings, followed by
// each byte that can end a tag name, so "<head" never matches "<header". Each
// pattern is found with one bytes.Index call, which runs as native code under
// Yaegi. Loops in plugin code are interpreted instead: a byte-by-byte scan
// took 12.6 s on a 5 MiB fragment with no head or body, and skipping "<header"
// false hits one by one took 1.1 s on 200,000 <header> tags. Mixed-case
// spellings such as "<hEaD>" are not matched; such a page falls through to the
// next insertion point, or passes through untouched.
var (
	tagHeadClose = tagPatterns("</head", "</HEAD", "</Head")
	tagHeadOpen  = tagPatterns("<head", "<HEAD", "<Head")
	tagBodyOpen  = tagPatterns("<body", "<BODY", "<Body")
)

func tagPatterns(spellings ...string) [][]byte {
	terminators := []string{">", " ", "\n", "\t", "\r", "\f", "/"}
	out := make([][]byte, 0, len(spellings)*len(terminators))
	for _, s := range spellings {
		for _, t := range terminators {
			out = append(out, []byte(s+t))
		}
	}
	return out
}

// injectionPoint returns the byte offset to insert the tag at: before
// </head>; failing that, after the <head ...> open tag; failing that, after
// the <body ...> open tag. It returns -1 when the bytes hold none of them.
func injectionPoint(b []byte) int {
	if i := findTag(b, tagHeadClose); i >= 0 {
		return i
	}
	if i := findTag(b, tagHeadOpen); i >= 0 {
		return afterOpenTag(b, i)
	}
	if i := findTag(b, tagBodyOpen); i >= 0 {
		return afterOpenTag(b, i)
	}
	return -1
}

// afterOpenTag returns the offset just past the '>' that closes the tag
// starting at i, or -1 if the bytes end first.
func afterOpenTag(b []byte, i int) int {
	end := bytes.IndexByte(b[i:], '>')
	if end < 0 {
		return -1
	}
	return i + end + 1
}

// findTag returns the offset of the earliest occurrence of any pattern, or -1.
// Once one is found, later patterns only search the bytes before it.
func findTag(b []byte, patterns [][]byte) int {
	best := -1
	limit := len(b)
	for _, p := range patterns {
		if k := bytes.Index(b[:limit], p); k >= 0 {
			best = k
			limit = k + len(p) - 1
		}
	}
	return best
}
