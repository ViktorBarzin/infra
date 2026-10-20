// Shared by every Showcase Variant (ADR-0037): loading the Snapshot, the
// switcher between Variants, the footer, and the labels that turn Snapshot
// values into words. Each Variant styles the switcher and footer itself.
// Paths stay relative: the page is served under /homelab/.

export const VARIANTS = [
  { href: "index.html", label: "Map" },
  { href: "request.html", label: "Follow a request" },
  { href: "graph.html", label: "Graph" },
  { href: "catalog.html", label: "Catalog" },
];

export async function loadSnapshot() {
  const r = await fetch("data.json", { cache: "no-cache" });
  const type = r.headers.get("content-type") || "";
  // A missing data.json can come back as index.html with a 200 (Caddy
  // try_files), so check the type rather than trusting the status alone.
  if (!r.ok || !type.includes("json")) {
    throw new Error(`data.json unavailable (${r.status} ${type})`);
  }
  return r.json();
}

// renderSwitcher fills el with links to every Variant, marking the current one.
export function renderSwitcher(el, current) {
  el.classList.add("sc-switcher");
  el.setAttribute("aria-label", "Ways to explore");
  el.innerHTML = VARIANTS.map(
    (v) =>
      `<a href="${v.href}"${v.href === current ? ' aria-current="page"' : ""}>${v.label}</a>`,
  ).join("");
}

export function renderFooter(el, snap) {
  const at = new Date(snap.generated.at);
  const commit = snap.generated.commit || "";
  el.classList.add("sc-footer");
  el.innerHTML =
    `Generated ${at.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })} from live state` +
    (commit
      ? ` at <a href="https://github.com/ViktorBarzin/infra/commit/${commit}">${commit.slice(0, 8)}</a>`
      : "") +
    `. Everything here is declared in <a href="https://github.com/ViktorBarzin/infra">the public infra repo</a>.`;
}

export const fmt = {
  int: (n) => Math.round(n).toLocaleString("en-GB"),
  // 440850 -> "441k", 12.69 -> "12.7"
  compact: (n) =>
    n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e4 ? `${Math.round(n / 1e3)}k` : n >= 100 ? fmt.int(n) : `${+n.toFixed(1)}`,
};

// STATS lists the headline numbers in display order.
export const STATS = [
  { key: "services", label: "services" },
  { key: "stacks", label: "Terraform stacks" },
  { key: "pods", label: "running pods" },
  { key: "nodes", label: "Kubernetes nodes" },
  { key: "cores", label: "vCPUs in the cluster" },
  { key: "memory_gib", label: "GiB of cluster RAM" },
  { key: "vms", label: "VMs on one server" },
  { key: "storage_tb", label: "TB of storage" },
  { key: "requests_per_day", label: "requests a day" },
  { key: "commits_per_week", label: "infra commits a week" },
  { key: "ci_runs_per_week", label: "CI runs a week" },
  { key: "agent_fixes_30d", label: "broken-service reports fixed by an AI agent in 30 days" },
];

export const ACCESS = {
  sso: { label: "Single sign-on", detail: "Authentik checks who you are before the app sees the request." },
  app: { label: "App login", detail: "The app has its own login." },
  lan: { label: "Home networks only", detail: "Reachable from the home networks and the VPN, nowhere else." },
};

export const GATES = {
  crowdsec: { label: "CrowdSec", detail: "Drops IPs with a bad reputation before Traefik routes anything." },
  turnstile: { label: "Cloudflare Turnstile", detail: "A browser check that keeps bots off the page." },
  anubis: { label: "Anubis", detail: "A proof-of-work challenge for browsers that fail Turnstile." },
  "ai-bot-block": { label: "AI crawler block", detail: "Known AI scrapers are turned away." },
  "rate-limit": { label: "Rate limit", detail: "Caps how fast one client can send requests." },
  "lan-only": { label: "Home networks only", detail: "Requests from outside the home networks and the VPN are refused." },
  authentik: { label: "Authentik SSO", detail: "Single sign-on: log in once, reach every app you are allowed to." },
};

export function dnsLabel(service) {
  if (service.host.endsWith(".lan")) {
    return { label: "Internal DNS", detail: "Technitium resolves the name inside the home networks only." };
  }
  switch (service.route.dns) {
    case "non-proxied":
      return { label: "Straight to the home IP", detail: "Cloudflare DNS points at the home connection; no proxy in between." };
    case "internal":
      return { label: "LAN address", detail: "The public name resolves to an internal address, so it only works at home or on the VPN." };
    default:
      return { label: "Cloudflare tunnel", detail: "Cloudflare proxies the request through a tunnel; the home IP is never exposed." };
  }
}

export const STORAGE = {
  "proxmox-lvm-encrypted": "Encrypted block volume (LUKS)",
  "proxmox-lvm": "Block volume on Proxmox",
  "nfs-pve": "NFS share on Proxmox",
  "nfs-truenas": "NFS share",
  "nfs-synology": "NFS share on the Synology",
  "local-path": "Node-local disk",
};

export const BADGES = { postgres: "PostgreSQL", mysql: "MySQL", redis: "Redis", vault: "Vault", mail: "Mail" };

// iconURL resolves a Homepage icon name the way Homepage does: mdi-* from
// Material Design Icons, si-* from Simple Icons, anything else from the
// dashboard-icons set. Callers fall back to a letter avatar when the image
// fails to load. mdi and si glyphs are black SVGs, so callers may want to
// invert them on dark backgrounds.
export function iconURL(icon) {
  if (!icon) return "";
  if (/^https?:/.test(icon)) return icon;
  if (icon.startsWith("mdi-")) return `https://cdn.jsdelivr.net/npm/@mdi/svg@7.4.47/svg/${icon.slice(4)}.svg`;
  if (icon.startsWith("si-")) return `https://cdn.jsdelivr.net/npm/simple-icons@13.21.0/icons/${icon.slice(3)}.svg`;
  const name = icon.replace(/\.(png|svg)$/, "");
  return `https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons@main/png/${name}.png`;
}

// isGlyphIcon reports whether iconURL returns a single-colour glyph (mdi/si)
// rather than a full-colour logo, so a dark theme can invert it.
export const isGlyphIcon = (icon) => /^(mdi|si)-/.test(icon || "");

export function escapeHTML(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
