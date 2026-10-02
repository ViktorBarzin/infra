package crowdsec_bouncer_plugin

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// AppSec helpers
// ---------------------------------------------------------------------------

// appsecCall is what the fake AppSec component saw for one check.
type appsecCall struct {
	method string
	header http.Header
	body   string
}

// fakeAppsec answers every check with status, after an optional delay, and
// records what it was sent.
type fakeAppsec struct {
	mu     sync.Mutex
	calls  []appsecCall
	status int
	delay  time.Duration
	srv    *httptest.Server
}

func newFakeAppsec(t *testing.T, status int) *fakeAppsec {
	t.Helper()
	f := &fakeAppsec{status: status}
	f.srv = httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		body, _ := io.ReadAll(req.Body)
		f.mu.Lock()
		f.calls = append(f.calls, appsecCall{method: req.Method, header: req.Header.Clone(), body: string(body)})
		status, delay := f.status, f.delay
		f.mu.Unlock()
		if delay > 0 {
			time.Sleep(delay)
		}
		rw.WriteHeader(status)
		if status == http.StatusForbidden {
			io.WriteString(rw, `{"action":"ban","http_status":403}`)
		} else {
			io.WriteString(rw, `{"action":"allow"}`)
		}
	}))
	// A closure, not the method value: yaegi (which these tests also run
	// under) cannot pass f.srv.Close as a func().
	t.Cleanup(func() { f.srv.Close() })
	return f
}

func (f *fakeAppsec) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func (f *fakeAppsec) last(t *testing.T) appsecCall {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.calls) == 0 {
		t.Fatalf("AppSec was never called")
	}
	return f.calls[len(f.calls)-1]
}

// appsecConfig is an enforcing config with AppSec on and pointed at url.
func appsecConfig(url string) *Config {
	cfg := enforcing()
	cfg.LapiKey = "bouncer-key"
	cfg.AppsecEnabled = true
	cfg.AppsecURL = url
	return cfg
}

// appsecBouncer builds a bouncer with an empty-but-loaded ban set and a fresh
// breaker, so every test starts from a closed breaker.
func appsecBouncer(t *testing.T, cfg *Config, next http.Handler) *Bouncer {
	t.Helper()
	resetBreaker()
	t.Cleanup(resetBreaker)
	return testBouncer(t, cfg, nil, next)
}

// trackingBody records how many bytes were read from it and when.
type trackingBody struct {
	mu   sync.Mutex
	r    io.Reader
	read int
	err  error
}

func (tb *trackingBody) Read(p []byte) (int, error) {
	tb.mu.Lock()
	defer tb.mu.Unlock()
	if tb.err != nil {
		return 0, tb.err
	}
	n, err := tb.r.Read(p)
	tb.read += n
	return n, err
}

func (tb *trackingBody) Close() error { return nil }

func (tb *trackingBody) bytesRead() int {
	tb.mu.Lock()
	defer tb.mu.Unlock()
	return tb.read
}

// bodyRequest builds a request whose body is a trackingBody, with the given
// declared length (-1 means unknown, as for chunked).
func bodyRequest(method, target, contentType string, payload []byte, contentLength int64) (*http.Request, *trackingBody) {
	tb := &trackingBody{r: bytes.NewReader(payload)}
	req := httptest.NewRequest(method, target, nil)
	req.Body = tb
	req.ContentLength = contentLength
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	req.RemoteAddr = "203.0.113.9:4444"
	return req, tb
}

// ---------------------------------------------------------------------------
// defaults and wiring
// ---------------------------------------------------------------------------

func TestAppsecDefaultsAreOffAndConservative(t *testing.T) {
	cfg := CreateConfig()
	if cfg.AppsecEnabled {
		t.Errorf("AppSec must ship disabled; it is switched on per Middleware")
	}
	if cfg.AppsecURL != "http://crowdsec-appsec-service.crowdsec.svc.cluster.local:7422" {
		t.Errorf("AppsecURL default = %q", cfg.AppsecURL)
	}
	if cfg.AppsecTimeoutMs != 200 {
		t.Errorf("AppsecTimeoutMs default = %d, want 200", cfg.AppsecTimeoutMs)
	}
	if cfg.AppsecBodyLimit != 65536 {
		t.Errorf("AppsecBodyLimit default = %d, want 65536", cfg.AppsecBodyLimit)
	}
}

