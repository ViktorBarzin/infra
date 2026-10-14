// Turns the live topology data (data.php) into a mermaid flowchart.
//
// One box per site (phpIPAM Location) holds its subnets and network devices;
// each device is joined to every subnet it holds an address in. A subnet with
// no Location, or with devices from more than one site on it (the WireGuard
// tunnels, the tailnet), sits above the sites with dotted links labelled with
// the live round-trip time. Loaded by index.html in the browser and by
// topology.test.js under node.
"use strict";

// A device is up when any of its addresses answers a ping.
function deviceState(device) {
  const probes = device.addresses.map((a) => a.probe).filter(Boolean);
  if (probes.length === 0) return "unknown";
  return probes.some((p) => p.up) ? "up" : "down";
}

// Subnet id -> the site it is drawn in, or null for between the sites.
function placement(subnets, devices) {
  const sites = new Map(subnets.map((s) => [s.id, new Set()]));
  for (const d of devices) {
    for (const a of d.addresses) sites.get(a.subnet)?.add(d.location);
  }
  const where = new Map();
  for (const s of subnets) {
    const others = [...sites.get(s.id)].filter((loc) => loc !== s.location);
    where.set(s.id, s.location && others.length === 0 ? s.location : null);
  }
  return where;
}

// Text safe inside a quoted mermaid label.
function label(text) {
  return String(text).replaceAll('"', "#quot;").replaceAll("<", "#lt;").replaceAll(">", "#gt;");
}

function subnetText(s) {
  let text = `<b>${label(s.cidr)}</b><br/>${label(s.description)}<br/>${s.addresses} addresses`;
  if (s.seen_hour > 0) text += `, ${s.seen_hour} seen in the last hour`;
  return text;
}

function siteId(name) {
  return "site_" + name.replace(/\W/g, "_");
}

function ipKey(cidr) {
  const [ip, mask] = cidr.split("/");
  return ip.split(".").reduce((n, octet) => n * 256 + Number(octet), 0) * 64 + Number(mask);
}

function buildMermaid(data) {
  const subnets = [...data.subnets].sort((a, b) => ipKey(a.cidr) - ipKey(b.cidr));
  const known = new Set(subnets.map((s) => s.id));
  const devices = [...data.devices]
    .map((d) => ({ ...d, addresses: d.addresses.filter((a) => known.has(a.subnet)) }))
    .filter((d) => d.addresses.length > 0)
    .sort((a, b) => a.name.localeCompare(b.name));
  const where = placement(subnets, devices);

  const subnetNode = (s) => `s${s.id}("${subnetText(s)}")`;
  const deviceNode = (d) => `d${d.id}["<b>${label(d.name)}</b><br/>${label(d.type)}"]`;

  const lines = ["flowchart TB"];
  const sites = [...new Set([...where.values(), ...devices.map((d) => d.location)].filter(Boolean))].sort();
  for (const site of sites) {
    lines.push(`  subgraph ${siteId(site)}["${label(site)}"]`);
    for (const d of devices) if (d.location === site) lines.push(`    ${deviceNode(d)}`);
    for (const s of subnets) if (where.get(s.id) === site) lines.push(`    ${subnetNode(s)}`);
    lines.push("  end");
  }
  for (const d of devices) if (!d.location) lines.push(`  ${deviceNode(d)}`);
  for (const s of subnets) if (where.get(s.id) === null) lines.push(`  ${subnetNode(s)}`);

  // Edge order sets the layers top to bottom: shared subnets, the devices that
  // join them, each site's subnets, then devices on one subnet only (a switch,
  // a Wi-Fi access point) hanging under it.
  for (const d of devices) {
    const subnetIds = [...new Set(d.addresses.map((a) => a.subnet))];
    for (const id of subnetIds) {
      if (where.get(id) === null) {
        const rtt = d.addresses.find((a) => a.subnet === id && a.probe?.up)?.probe.ms;
        if (rtt === undefined || rtt === null) lines.push(`  s${id} -.- d${d.id}`);
        else lines.push(`  s${id} -.-|${rtt < 1 ? label("<1") : Math.round(rtt)} ms| d${d.id}`);
      } else if (subnetIds.length === 1) {
        lines.push(`  s${id} --- d${d.id}`);
      } else {
        lines.push(`  d${d.id} --- s${id}`);
      }
    }
  }
  for (const s of subnets) lines.push(`  click s${s.id} "/subnets/${s.section}/${s.id}/" "Open ${s.cidr} in phpIPAM"`);
  for (const s of subnets) if (where.get(s.id) === null) lines.push(`  class s${s.id} shared`);
  for (const d of devices) lines.push(`  class d${d.id} ${deviceState(d)}`);
  lines.push(
    "  classDef up stroke:#2e9d5b,stroke-width:3px",
    "  classDef down stroke:#d0453b,stroke-width:3px,stroke-dasharray:6 4",
    "  classDef unknown stroke:#8a8a8a,stroke-width:2px",
    "  classDef shared stroke-dasharray:3 3",
  );
  return lines.join("\n") + "\n";
}

if (typeof module !== "undefined") {
  module.exports = { deviceState, placement, label, subnetText, buildMermaid };
}
