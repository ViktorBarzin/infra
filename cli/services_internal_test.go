package main

import (
	"strings"
	"testing"
)

// The catalog was ingress-only, so anything without a web page was invisible to
// agents — including the cluster VPN egress proxy, which is a ClusterIP with no
// ingress ON PURPOSE (an ingress would publish an open, unauthenticated proxy
// through Traefik). These tests cover listing catalog-enabled Services too, so a
// cluster-internal capability can be discovered without being exposed.

const internalSvcJSON = `{"items":[
 {"metadata":{"name":"proxy-egress-uk","namespace":"proxy","annotations":{
   "gethomepage.dev/enabled":"true",
   "gethomepage.dev/name":"VPN egress (UK)",
   "gethomepage.dev/description":"Egress via NordVPN UK",
   "homelab/endpoint":"proxy-egress-uk.proxy.svc.cluster.local:8888"}},
  "spec":{"clusterIP":"10.105.237.194","ports":[{"port":8888},{"port":1080}]}},
 {"metadata":{"name":"not-in-catalog","namespace":"proxy","annotations":{}},
  "spec":{"clusterIP":"10.96.0.9","ports":[{"port":80}]}},
 {"metadata":{"name":"headless","namespace":"x","annotations":{
   "gethomepage.dev/enabled":"true","gethomepage.dev/name":"Headless"}},
  "spec":{"clusterIP":"None","ports":[{"port":80}]}}
]}`

func TestParseInternalServicesKeepsOnlyAnnotatedOnes(t *testing.T) {
	got, err := parseInternalServices(internalSvcJSON)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 catalog-enabled Service, got %d: %+v", len(got), got)
	}
	if got[0].Name != "VPN egress (UK)" {
		t.Errorf("name = %q", got[0].Name)
	}
}

func TestParseInternalServicesUsesTheExplicitEndpoint(t *testing.T) {
	// A Service can expose several ports, so the CONNECTABLE address cannot be
	// derived — the annotation states which one a consumer should use.
	got, _ := parseInternalServices(internalSvcJSON)
	if got[0].Host != "proxy-egress-uk.proxy.svc.cluster.local:8888" {
		t.Errorf("host = %q, want the annotated endpoint", got[0].Host)
	}
}

func TestParseInternalServicesSkipsHeadless(t *testing.T) {
	// A headless Service has no ClusterIP to connect to; listing it would give
	// an agent an address that does not answer.
	got, _ := parseInternalServices(internalSvcJSON)
	for _, s := range got {
		if s.Name == "Headless" {
			t.Errorf("headless Service should not be catalogued: %+v", s)
		}
	}
}

func TestInternalServicesAreMarkedNotWebFacing(t *testing.T) {
	// The inventory prints hostnames a human can open in a browser. A
	// cluster-internal endpoint is not one, and must not read as though it is.
	got, _ := parseInternalServices(internalSvcJSON)
	if !got[0].Internal {
		t.Error("a Service-derived row must be flagged Internal")
	}
	rendered := formatCatalog(got, "")
	if !strings.Contains(rendered, "in-cluster") {
		t.Errorf("catalog must mark internal rows; got:\n%s", rendered)
	}
}

func TestIngressRowsStayExternal(t *testing.T) {
	ing, err := parseServices(`{"items":[{"metadata":{"name":"echo","namespace":"x",
	 "annotations":{"gethomepage.dev/enabled":"true","gethomepage.dev/name":"Echo"}},
	 "spec":{"rules":[{"host":"echo.viktorbarzin.me"}]}}]}`)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(ing) != 1 || ing[0].Internal {
		t.Errorf("ingress-derived rows must not be flagged Internal: %+v", ing)
	}
}

func TestRoutingTableNamesTheEgressMoment(t *testing.T) {
	// Per the 2026-08-15 blind-agent tests, an inventory entry alone does not
	// change behaviour — the routing table naming the MOMENT is what does.
	var found bool
	for _, r := range routingTable() {
		if strings.Contains(strings.ToLower(r[0]), "country") ||
			strings.Contains(strings.ToLower(r[0]), "our ip") {
			found = true
			if !strings.Contains(r[1], "proxy-egress") {
				t.Errorf("egress routing row must name the endpoint, got %q", r[1])
			}
		}
	}
	if !found {
		t.Error("routing table has no row for 'request must not come from our IP'")
	}
}