func TestAppsecDisabledNeverCallsAppsec(t *testing.T) {
	f := newFakeAppsec(t, http.StatusForbidden)
	cfg := appsecConfig(f.srv.URL)
	cfg.AppsecEnabled = false
	hit := false
	b := appsecBouncer(t, cfg, okNext(&hit))
	rec := do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
	if !hit || rec.Code != http.StatusOK || f.callCount() != 0 {
		t.Fatalf("disabled AppSec: hit=%v code=%d calls=%d", hit, rec.Code, f.callCount())
	}
}

func TestNewWithBadAppsecURLDisablesAppsecInsteadOfFailing(t *testing.T) {
	// A New() error makes the middleware unresolvable, and the entrypoint
	// middleware is on every router: one bad URL must not 404 the fleet.
	cfg := appsecConfig("::not a url")
	b, err := newBouncer(cfg, okNext(new(bool)), "test")
	if err != nil {
		t.Fatalf("newBouncer must not fail on a bad AppSec URL: %v", err)
	}
	if b.appsecOn {
		t.Errorf("a bad AppSec URL must turn AppSec off")
	}
}

// ---------------------------------------------------------------------------
// protocol
// ---------------------------------------------------------------------------

func TestAppsecAllowReachesBackendAndSendsProtocolHeaders(t *testing.T) {
	f := newFakeAppsec(t, http.StatusOK)
	hit := false
	b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(&hit))

	req := httptest.NewRequest(http.MethodGet, "http://app.viktorbarzin.me/search?q=a%20b&x=1", nil)
	req.RemoteAddr = "203.0.113.9:4444"
	req.Header.Set("User-Agent", "curl/8.5")
	req.Header.Set("Accept", "text/html")
	rec := httptest.NewRecorder()
	b.ServeHTTP(rec, req)

	if !hit || rec.Code != http.StatusOK {
		t.Fatalf("allow: hit=%v code=%d", hit, rec.Code)
	}
	c := f.last(t)
	if c.method != http.MethodGet {
		t.Errorf("bodiless check must be GET, got %s", c.method)
	}
	want := map[string]string{
		"X-Crowdsec-Appsec-Ip":           "203.0.113.9",
		"X-Crowdsec-Appsec-Uri":          "/search?q=a%20b&x=1",
		"X-Crowdsec-Appsec-Host":         "app.viktorbarzin.me",
		"X-Crowdsec-Appsec-Verb":         "GET",
		"X-Crowdsec-Appsec-Api-Key":      "bouncer-key",
		"X-Crowdsec-Appsec-User-Agent":   "curl/8.5",
		"X-Crowdsec-Appsec-Http-Version": "11",
		"Accept":                         "text/html",
	}
	for k, v := range want {
		if got := c.header.Get(k); got != v {
			t.Errorf("%s = %q, want %q", k, got, v)
		}
	}
}

func TestAppsecUsesTheResolvedClientIPBehindCloudflared(t *testing.T) {
	f := newFakeAppsec(t, http.StatusOK)
	b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(new(bool)))
	do(b, "10.10.3.4:5555", "app.viktorbarzin.me", map[string]string{"Cf-Connecting-Ip": "198.51.100.7"})
	if got := f.last(t).header.Get("X-Crowdsec-Appsec-Ip"); got != "198.51.100.7" {
		t.Errorf("AppSec IP = %q, want the Cf-Connecting-Ip from the trusted peer", got)
	}
}

func TestClientCannotSmuggleAppsecHeaders(t *testing.T) {
	f := newFakeAppsec(t, http.StatusOK)
	b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(new(bool)))
	do(b, "203.0.113.9:4444", "app.viktorbarzin.me", map[string]string{
		"X-Crowdsec-Appsec-Ip":      "1.2.3.4",
		"X-Crowdsec-Appsec-Api-Key": "evil",
		"X-Crowdsec-Appsec-Foo":     "bar",
	})
	c := f.last(t)
	if c.header.Get("X-Crowdsec-Appsec-Ip") != "203.0.113.9" || c.header.Get("X-Crowdsec-Appsec-Api-Key") != "bouncer-key" {
		t.Errorf("client-supplied AppSec headers leaked: ip=%q key=%q",
			c.header.Get("X-Crowdsec-Appsec-Ip"), c.header.Get("X-Crowdsec-Appsec-Api-Key"))
	}
	if c.header.Get("X-Crowdsec-Appsec-Foo") != "" {
		t.Errorf("unknown client X-Crowdsec-Appsec-* header was forwarded")
	}
}

