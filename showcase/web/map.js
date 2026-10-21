// Map variant: an exploded isometric drawing of the four layers, a detail
// panel, and a five-stop guided tour. All homelab facts come from data.json.
import {
  loadSnapshot, renderSwitcher, renderFooter, fmt, STATS, ACCESS, GATES,
  dnsLabel, BADGES, iconURL, escapeHTML,
} from "./shared.js";

const $ = (s) => document.querySelector(s);
const esc = escapeHTML;

// Map order, top to bottom. "operations" is drawn as the band beside them.
const STACK = ["apps", "platform", "network", "hardware"];
const TOUR = ["hardware", "network", "platform", "operations", "apps", "home"];
const TOUR_TITLES = {
  hardware: "The hardware",
  network: "The network",
  platform: "The platform",
  operations: "How it is run",
  apps: "The apps",
  home: "The house",
};

let snap, layers, statLabel;
const state = { open: null, tour: -1, group: null };

// ---------- isometric drawing ----------
const C = Math.cos(Math.PI / 6);
const P = (x, y, z = 0) => `${((x - y) * C).toFixed(1)},${((x + y) / 2 - z).toFixed(1)}`;
const poly = (pts, cls, extra = "") => `<polygon class="${cls}" points="${pts.join(" ")}"${extra}/>`;

// box draws an iso box with its three visible faces.
function box(x, y, w, d, h, z, cls = ["p-fill", "p-fill-2", "p-fill"], extra = "") {
  const t = z + h;
  return `<g${extra}>` +
    poly([P(x + w, y, z), P(x + w, y + d, z), P(x + w, y + d, t), P(x + w, y, t)], cls[0]) +
    poly([P(x, y + d, z), P(x + w, y + d, z), P(x + w, y + d, t), P(x, y + d, t)], cls[1]) +
    poly([P(x, y, t), P(x + w, y, t), P(x + w, y + d, t), P(x, y + d, t)], cls[2]) +
    `</g>`;
}

const W = 260, D = 150, T = 14;

function plateSVG(id, label) {
  let inner = "";
  if (id === "apps") inner = appsTiles();
  else if (id === "platform") inner = platformNodes();
  else if (id === "network") inner = networkSites();
  else if (id === "hardware") inner = hardwareKit();
  const conn = id === "hardware" ? "" :
    `<line class="p-conn" x1="${-D * C}" y1="${D / 2}" x2="${-D * C}" y2="${D / 2 + 70}"/>` +
    `<line class="p-conn" x1="${W * C}" y1="${W / 2}" x2="${W * C}" y2="${W / 2 + 70}"/>` +
    `<line class="p-conn" x1="${(W - D) * C}" y1="${(W + D) / 2}" x2="${(W - D) * C}" y2="${(W + D) / 2 + 70}"/>`;
  const minX = -D * C - 6, maxX = W * C + 6;
  return `<svg viewBox="${minX.toFixed(0)} -52 ${(maxX - minX).toFixed(0)} ${(W + D) / 2 + 64}" role="img" aria-label="${esc(label)}" focusable="false">` +
    conn + `<g class="plate">` + box(0, 0, W, D, T, 0, ["p-l", "p-r", "p-top"]) + inner + `</g></svg>`;
}

function appsTiles() {
  const svcs = [...snap.services].sort((a, b) => a.group.localeCompare(b.group) || a.name.localeCompare(b.name));
  const n = svcs.length;
  const cols = Math.max(1, Math.ceil(Math.sqrt((n * W) / D)));
  const rows = Math.ceil(n / cols);
  const cx = (W - 24) / cols, cy = (D - 24) / rows, s = Math.min(cx, cy) * 0.66;
  return svcs.map((svc, i) => {
    const x = 12 + (i % cols) * cx + (cx - s) / 2;
    const y = 12 + Math.floor(i / cols) * cy + (cy - s) / 2;
    return box(x, y, s, s, 4, T, ["p-fill", "p-fill-2", "p-fill tile"], ` data-group="${esc(svc.group)}"`);
  }).join("");
}

