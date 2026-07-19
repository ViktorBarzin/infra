package real_ip_plugin

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// serve runs the plugin with the DEFAULT config (trusts the in-cluster pod
// CIDR 10.10.0.0/16), the given real TCP peer (req.RemoteAddr), and the given
// request headers, returning the X-Real-Ip the next handler observes.
//
// httptest.NewRequest defaults RemoteAddr to 192.0.2.1:1234, so every test MUST
// set the peer explicitly — trust is decided by the peer, never by the headers.
func serve(t *testing.T, remoteAddr string, h http.Header) string {
	t.Helper()
	return serveCfg(t, CreateConfig(), remoteAddr, h)
}

// serveCfg is serve with an explicit config (for custom TrustedProxyCIDRs).
func serveCfg(t *testing.T, cfg *Config, remoteAddr string, h http.Header) string {
	t.Helper()
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = remoteAddr
	if h != nil {
		req.Header = h
	}
	var got string
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Get("X-Real-Ip")
	})
	rp, err := New(context.Background(), next, cfg, "test")
	if err != nil {
		t.Fatalf("New returned an unexpected error: %v", err)
	}
	rp.ServeHTTP(httptest.NewRecorder(), req)
	return got
}

// --- Trusted peer: a genuine in-cluster proxy (cloudflared). Its client-set
// CF / XFF headers are trusted. ---

// 1. Trusted peer + public Cf-Connecting-Ip → that CF value wins.
func TestTrustedPeerCFWins(t *testing.T) {
	got := serve(t, "10.10.195.236:5000", http.Header{
		"Cf-Connecting-Ip": {"203.0.113.5"},
		"X-Forwarded-For":  {"198.51.100.9"},
		"X-Real-Ip":        {"1.1.1.1"},
	})
	if got != "203.0.113.5" {
		t.Fatalf("trusted peer must trust Cf-Connecting-Ip; want 203.0.113.5, got %q", got)
	}
}

// 2. Trusted peer + loopback CF (not public) + no XFF → falls back to the peer,
// never the spoofable loopback value.
func TestTrustedPeerLoopbackCFFallsToPeer(t *testing.T) {
	got := serve(t, "10.10.195.236:5000", http.Header{
		"Cf-Connecting-Ip": {"127.0.0.1"},
	})
	if got == "127.0.0.1" {
		t.Fatal("a loopback Cf-Connecting-Ip must never be stamped")
	}
	if got != "10.10.195.236" {
		t.Fatalf("with an unusable CF and no XFF, want the peer 10.10.195.236, got %q", got)
	}
}

// 3. Trusted peer + no CF + XFF (private then public) → first public entry.
func TestTrustedPeerXFFFirstPublic(t *testing.T) {
	got := serve(t, "10.10.195.236:5000", http.Header{
		"X-Forwarded-For": {"10.0.0.9, 198.51.100.9"},
	})
	if got != "198.51.100.9" {
		t.Fatalf("want first public XFF entry 198.51.100.9, got %q", got)
	}
}

// 4. Trusted peer + no CF/XFF → the peer itself.
func TestTrustedPeerNoHeadersUsesPeer(t *testing.T) {
	got := serve(t, "10.10.195.236:5000", nil)
	if got != "10.10.195.236" {
		t.Fatalf("a trusted peer with no headers must become the peer 10.10.195.236, got %q", got)
	}
}

// --- Untrusted peer: the real client itself (pfSense PROXY-protocol rewrote
// RemoteAddr, or direct/internal). ALL client-supplied headers are ignored. ---

// 5. Untrusted peer + forged Cf-Connecting-Ip → peer wins, forgery ignored.
func TestUntrustedPeerForgedCFRejected(t *testing.T) {
	got := serve(t, "10.0.10.10:5000", http.Header{
		"Cf-Connecting-Ip": {"6.6.6.6"},
	})
	if got != "10.0.10.10" {
		t.Fatalf("forged Cf-Connecting-Ip from an untrusted peer must be ignored; want 10.0.10.10, got %q", got)
	}
}

// 6. Untrusted peer + forged X-Forwarded-For → peer wins, forgery ignored.
func TestUntrustedPeerForgedXFFRejected(t *testing.T) {
	got := serve(t, "10.0.10.10:5000", http.Header{
		"X-Forwarded-For": {"7.7.7.7"},
	})
	if got != "10.0.10.10" {
		t.Fatalf("forged X-Forwarded-For from an untrusted peer must be ignored; want 10.0.10.10, got %q", got)
	}
}

// 7. Untrusted peer + forged raw X-Real-Ip → overwritten with the peer.
func TestUntrustedPeerForgedRawXRealIPRejected(t *testing.T) {
	got := serve(t, "10.0.10.10:5000", http.Header{
		"X-Real-Ip": {"8.8.8.8"},
	})
	if got != "10.0.10.10" {
		t.Fatalf("forged raw X-Real-Ip from an untrusted peer must be overwritten; want 10.0.10.10, got %q", got)
	}
}