func TestHopByHopHeadersAreNotForwarded(t *testing.T) {
	f := newFakeAppsec(t, http.StatusOK)
	b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(new(bool)))
	do(b, "203.0.113.9:4444", "app.viktorbarzin.me", map[string]string{
		"Connection": "Upgrade", "Upgrade": "websocket", "Expect": "100-continue",
		"Te": "trailers", "Keep-Alive": "timeout=5", "Proxy-Connection": "keep-alive",
	})
	c := f.last(t)
	for _, h := range []string{"Upgrade", "Expect", "Te", "Keep-Alive", "Proxy-Connection"} {
		if c.header.Get(h) != "" {
			t.Errorf("hop-by-hop header %s was forwarded", h)
		}
	}
}

func TestAppsecBlockReturns403AndSkipsBackend(t *testing.T) {
	f := newFakeAppsec(t, http.StatusForbidden)
	hit := false
	b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(&hit))
	lines := capture(b)
	rec := do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
	if hit || rec.Code != http.StatusForbidden {
		t.Fatalf("block: hit=%v code=%d", hit, rec.Code)
	}
	if len(*lines) != 1 || !strings.Contains((*lines)[0], "[crowdsec-bouncer] action=appsec-block ip=203.0.113.9 host=app.viktorbarzin.me") {
		t.Errorf("block log = %q", *lines)
	}
}

func TestAppsecNon403StatusesFailOpen(t *testing.T) {
	// 401 is what a fresh AppSec pod answers while LAPI is unreachable, 500 is
	// an engine error, 404 a wrong URL. None of them may block.
	for _, status := range []int{http.StatusUnauthorized, http.StatusInternalServerError, http.StatusNotFound, http.StatusTooManyRequests} {
		f := newFakeAppsec(t, status)
		hit := false
		b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(&hit))
		rec := do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
		if !hit || rec.Code != http.StatusOK {
			t.Errorf("status %d: hit=%v code=%d, want fail-open", status, hit, rec.Code)
		}
	}
}

func TestAppsecTimeoutFailsOpenWithinTheDeadline(t *testing.T) {
	f := newFakeAppsec(t, http.StatusForbidden)
	f.delay = 500 * time.Millisecond
	cfg := appsecConfig(f.srv.URL)
	cfg.AppsecTimeoutMs = 50
	hit := false
	b := appsecBouncer(t, cfg, okNext(&hit))
	start := time.Now()
	rec := do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
	if took := time.Since(start); took > 300*time.Millisecond {
		t.Errorf("timed-out check took %v, want ~50ms", took)
	}
	if !hit || rec.Code != http.StatusOK {
		t.Fatalf("timeout: hit=%v code=%d, want fail-open", hit, rec.Code)
	}
}

func TestAppsecUnreachableFailsOpen(t *testing.T) {
	hit := false
	b := appsecBouncer(t, appsecConfig("http://127.0.0.1:1"), okNext(&hit))
	rec := do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
	if !hit || rec.Code != http.StatusOK {
		t.Fatalf("unreachable: hit=%v code=%d", hit, rec.Code)
	}
}

// ---------------------------------------------------------------------------
// skip lists
// ---------------------------------------------------------------------------

func TestAppsecSkipHostSkipsInspectionButKeepsBans(t *testing.T) {
	f := newFakeAppsec(t, http.StatusForbidden)
	cfg := appsecConfig(f.srv.URL)
	cfg.AppsecSkipHosts = []string{"Immich.viktorbarzin.me"}
	hit := false
	resetBreaker()
	t.Cleanup(resetBreaker)
	b := testBouncer(t, cfg, banned("198.51.100.66"), okNext(&hit))

	rec := do(b, "203.0.113.9:4444", "immich.viktorbarzin.me:443", nil)
	if !hit || rec.Code != http.StatusOK || f.callCount() != 0 {
		t.Fatalf("skipped host: hit=%v code=%d calls=%d", hit, rec.Code, f.callCount())
	}
	hit = false
	rec = do(b, "198.51.100.66:4444", "immich.viktorbarzin.me", nil)
	if hit || rec.Code != http.StatusForbidden {
		t.Fatalf("a banned client must still be blocked on an AppSec-skipped host: hit=%v code=%d", hit, rec.Code)
	}
}

