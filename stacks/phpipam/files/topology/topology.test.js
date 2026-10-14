// Unit tests for topology.js.
// Run with: node --test stacks/phpipam/files/topology/topology.test.js
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const t = require("./topology.js");

const probe = (up, ms = 4) => ({ up, ms });

function subnet(id, cidr, description, location, addresses = 1, seen = 1) {
  return { id, section: 3, cidr, description, location, addresses, seen_hour: seen };
}

function device(id, name, type, location, addresses) {
  return { id, name, type, location, addresses };
}

const LAN = subnet(9, "192.168.1.0/24", "Sofia LAN", "Sofia", 51, 42);
const K8S = subnet(8, "10.0.20.0/24", "Kubernetes", "Sofia");
const LONDON = subnet(11, "192.168.8.0/24", "London LAN", "London");
const WG = subnet(10, "10.3.2.0/24", "WireGuard", "Sofia");
const TAILNET = subnet(16, "100.64.0.0/10", "Headscale", null, 11, 0);

const PFSENSE = device(3, "pfsense", "Firewall", "Sofia", [
  { ip: "192.168.1.2", subnet: 9, probe: probe(true, 1) },
  { ip: "10.0.20.1", subnet: 8, probe: probe(true, 1) },
  { ip: "10.3.2.1", subnet: 10, probe: probe(true, 1) },
]);
const FLINT = device(18, "flint-london", "Router", "London", [
  { ip: "192.168.8.1", subnet: 11, probe: probe(true, 39) },
  { ip: "10.3.2.6", subnet: 10, probe: probe(true, 41.4) },
]);
const AP = device(5, "wifi-garaj", "Wireless", "Sofia", [{ ip: "192.168.1.7", subnet: 9, probe: probe(true) }]);

const DATA = { subnets: [LAN, K8S, LONDON, WG, TAILNET], devices: [PFSENSE, FLINT, AP] };

test("device state", () => {
  const cases = [
    [[probe(true)], "up"],
    [[probe(false), probe(true)], "up"], // any address answering is enough
    [[probe(false)], "down"],
    [[null], "unknown"], // the probe itself could not run
    [[], "unknown"],
  ];
  for (const [probes, want] of cases) {
    const d = device(1, "x", "Router", "Sofia", probes.map((p, i) => ({ ip: `10.0.0.${i}`, subnet: 1, probe: p })));
    assert.equal(t.deviceState(d), want, JSON.stringify(probes));
  }
});

test("placement", () => {
  const where = t.placement(DATA.subnets, DATA.devices);
  assert.equal(where.get(9), "Sofia");
  assert.equal(where.get(11), "London");
  assert.equal(where.get(10), null); // routers from two sites sit on it
  assert.equal(where.get(16), null); // no Location in phpIPAM
});

test("label escapes mermaid syntax", () => {
  assert.equal(t.label('a "b" <c>'), "a #quot;b#quot; #lt;c#gt;");
});

test("subnet text", () => {
  assert.equal(t.subnetText(LAN), "<b>192.168.1.0/24</b><br/>Sofia LAN<br/>51 addresses, 42 seen in the last hour");
  assert.equal(t.subnetText(TAILNET), "<b>100.64.0.0/10</b><br/>Headscale<br/>11 addresses");
});

test("mermaid layout", () => {
  const out = t.buildMermaid(DATA);
  assert.match(out, /^flowchart TB\n/);
  assert.ok(out.includes('subgraph site_Sofia["Sofia"]'));
  assert.ok(out.includes('subgraph site_London["London"]'));
  const wg = out.split("\n").find((l) => l.trimStart().startsWith("s10("));
  assert.ok(!wg.startsWith("    "), "shared subnet is drawn outside the site boxes");
  // Shared subnet above the routers, dotted, labelled with the live round trip.
  assert.ok(out.includes("s10 -.-|1 ms| d3"));
  assert.ok(out.includes("s10 -.-|41 ms| d18"));
  // Router above its site's subnets; a one-subnet device hangs below its subnet.
  assert.ok(out.includes("d3 --- s9"));
  assert.ok(out.includes("s9 --- d5"));
  assert.ok(out.includes('click s9 "/subnets/3/9/"'));
  assert.ok(out.includes("class d18 up"));
});

test("round trip under a millisecond", () => {
  const fast = device(3, "pfsense", "Firewall", "Sofia", [
    { ip: "10.0.20.1", subnet: 8, probe: probe(true, 0.4) },
    { ip: "10.3.2.1", subnet: 10, probe: probe(true, 0.4) },
  ]);
  const out = t.buildMermaid({ subnets: [K8S, LONDON, WG], devices: [fast, FLINT] });
  assert.ok(out.includes("s10 -.-|#lt;1 ms| d3"));
});

test("down tunnel has no round-trip label", () => {
  const dead = device(22, "m3", "Router", "Mladost 3", [
    { ip: "192.168.3.1", subnet: 15, probe: probe(false) },
    { ip: "10.3.2.7", subnet: 10, probe: probe(false) },
  ]);
  const m3 = subnet(15, "192.168.3.0/24", "Mladost 3 LAN", "Mladost 3");
  const out = t.buildMermaid({ subnets: [LAN, m3, WG], devices: [PFSENSE, dead] });
  assert.ok(out.includes("s10 -.- d22"));
  assert.ok(out.includes("class d22 down"));
});

test("output does not depend on input order", () => {
  const shuffled = { subnets: [...DATA.subnets].reverse(), devices: [...DATA.devices].reverse() };
  assert.equal(t.buildMermaid(shuffled), t.buildMermaid(DATA));
});