function platformNodes() {
  const nodes = snap.hardware.nodes;
  const cols = Math.ceil(nodes.length / 2);
  const cw = (W - 30) / cols, ch = (D - 30) / 2;
  const maxMem = Math.max(...nodes.map((n) => n.memory_gib));
  return nodes.map((n, i) => {
    const w = cw * 0.62, d = ch * 0.6;
    const x = 15 + (i % cols) * cw + (cw - w) / 2;
    const y = 15 + Math.floor(i / cols) * ch + (ch - d) / 2;
    const h = 8 + (n.memory_gib / maxMem) * 30;
    const top = n.gpu ? "p-fill p-hot" : "p-fill";
    return box(x, y, w, d, h, T, ["p-fill", "p-fill-2", top]);
  }).join("");
}

function networkSites() {
  const sites = snap.hardware.sites;
  const spots = [[W * 0.3, D * 0.55], [W * 0.78, D * 0.25], [W * 0.78, D * 0.8], [W * 0.5, D * 0.15], [W * 0.5, D * 0.88]];
  let s = "";
  const hub = spots[0];
  sites.slice(1).forEach((_, i) => {
    const p = spots[(i + 1) % spots.length];
    s += `<polyline class="p-link" points="${P(hub[0], hub[1], T)} ${P(p[0], p[1], T)}"/>`;
  });
  sites.forEach((_, i) => {
    const [x, y] = spots[i % spots.length];
    const r = i === 0 ? 20 : 12;
    s += box(x - r / 2, y - r / 2, r, r, i === 0 ? 14 : 8, T, ["p-fill", "p-fill-2", i === 0 ? "p-fill p-hot" : "p-fill"]);
  });
  // a ring of segment markers around the main site
  for (let a = 0; a < 6; a++) {
    const ang = (a / 6) * Math.PI * 2;
    s += `<circle class="p-dot" r="2.4" cx="${((hub[0] + Math.cos(ang) * 34 - (hub[1] + Math.sin(ang) * 34)) * C).toFixed(1)}" cy="${((hub[0] + Math.cos(ang) * 34 + hub[1] + Math.sin(ang) * 34) / 2 - T).toFixed(1)}"/>`;
  }
  return s;
}

function hardwareKit() {
  const sites = snap.hardware.sites;
  const weights = sites.map((st) => Math.max(st.kit.length, 1.5));
  const total = weights.reduce((a, b) => a + b, 0);
  let x0 = 10, s = "";
  sites.forEach((st, si) => {
    const rw = ((W - 20 - (sites.length - 1) * 8) * weights[si]) / total;
    s += `<polygon class="p-detail" stroke-dasharray="3 3" points="${[P(x0, 10, T), P(x0 + rw, 10, T), P(x0 + rw, D - 10, T), P(x0, D - 10, T)].join(" ")}"/>`;
    let cx = x0 + 8, cy = 18;
    st.kit.forEach((k) => {
      const big = Boolean(k.live);
      const w = big ? 34 : 15, d = big ? 26 : 15, h = big ? 22 : 8;
      if (cy + d > D - 14) { cy = 18; cx += 24; }
      s += box(cx, cy, Math.min(w, rw - 16), d, h, T, ["p-fill", "p-fill-2", big ? "p-fill p-hot" : "p-fill"]);
      cy += d + 10;
    });
    x0 += rw + 8;
  });
  return s;
}