func TestBouncerSkipHostsAlsoSkipAppsec(t *testing.T) {
	f := newFakeAppsec(t, http.StatusForbidden)
	hit := false
	b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(&hit))
	rec := do(b, "203.0.113.9:4444", "authentik.viktorbarzin.me", nil)
	if !hit || rec.Code != http.StatusOK || f.callCount() != 0 {
		t.Fatalf("auth host: hit=%v code=%d calls=%d", hit, rec.Code, f.callCount())
	}
}

func TestBannedClientIsBlockedBeforeAppsec(t *testing.T) {
	f := newFakeAppsec(t, http.StatusOK)
	resetBreaker()
	t.Cleanup(resetBreaker)
	b := testBouncer(t, appsecConfig(f.srv.URL), banned("203.0.113.9"), okNext(new(bool)))
	rec := do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
	if rec.Code != http.StatusForbidden || f.callCount() != 0 {
		t.Fatalf("banned client: code=%d calls=%d", rec.Code, f.callCount())
	}
}

// ---------------------------------------------------------------------------
// body policy: the property that keeps uploads streaming
// ---------------------------------------------------------------------------

func TestSmallJSONBodyIsInspectedAndRestored(t *testing.T) {
	f := newFakeAppsec(t, http.StatusOK)
	payload := []byte(`{"user":"a","q":"` + strings.Repeat("x", 2000) + `"}`)
	var got []byte
	next := http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		got, _ = io.ReadAll(req.Body)
		rw.WriteHeader(http.StatusOK)
	})
	b := appsecBouncer(t, appsecConfig(f.srv.URL), next)
	req, _ := bodyRequest(http.MethodPost, "http://app.viktorbarzin.me/api/login", "application/json; charset=utf-8", payload, int64(len(payload)))
	rec := httptest.NewRecorder()
	b.ServeHTTP(rec, req)

	c := f.last(t)
	if c.method != http.MethodPost || c.body != string(payload) {
		t.Errorf("AppSec got method=%s body-len=%d, want POST with the body", c.method, len(c.body))
	}
	if c.header.Get("X-Crowdsec-Appsec-Verb") != "POST" {
		t.Errorf("verb header = %q", c.header.Get("X-Crowdsec-Appsec-Verb"))
	}
	if !bytes.Equal(got, payload) {
		t.Errorf("backend got %d bytes, want the original %d", len(got), len(payload))
	}
}

func TestInspectedMediaTypes(t *testing.T) {
	cases := map[string]bool{
		"application/json":                  true,
		"application/x-www-form-urlencoded": true,
		"application/xml":                   true,
		"text/xml":                          true,
		"application/vnd.api+json":          true,
		"application/soap+xml":              true,
		"APPLICATION/JSON; charset=UTF-8":   true,
		"multipart/form-data; boundary=x":   false,
		"application/octet-stream":          false,
		"video/mp4":                         false,
		"text/plain":                        false,
		"":                                  false,
		"garbage;;;":                        false,
	}
	for ct, want := range cases {
		if got := inspectableMediaType(ct); got != want {
			t.Errorf("inspectableMediaType(%q) = %v, want %v", ct, got, want)
		}
	}
}

