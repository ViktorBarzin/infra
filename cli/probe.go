package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"strings"
	"time"
)

// internalLBIP is the dedicated Traefik LB; every internal ingress routes through it.
const internalLBIP = "10.0.20.203"

// clientDialingIP returns an http.Client that dials ip for ANY host while keeping
// the URL host as SNI (so the cert matches) — the Go form of `curl --resolve
// host:443:ip`. TLS verification is skipped (these are reachability/observability
// probes, not security checks; internal .lan vhosts may serve a non-matching cert).
func clientDialingIP(ip string, timeout time.Duration) *http.Client {
	d := &net.Dialer{Timeout: 8 * time.Second}
	tr := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			if i := strings.LastIndex(addr, ":"); i >= 0 {
				addr = ip + addr[i:]
			}
			return d.DialContext(ctx, network, addr)
		},
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}
	return &http.Client{Timeout: timeout, Transport: tr}
}

// probeURL issues a GET and returns status code + elapsed time.
func probeURL(c *http.Client, rawurl string) (int, time.Duration, error) {
	start := time.Now()
	resp, err := c.Get(rawurl)
	dur := time.Since(start)
	if err != nil {
		return 0, dur, err
	}
	resp.Body.Close()
	return resp.StatusCode, dur, nil
}

// lbGetBody GETs https://<host><path>?<q> through the internal LB and returns the body.
func lbGetBody(host, path string, q url.Values) ([]byte, error) {
	u := "https://" + host + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	resp, err := clientDialingIP(internalLBIP, 20*time.Second).Get(u)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%s -> %d: %s", path, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return body, nil
}

// dig runs `dig +short` against a resolver, optionally for a record type.
func dig(name, server, rrtype string) (string, error) {
	args := []string{"+short", "+time=3", "+tries=1"}
	if rrtype != "" {
		args = append(args, rrtype)
	}
	args = append(args, name, "@"+server)
	out, err := exec.Command("dig", args...).Output()
	return strings.TrimSpace(string(out)), err
}