// houseSVG draws the family home as a small house on its own plate, the Map's
// pointer to the Home view (HL-05).
function houseSVG() {
  const w = 110, d = 80, h = 34, r = 26, x = 25, y = 22;
  const roof =
    poly([P(x, y, h), P(x + w, y, h), P(x + w, y + d / 2, h + r), P(x, y + d / 2, h + r)], "p-r") +
    poly([P(x + w, y, h), P(x + w, y + d, h), P(x + w, y + d / 2, h + r)], "p-l") +
    poly([P(x, y + d, h), P(x + w, y + d, h), P(x + w, y + d / 2, h + r), P(x, y + d / 2, h + r)], "p-top");
  const door = poly([P(x + w, y + d * 0.42, 0), P(x + w, y + d * 0.6, 0), P(x + w, y + d * 0.6, 18), P(x + w, y + d * 0.42, 18)], "p-fill p-hot");
  const win = (u) => poly([P(x + u, y + d, 14), P(x + u + 16, y + d, 14), P(x + u + 16, y + d, 26), P(x + u, y + d, 26)], "p-fill-2");
  const pw = 160, pd = 124, minX = -pd * C - 6, maxX = pw * C + 6;
  return `<svg viewBox="${minX.toFixed(0)} -78 ${(maxX - minX).toFixed(0)} ${(pw + pd) / 2 + 92}" aria-hidden="true" focusable="false">` +
    `<g class="plate">` + box(0, 0, pw, pd, 8, 0, ["p-l", "p-r", "p-top"]) +
    `<g transform="translate(0,-8)">` + box(x, y, w, d, h, 0, ["p-fill", "p-fill-2", "p-fill"]) + door + win(18) + win(70) + roof + `</g>` +
    `</g></svg>`;
}