// assertUntouched checks the two halves of "never buffered": AppSec received
// no body, and the backend was entered before a single byte had been read.
func assertUntouched(t *testing.T, name, method, contentType string, payload []byte, contentLength int64, mutate func(*http.Request)) {
	t.Helper()
	f := newFakeAppsec(t, http.StatusOK)
	var readBeforeNext = -1
	var got []byte
	var tb *trackingBody
	next := http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		readBeforeNext = tb.bytesRead()
		got, _ = io.ReadAll(req.Body)
		rw.WriteHeader(http.StatusOK)
	})
	b := appsecBouncer(t, appsecConfig(f.srv.URL), next)
	var req *http.Request
	req, tb = bodyRequest(method, "http://app.viktorbarzin.me/upload", contentType, payload, contentLength)
	if mutate != nil {
		mutate(req)
	}
	rec := httptest.NewRecorder()
	b.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("%s: code=%d", name, rec.Code)
	}
	if readBeforeNext != 0 {
		t.Errorf("%s: %d body bytes were read before the backend was called, want 0", name, readBeforeNext)
	}
	c := f.last(t)
	if c.method != http.MethodGet || c.body != "" {
		t.Errorf("%s: AppSec got method=%s body-len=%d, want a bodiless GET", name, c.method, len(c.body))
	}
	if c.header.Get("X-Crowdsec-Appsec-Verb") != method {
		t.Errorf("%s: verb header = %q, want %q", name, c.header.Get("X-Crowdsec-Appsec-Verb"), method)
	}
	if !bytes.Equal(got, payload) {
		t.Errorf("%s: backend got %d bytes, want %d", name, len(got), len(payload))
	}
}

func TestBodyOneByteOverTheLimitIsNotRead(t *testing.T) {
	payload := []byte(`{"a":"` + strings.Repeat("x", 65536-8+1) + `"}`)
	if len(payload) != 65537 {
		t.Fatalf("payload is %d bytes, want 65537", len(payload))
	}
	assertUntouched(t, "65537-byte JSON", http.MethodPost, "application/json", payload, int64(len(payload)), nil)
}

func TestBodyAtTheLimitIsInspected(t *testing.T) {
	f := newFakeAppsec(t, http.StatusOK)
	payload := []byte(`{"a":"` + strings.Repeat("x", 65536-8) + `"}`)
	b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(new(bool)))
	req, _ := bodyRequest(http.MethodPost, "http://app.viktorbarzin.me/api", "application/json", payload, int64(len(payload)))
	b.ServeHTTP(httptest.NewRecorder(), req)
	if c := f.last(t); c.method != http.MethodPost || len(c.body) != 65536 {
		t.Errorf("65536-byte body: method=%s len=%d, want POST with the body", c.method, len(c.body))
	}
}

func TestMultipartUploadIsNotRead(t *testing.T) {
	payload := []byte("--x\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"a.mp4\"\r\n\r\nDATA\r\n--x--\r\n")
	assertUntouched(t, "small multipart", http.MethodPost, "multipart/form-data; boundary=x", payload, int64(len(payload)), nil)
}

func TestChunkedBodyIsNotRead(t *testing.T) {
	payload := []byte(`{"small":"json"}`)
	assertUntouched(t, "chunked JSON", http.MethodPost, "application/json", payload, -1, nil)
}

func TestCompressedBodyIsNotRead(t *testing.T) {
	payload := []byte(`{"small":"json"}`)
	assertUntouched(t, "gzip JSON", http.MethodPost, "application/json", payload, int64(len(payload)), func(req *http.Request) {
		req.Header.Set("Content-Encoding", "gzip")
	})
}

func TestOctetStreamIsNotRead(t *testing.T) {
	payload := bytes.Repeat([]byte{0xab}, 1024)
	assertUntouched(t, "octet-stream PUT", http.MethodPut, "application/octet-stream", payload, int64(len(payload)), nil)
}

func TestSkippedHostBodyIsNotRead(t *testing.T) {
	f := newFakeAppsec(t, http.StatusOK)
	cfg := appsecConfig(f.srv.URL)
	cfg.AppsecSkipHosts = []string{"immich.viktorbarzin.me"}
	var tb *trackingBody
	readBeforeNext := -1
	next := http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		readBeforeNext = tb.bytesRead()
		rw.WriteHeader(http.StatusOK)
	})
	b := appsecBouncer(t, cfg, next)
	payload := []byte(`{"small":"json"}`)
	var req *http.Request
	req, tb = bodyRequest(http.MethodPost, "http://immich.viktorbarzin.me/api/search", "application/json", payload, int64(len(payload)))
	req.Host = "immich.viktorbarzin.me"
	b.ServeHTTP(httptest.NewRecorder(), req)
	if readBeforeNext != 0 || f.callCount() != 0 {
		t.Errorf("skipped host: read=%d calls=%d, want 0 and 0", readBeforeNext, f.callCount())
	}
}