// 8. Untrusted PUBLIC peer (pfSense PROXY-protocol real client), no headers →
// the peer itself.
func TestUntrustedPublicPeerNoHeaders(t *testing.T) {
	got := serve(t, "176.12.22.76:5000", nil)
	if got != "176.12.22.76" {
		t.Fatalf("a direct public client must become its own peer IP; want 176.12.22.76, got %q", got)
	}
}

// 9. Untrusted public peer + forged CF + forged XFF + forged X-Real-Ip → the
// real peer wins, every forged header ignored.
func TestUntrustedPublicPeerForgedHeadersIgnored(t *testing.T) {
	got := serve(t, "176.12.22.76:5000", http.Header{
		"Cf-Connecting-Ip": {"6.6.6.6"},
		"X-Forwarded-For":  {"7.7.7.7"},
		"X-Real-Ip":        {"8.8.8.8"},
	})
	if got != "176.12.22.76" {
		t.Fatalf("forged headers from a real public client must be ignored; want 176.12.22.76, got %q", got)
	}
}

// --- Config: custom TrustedProxyCIDRs ---

// 10. A peer inside a custom trusted CIDR is trusted; one outside is not.
func TestCustomTrustedProxyCIDRs(t *testing.T) {
	cfg := &Config{TrustedProxyCIDRs: []string{"192.168.5.0/24"}}
	// inside the custom range → trusts the CF header
	if got := serveCfg(t, cfg, "192.168.5.7:5000", http.Header{"Cf-Connecting-Ip": {"203.0.113.5"}}); got != "203.0.113.5" {
		t.Fatalf("peer inside custom trusted CIDR must trust CF; want 203.0.113.5, got %q", got)
	}
	// outside the custom range → untrusted, forged CF ignored, peer wins
	if got := serveCfg(t, cfg, "192.168.6.7:5000", http.Header{"Cf-Connecting-Ip": {"203.0.113.5"}}); got != "192.168.6.7" {
		t.Fatalf("peer outside custom trusted CIDR must be untrusted; want 192.168.6.7, got %q", got)
	}
}

// 11. RemoteAddr without a port must not panic and must decide trust correctly.
func TestRemoteAddrWithoutPort(t *testing.T) {
	// trusted bare-IP peer → trusts CF
	if got := serve(t, "10.10.195.236", http.Header{"Cf-Connecting-Ip": {"203.0.113.5"}}); got != "203.0.113.5" {
		t.Fatalf("bare-IP trusted peer must trust CF; want 203.0.113.5, got %q", got)
	}
	// untrusted bare-IP peer → forged CF ignored, peer wins
	if got := serve(t, "176.12.22.76", http.Header{"Cf-Connecting-Ip": {"6.6.6.6"}}); got != "176.12.22.76" {
		t.Fatalf("bare-IP untrusted peer must ignore forged CF; want 176.12.22.76, got %q", got)
	}
}

// 12. New() must fail loudly on a malformed CIDR.
func TestNewErrorsOnMalformedCIDR(t *testing.T) {
	cfg := &Config{TrustedProxyCIDRs: []string{"not-a-cidr"}}
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {})
	if _, err := New(context.Background(), next, cfg, "test"); err == nil {
		t.Fatal("New must return an error for a malformed TrustedProxyCIDRs entry")
	}
}

// --- isPublic() edge cases, exercised through the trusted-peer header path.
// isPublic is unchanged but load-bearing to the anti-spoof behaviour. ---

// CGNAT 100.64/10 is not real client space → skipped for the public entry.
func TestTrustedPeerCGNATExcluded(t *testing.T) {
	got := serve(t, "10.10.195.236:5000", http.Header{
		"X-Forwarded-For": {"100.64.0.1, 203.0.113.7"},
	})
	if got != "203.0.113.7" {
		t.Fatalf("CGNAT entry must be skipped; want 203.0.113.7, got %q", got)
	}
}

// Unspecified/multicast entries must not shadow the real public IP.
func TestTrustedPeerUnspecifiedMulticastExcluded(t *testing.T) {
	got := serve(t, "10.10.195.236:5000", http.Header{
		"X-Forwarded-For": {"0.0.0.0, 224.0.0.1, 203.0.113.7"},
	})
	if got != "203.0.113.7" {
		t.Fatalf("unspecified/multicast entries must be skipped; want 203.0.113.7, got %q", got)
	}
}

// A public IPv6 XFF entry is accepted.
func TestTrustedPeerIPv6PublicXFF(t *testing.T) {
	got := serve(t, "10.10.195.236:5000", http.Header{
		"X-Forwarded-For": {"2606:4700:4700::1111"},
	})
	if got != "2606:4700:4700::1111" {
		t.Fatalf("public IPv6 XFF entry must be accepted; want 2606:4700:4700::1111, got %q", got)
	}
}

// A malformed Cf-Connecting-Ip falls through to the public XFF entry.
func TestTrustedPeerMalformedCFFallsThrough(t *testing.T) {
	got := serve(t, "10.10.195.236:5000", http.Header{
		"Cf-Connecting-Ip": {"not-an-ip"},
		"X-Forwarded-For":  {"203.0.113.9"},
	})
	if got != "203.0.113.9" {
		t.Fatalf("malformed CF must fall through to XFF; want 203.0.113.9, got %q", got)
	}
}