// ---------- labels ----------
function groups() {
  const m = new Map();
  for (const s of snap.services) m.set(s.group, (m.get(s.group) || 0) + 1);
  return [...m.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
}
const n = (k) => fmt.compact(snap.stats[k]);
const stat = (k) => ({ v: n(k), l: statLabel[k] });

function layerMeta(id) {
  const st = snap.stats;
  switch (id) {
    case "apps": return `${fmt.int(st.services)} services in ${groups().length} groups`;
    case "platform": return `${n("nodes")} Kubernetes nodes, ${n("pods")} running pods`;
    case "network": return `${n("requests_per_day")} requests a day`;
    case "hardware": return `${n("vms")} VMs on one server, ${snap.hardware.sites.length} sites`;
    case "operations": return `${n("commits_per_week")} infra commits a week`;
    default: return "";
  }
}

function renderMap() {
  const stack = $("#stack");
  stack.innerHTML = STACK.map((id, i) => {
    const L = layers[id];
    const num = STACK.length - i;
    return `<li><button type="button" class="layer" data-layer="${id}" aria-pressed="false" aria-controls="panel">
      ${plateSVG(id, `${L.title} layer`)}
      <span class="label">
        <span class="tag">L${num}</span>
        <span class="name">${esc(L.title)}</span>
        <span class="meta">${esc(layerMeta(id))}</span>
        <span class="open">Open &rarr;</span>
      </span></button></li>`;
  }).join("");

  const ops = layers.operations;
  $("#ops-slot").innerHTML = `<button type="button" class="ops-band" data-layer="operations" aria-pressed="false" aria-controls="panel">
    <svg viewBox="0 0 48 48" aria-hidden="true"><path d="M38 18a15 15 0 0 0-27-4"/><path d="M10 6v8h8"/><path d="M10 30a15 15 0 0 0 27 4"/><path d="M38 42v-8h-8"/></svg>
    <span class="txt">
      <span class="tag">Across all layers</span>
      <span class="name">${esc(ops.title)}</span>
      <span class="meta">${esc(layerMeta("operations"))}</span>
      <span class="open">Open &rarr;</span>
    </span></button>
    <a class="house" href="home.html" data-home>
      ${houseSVG()}
      <span class="txt">
        <span class="tag">HL-05 &middot; Home</span>
        <span class="name">The house</span>
        ${snap.home ? `<span class="meta">${esc(fmt.int(snap.home.counts.devices))} devices, ${esc(fmt.int(snap.home.counts.automations))} automations</span>` : ""}
        <span class="open">Open the Home view &rarr;</span>
      </span></a>`;

  document.querySelectorAll("[data-layer]").forEach((b) =>
    b.addEventListener("click", () => {
      if (state.tour >= 0) {
        const idx = TOUR.indexOf(b.dataset.layer);
        goTour(idx);
      } else {
        openLayer(b.dataset.layer, { scroll: true });
      }
    }));
}

// ---------- panel ----------
function kv(items) {
  return `<dl class="kv">${items.map((i) => `<div><dt>${esc(i.l)}</dt><dd>${esc(i.v)}</dd></div>`).join("")}</dl>`;
}
function docsHTML(docs) {
  if (!docs.length) return "";
  return `<h3>Design docs</h3><ul class="docs">${docs.map((d) => `<li>
    <strong>${esc(d.title)}</strong><p>${esc(d.summary)}</p>
    <a href="${esc(d.url)}">Read the doc &rarr;</a></li>`).join("")}</ul>`;
}
function bars(rows, total) {
  const max = Math.max(...rows.map((r) => r.n), 1);
  return `<ul class="bars">${rows.map((r) => `<li>
    <span class="bl">${esc(r.label)}</span><span class="bn">${fmt.int(r.n)}${total ? ` of ${fmt.int(total)}` : ""}</span>
    <span class="track" aria-hidden="true"><span class="fill" style="width:${((r.n / max) * 100).toFixed(1)}%"></span></span>
    ${r.detail ? `<span class="bd">${esc(r.detail)}</span>` : ""}</li>`).join("")}</ul>`;
}
function countBy(list, f) {
  const m = new Map();
  for (const x of list) for (const k of [].concat(f(x))) m.set(k, (m.get(k) || 0) + 1);
  return [...m.entries()].sort((a, b) => b[1] - a[1]);
}

function hardwareExtra() {
  const h = snap.hardware;
  const sites = `<h3>Sites and kit</h3><div class="sites">${h.sites.map((s) => `<div class="site">
    <strong>${esc(s.name)}</strong><p>${esc(s.role)}</p>
    <ul>${s.kit.map((k) => `<li><b>${esc(k.name)}${k.live ? `<span class="live">live</span>` : ""}</b><span>${esc(k.role)}</span></li>`).join("")}</ul>
  </div>`).join("")}</div>`;
  const nodes = `<h3>Kubernetes nodes</h3><table class="nodes"><thead><tr><th>Node</th><th>Role</th><th class="num">vCPU</th><th class="num">GiB</th></tr></thead><tbody>
    ${h.nodes.map((nd) => `<tr><td><code>${esc(nd.name)}</code>${nd.gpu ? ` <span class="live">GPU</span>` : ""}</td><td>${esc(nd.role)}</td><td class="num">${fmt.int(nd.cpu)}</td><td class="num">${fmt.compact(nd.memory_gib)}</td></tr>`).join("")}
  </tbody></table>`;
  return sites + nodes;
}

function networkExtra() {
  const svcs = snap.services;
  const gates = countBy(svcs, (s) => s.route.gates).map(([k, c]) => ({ label: GATES[k]?.label || k, detail: GATES[k]?.detail, n: c }));
  const dns = countBy(svcs, (s) => dnsLabel(s).label).map(([k, c]) => ({ label: k, detail: svcs.map(dnsLabel).find((d) => d.label === k)?.detail, n: c }));
  return `<h3>How requests reach the apps</h3>${bars(dns, svcs.length)}
    <h3>Gates in front of the apps</h3>${bars(gates, svcs.length)}`;
}

function platformExtra() {
  const b = countBy(Object.values(snap.graph.badges), (v) => v).map(([k, c]) => ({ label: BADGES[k] || k, n: c }));
  return `<h3>Shared services, by namespaces using them</h3>${bars(b)}`;
}

function appsExtra() {
  const gs = groups();
  const access = countBy(snap.services, (s) => s.access).map(([k, c]) => ({ label: ACCESS[k]?.label || k, detail: ACCESS[k]?.detail, n: c }));
  return `<h3>Groups</h3><div class="groups" role="group" aria-label="Service groups">${gs.map(([g, c]) =>
    `<button type="button" class="group" data-group="${esc(g)}" aria-pressed="${g === state.group}"><span>${esc(g)}</span><b>${c}</b></button>`).join("")}</div>
    <div id="svc-slot">${servicesHTML()}</div>
    <h3>How you log in</h3>${bars(access, snap.services.length)}`;
}

function servicesHTML() {
  if (!state.group) return `<p class="empty">Pick a group to list its services.</p>`;
  const list = snap.services.filter((s) => s.group === state.group).sort((a, b) => a.name.localeCompare(b.name));
  return `<h3>${esc(state.group)}</h3><ul class="svc-list">${list.map((s) => {
    const a = ACCESS[s.access];
    const icon = iconURL(s.icon);
    const letter = esc((s.name || "?").trim().charAt(0).toUpperCase());
    return `<li class="svc">
      ${icon ? `<img src="${esc(icon)}" alt="" loading="lazy" width="40" height="40" data-letter="${letter}">` : `<span class="avatar" aria-hidden="true">${letter}</span>`}
      <span class="nm">${esc(s.name)}</span>
      <span class="ds">${esc(s.description)}</span>
      <span class="row"><span class="chip ${esc(s.access)}" title="${esc(a?.detail || "")}">${esc(a?.label || s.access)}</span>
      ${s.stack_url ? `<a class="tf" href="${esc(s.stack_url)}">Terraform &rarr;</a>` : ""}</span>
    </li>`;
  }).join("")}</ul>`;
}

function wireServices(root) {
  root.querySelectorAll("img[data-letter]").forEach((img) => {
    img.addEventListener("error", () => {
      const span = document.createElement("span");
      span.className = "avatar";
      span.setAttribute("aria-hidden", "true");
      span.textContent = img.dataset.letter;
      img.replaceWith(span);
    }, { once: true });
  });
}

function highlightGroup() {
  document.querySelectorAll(".tile").forEach((t) => {
    const g = t.parentElement.dataset.group;
    t.classList.toggle("p-hot", Boolean(state.group) && g === state.group);
  });
}

function layerStats(id) {
  const st = snap.stats;
  switch (id) {
    case "hardware": return [
      { v: fmt.compact(st.host_threads), l: "CPU threads on the host" },
      { v: fmt.compact(st.host_memory_gib), l: "GiB of host RAM" },
      stat("storage_tb"), stat("vms"), stat("nodes"),
    ];
    case "network": return [stat("requests_per_day"), { v: fmt.int(snap.services.length), l: "services behind the ingress" }];
    case "platform": return [stat("stacks"), stat("pods"), stat("cores"), stat("memory_gib")];
    case "operations": return [stat("commits_per_week"), stat("ci_runs_per_week"), stat("agent_fixes_30d")];
    case "apps": return [stat("services"), { v: String(groups().length), l: "groups" }];
    default: return [];
  }
}

function homePanelHTML() {
  const h = snap.home;
  const open = `<div class="hero-actions" style="margin:18px 0 0"><a class="btn btn-primary" href="home.html">Open the Home view <span aria-hidden="true">&rarr;</span></a></div>`;
  if (!h) {
    return `<div><p class="panel-tag">Beyond the cluster</p><h2 id="panel-title">The house</h2>
      <p class="intro">The family home runs on one Home Assistant instance on the same server. Its numbers are unavailable right now.</p>${open}</div>`;
  }
  const c = h.counts;
  return `<div><p class="panel-tag">Beyond the cluster</p><h2 id="panel-title">The house</h2>
    <p class="intro">One Home Assistant instance, a VM on the same server as the cluster, runs the family home${h.site ? ` in ${esc(h.site)}` : ""}.</p>
    ${kv([
      { v: fmt.compact(c.devices), l: "devices" },
      { v: fmt.compact(c.integration_kinds), l: "kinds of integration" },
      { v: fmt.compact(c.automations), l: "automations" },
      { v: fmt.compact(c.dashboards), l: "dashboards" },
    ])}
    ${(h.highlights || []).length ? `<h3>How it works</h3><ul class="docs">${h.highlights.map((x) => `<li><strong>${esc(x.title)}</strong></li>`).join("")}</ul>` : ""}
    ${open}</div>`;
}

function panelHTML(id) {
  if (id === "home") return homePanelHTML();
  const L = layers[id];
  const where = id === "operations" ? "Across all layers" : `Layer ${STACK.length - STACK.indexOf(id)} of ${STACK.length}`;
  const extra = { hardware: hardwareExtra, network: networkExtra, platform: platformExtra, apps: appsExtra }[id];
  const mini = STACK.includes(id) ? `<div class="panel-plate" aria-hidden="true">${plateSVG(id, "")}</div>` : "";
  return `<div>${mini}<p class="panel-tag">${where}</p><h2 id="panel-title">${esc(L.title)}</h2>
    ${kv(layerStats(id))}
    ${docsHTML(L.docs)}
    ${extra ? extra() : ""}</div>`;
}

function introHTML() {
  return `<div><p class="panel-tag">Start here</p><h2>Pick a layer</h2>
    <p class="intro">Tap any layer on the map to read how it works and open its design docs, or take the tour through all ${TOUR.length === 6 ? "six" : TOUR.length} stops, from the hardware up to the apps and the house they run.</p>
    <div class="hero-actions" style="margin:18px 0 0"><button type="button" class="btn btn-primary" data-start-tour>Take the tour <span aria-hidden="true">&rarr;</span></button></div></div>`;
}

function setPressed() {
  document.querySelectorAll("[data-layer]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.layer === state.open)));
  document.querySelector("[data-home]")?.classList.toggle("is-open", state.open === "home");
  $("#map").classList.toggle("touring", state.tour >= 0);
}

function openLayer(id, { scroll = false, keepGroup = false } = {}) {
  if (!layers[id] && id !== "home") return;
  if (!keepGroup && id !== state.open) state.group = null;
  state.open = id;
  const body = $("#panel-body");
  body.innerHTML = panelHTML(id);
  wireServices(body);
  body.querySelectorAll(".group").forEach((g) => g.addEventListener("click", () => {
    state.group = state.group === g.dataset.group ? null : g.dataset.group;
    body.querySelectorAll(".group").forEach((x) => x.setAttribute("aria-pressed", String(x.dataset.group === state.group)));
    const slot = body.querySelector("#svc-slot");
    slot.innerHTML = servicesHTML();
    wireServices(slot);
    highlightGroup();
  }));
  highlightGroup();
  setPressed();
  $("#panel").scrollTop = 0;
  if (state.tour < 0) history.replaceState(null, "", `#${id}`);
  if (scroll && window.matchMedia("(max-width: 900px)").matches) {
    $("#panel").scrollIntoView({ behavior: "smooth", block: "start" });
  }
}

// ---------- tour ----------
function renderTourbar() {
  const bar = $("#tourbar");
  if (state.tour < 0) { bar.hidden = true; bar.innerHTML = ""; return; }
  const i = state.tour, last = TOUR.length - 1;
  bar.hidden = false;
  bar.innerHTML = `<div class="tour-row"><span class="tour-step">Tour &middot; stop ${i + 1} of ${TOUR.length}</span>
      <button type="button" class="tour-exit" data-tour-exit>End tour</button></div>
    <div class="tour-progress" role="group" aria-label="Tour progress" style="grid-template-columns:repeat(${TOUR.length},1fr)">${TOUR.map((id, k) =>
      `<button type="button" data-tour-go="${k}" aria-label="Stop ${k + 1}: ${esc(TOUR_TITLES[id])}" class="${k < i ? "done" : ""}"${k === i ? ' aria-current="step"' : ""}></button>`).join("")}</div>
    <div class="tour-row"><div class="tour-nav">
      <button type="button" class="btn" data-tour-prev${i === 0 ? " disabled" : ""}><span aria-hidden="true">&larr;</span> Back</button>
      <button type="button" class="btn btn-primary" data-tour-next>${i === last ? "Finish" : "Next"} <span aria-hidden="true">&rarr;</span></button>
    </div><p class="tour-hint">Arrow keys work too.</p></div>`;
  bar.querySelector("[data-tour-prev]").addEventListener("click", () => goTour(state.tour - 1));
  bar.querySelector("[data-tour-next]").addEventListener("click", () => (state.tour === last ? endTour() : goTour(state.tour + 1)));
  bar.querySelector("[data-tour-exit]").addEventListener("click", endTour);
  bar.querySelectorAll("[data-tour-go]").forEach((b) => b.addEventListener("click", () => goTour(+b.dataset.tourGo)));
}

function goTour(i) {
  if (i < 0 || i >= TOUR.length) return;
  state.tour = i;
  openLayer(TOUR[i]);
  renderTourbar();
  history.replaceState(null, "", `#tour-${i + 1}`);
  const panel = $("#panel");
  if (window.matchMedia("(max-width: 900px)").matches) {
    panel.scrollIntoView({ behavior: "smooth", block: "start" });
  } else {
    const r = panel.getBoundingClientRect();
    if (r.top < 0 || r.top > window.innerHeight * 0.6) panel.scrollIntoView({ behavior: "smooth", block: "start" });
  }
  panel.focus({ preventScroll: true });
}

function endTour() {
  const id = state.open;
  state.tour = -1;
  renderTourbar();
  setPressed();
  history.replaceState(null, "", id ? `#${id}` : location.pathname);
}

document.addEventListener("keydown", (e) => {
  if (state.tour < 0 || e.altKey || e.ctrlKey || e.metaKey) return;
  if (e.target.closest && e.target.closest("input, textarea, select")) return;
  if (e.key === "ArrowRight") { e.preventDefault(); state.tour === TOUR.length - 1 ? endTour() : goTour(state.tour + 1); }
  else if (e.key === "ArrowLeft") { e.preventDefault(); goTour(state.tour - 1); }
  else if (e.key === "Escape") endTour();
});

// ---------- boot ----------
function renderHero() {
  const st = snap.stats;
  const server = snap.hardware.sites.flatMap((s) => s.kit).find((k) => k.live === "proxmox");
  $("#lede").innerHTML =
    `${server ? `One <strong>${esc(server.name)}</strong> running ${n("vms")} VMs, ` : ""}` +
    `a <strong>${n("nodes")}-node Kubernetes cluster</strong> and <strong>${fmt.int(st.services)} self-hosted services</strong>, ` +
    `all in <strong>${n("stacks")} Terraform stacks</strong>.`;
  $("#stats").innerHTML = STATS.filter((s) => st[s.key] != null)
    .map((s) => `<div><dt>${esc(s.label)}</dt><dd>${esc(fmt.compact(st[s.key]))}</dd></div>`).join("");
  const at = new Date(snap.generated.at);
  $("#rev").textContent = `${snap.generated.commit ? `rev ${snap.generated.commit.slice(0, 7)}, ` : ""}${at.toLocaleDateString(undefined, { dateStyle: "medium" })}`;
}

async function main() {
  renderSwitcher($("#switcher"), "index.html");
  try {
    snap = await loadSnapshot();
  } catch (err) {
    $("#lede").textContent = `Could not load the snapshot: ${err.message}`;
    return;
  }
  layers = Object.fromEntries(snap.layers.map((l) => [l.id, l]));
  statLabel = Object.fromEntries(STATS.map((s) => [s.key, s.label]));
  renderHero();
  renderMap();
  renderFooter($("#footer"), snap);

  document.addEventListener("click", (e) => {
    if (e.target.closest("[data-start-tour]")) goTour(0);
  });
  $("#tour-start").addEventListener("click", () => goTour(0));

  const h = location.hash.slice(1);
  const tm = /^tour-(\d)$/.exec(h);
  if (tm) goTour(Math.min(TOUR.length, Math.max(1, +tm[1])) - 1);
  else if (layers[h] || h === "home") openLayer(h);
  else $("#panel-body").innerHTML = introHTML();
}

main();