func TestBodyReadErrorAnswers400WithoutCallingTheBackend(t *testing.T) {
	f := newFakeAppsec(t, http.StatusOK)
	hit := false
	b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(&hit))
	req, tb := bodyRequest(http.MethodPost, "http://app.viktorbarzin.me/api", "application/json", []byte(`{"a":1}`), 7)
	tb.err = errors.New("client went away")
	rec := httptest.NewRecorder()
	b.ServeHTTP(rec, req)
	if hit || rec.Code != http.StatusBadRequest {
		t.Fatalf("read error: hit=%v code=%d, want 400 and no backend call", hit, rec.Code)
	}
}

// ---------------------------------------------------------------------------
// circuit breaker
// ---------------------------------------------------------------------------

func TestBreakerOpensOnFailureRatioAndStopsCalling(t *testing.T) {
	f := newFakeAppsec(t, http.StatusInternalServerError)
	b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(new(bool)))
	lines := capture(b)

	for i := 0; i < breakerWindow; i++ {
		do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
	}
	if f.callCount() != breakerWindow {
		t.Fatalf("calls before opening = %d, want %d", f.callCount(), breakerWindow)
	}
	for i := 0; i < 10; i++ {
		rec := do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("open breaker must fail open, got %d", rec.Code)
		}
	}
	if f.callCount() != breakerWindow {
		t.Errorf("calls while open = %d, want none beyond %d", f.callCount()-breakerWindow, 0)
	}
	opened := 0
	for _, l := range *lines {
		if strings.Contains(l, "action=appsec-breaker state=open") {
			opened++
		}
	}
	if opened != 1 {
		t.Errorf("breaker-open log lines = %d, want exactly 1 (only transitions are logged): %q", opened, *lines)
	}
}

func TestBreakerStaysClosedBelowTheRatio(t *testing.T) {
	f := newFakeAppsec(t, http.StatusOK)
	b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(new(bool)))
	// 9 failures in 20 is under half: keep checking.
	for i := 0; i < breakerWindow; i++ {
		f.mu.Lock()
		if i%2 == 0 && i < 18 {
			f.status = http.StatusInternalServerError
		} else {
			f.status = http.StatusOK
		}
		f.mu.Unlock()
		do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
	}
	before := f.callCount()
	do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
	if f.callCount() != before+1 {
		t.Errorf("breaker opened at 9/20 failures")
	}
}

func TestBreakerClosesAfterTheOpenPeriod(t *testing.T) {
	f := newFakeAppsec(t, http.StatusInternalServerError)
	b := appsecBouncer(t, appsecConfig(f.srv.URL), okNext(new(bool)))
	lines := capture(b)
	saved := breakerOpenFor
	breakerOpenFor = 20 * time.Millisecond
	t.Cleanup(func() { breakerOpenFor = saved })

	for i := 0; i < breakerWindow; i++ {
		do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
	}
	time.Sleep(40 * time.Millisecond)
	f.mu.Lock()
	f.status = http.StatusOK
	f.mu.Unlock()
	before := f.callCount()
	do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
	if f.callCount() != before+1 {
		t.Fatalf("breaker did not resume checks after the open period")
	}
	closed := false
	for _, l := range *lines {
		if strings.Contains(l, "action=appsec-breaker state=closed") {
			closed = true
		}
	}
	if !closed {
		t.Errorf("no state=closed line: %q", *lines)
	}
}

func TestBreakerIsSharedAcrossMiddlewareInstances(t *testing.T) {
	// Traefik rebuilds the middleware on every config reload (~285/h); a
	// per-instance breaker would forget its failures every few seconds.
	f := newFakeAppsec(t, http.StatusInternalServerError)
	cfg := appsecConfig(f.srv.URL)
	resetBreaker()
	t.Cleanup(resetBreaker)
	for i := 0; i < breakerWindow; i++ {
		b := testBouncer(t, cfg, nil, okNext(new(bool)))
		do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
	}
	b := testBouncer(t, cfg, nil, okNext(new(bool)))
	do(b, "203.0.113.9:4444", "app.viktorbarzin.me", nil)
	if f.callCount() != breakerWindow {
		t.Errorf("a fresh instance ignored the open breaker: calls=%d", f.callCount())
	}
}
