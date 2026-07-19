package real_ip_plugin

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func serve(h http.Header) string {
	req := httptest.NewRequest("GET", "/", nil)
	req.Header = h
	var got string
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { got = r.Header.Get("X-Real-Ip") })
	rp, _ := New(nil, next, CreateConfig(), "t")
	rp.ServeHTTP(httptest.NewRecorder(), req)
	return got
}

func TestCFWins(t *testing.T) {
	if serve(http.Header{"Cf-Connecting-Ip": {"203.0.113.5"}, "X-Forwarded-For": {"198.51.100.9"}, "X-Real-Ip": {"10.10.1.1"}}) != "203.0.113.5" {
		t.Fatal("CF-Connecting-IP must win")
	}
}
func TestXFFPublicFallback(t *testing.T) {
	if serve(http.Header{"X-Forwarded-For": {"10.10.1.1, 203.0.113.7"}, "X-Real-Ip": {"10.10.1.1"}}) != "203.0.113.7" {
		t.Fatal("first public XFF entry must win over private")
	}
}
func TestHeaderlessLeavesPeer(t *testing.T) {
	if serve(http.Header{"X-Real-Ip": {"10.10.9.9"}}) != "10.10.9.9" {
		t.Fatal("no CF/XFF must leave the existing X-Real-Ip (non-empty)")
	}
}
func TestAllPrivateXFFLeavesPeer(t *testing.T) {
	if serve(http.Header{"X-Forwarded-For": {"10.0.0.1, 192.168.1.1"}, "X-Real-Ip": {"10.10.9.9"}}) != "10.10.9.9" {
		t.Fatal("all-private XFF must leave the existing X-Real-Ip")
	}
}
func TestCGNATExcluded(t *testing.T) {
	if serve(http.Header{"X-Forwarded-For": {"100.64.0.1, 203.0.113.7"}}) != "203.0.113.7" {
		t.Fatal("CGNAT 100.64/10 must be skipped in favour of the public entry")
	}
}
func TestUnspecifiedAndMulticastExcluded(t *testing.T) {
	if serve(http.Header{"X-Forwarded-For": {"0.0.0.0, 224.0.0.1, 203.0.113.7"}}) != "203.0.113.7" {
		t.Fatal("unspecified/multicast entries must not shadow the real public IP")
	}
}
func TestIPv6PublicXFF(t *testing.T) {
	if serve(http.Header{"X-Forwarded-For": {"2606:4700:4700::1111"}}) != "2606:4700:4700::1111" {
		t.Fatal("a public IPv6 XFF entry must be accepted")
	}
}
func TestMalformedCFFallsThrough(t *testing.T) {
	if serve(http.Header{"Cf-Connecting-Ip": {"not-an-ip"}, "X-Forwarded-For": {"203.0.113.9"}}) != "203.0.113.9" {
		t.Fatal("a malformed CF-Connecting-IP must fall through to XFF")
	}
}
