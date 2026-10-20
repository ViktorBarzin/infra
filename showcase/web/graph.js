// Live service graph: namespaces as points, observed traffic as lines.
// The layout is a small force simulation written here (repulsion, springs,
// centring, cooling); namespaces without traffic sit in an outer ring grouped
// by service group. Everything is drawn in screen space so nodes and labels
// keep a legible size at every zoom level.
import { loadSnapshot, renderSwitcher, renderFooter, fmt, ACCESS, BADGES, iconURL, escapeHTML } from "./shared.js";

const SVGNS = "http://www.w3.org/2000/svg";
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const BADGE_ORDER = ["postgres", "mysql", "redis", "vault", "mail"];
const GROUP_TOKENS = {
  "Core Platform": "core", Infrastructure: "infra", "Media & Entertainment": "media",
  Productivity: "prod", "Development & CI": "dev", "Identity & Security": "sec",
  "Smart Home": "home", "AI & Data": "ai", Automation: "auto", Finance: "fin",
  "Finance & Personal": "fin", Other: "other",
};
const FALLBACK = ["core", "media", "prod", "dev", "sec", "home", "ai", "auto", "fin", "infra", "other"];

function groupColor(g) {
  let t = GROUP_TOKENS[g];
  if (!t) {
    let h = 0;
    for (const c of g) h = (h * 31 + c.charCodeAt(0)) >>> 0;
    t = FALLBACK[h % FALLBACK.length];
  }
  return `var(--g-${t})`;
}

// ---------- model ----------

function labelFor(ns, svcs) {
  if (!svcs.length) return ns;
  if (svcs.length === 1) return svcs[0].name;
  const words = svcs.map((s) => s.name.split(/\s+/));
  const common = [];
  for (let i = 0; ; i++) {
    const w = words[0][i];
    if (!w || !words.every((ws) => (ws[i] || "").toLowerCase() === w.toLowerCase())) break;
    common.push(w);
  }
  const c = common.join(" ").replace(/[\s(:\-]+$/, "");
  return c.length >= 3 ? c : ns;
}

function groupFor(svcs) {
  const count = new Map();
  for (const s of svcs) count.set(s.group, (count.get(s.group) || 0) + 1);
  let best = "Other", n = 0;
  for (const [g, c] of count) if (c > n) { best = g; n = c; }
  return best;
}

function buildModel(snap) {
  const byNs = new Map();
  for (const s of snap.services) {
    if (!byNs.has(s.namespace)) byNs.set(s.namespace, []);
    byNs.get(s.namespace).push(s);
  }
  const badges = snap.graph.badges || {};
  const nodes = [...new Set(snap.graph.nodes)].map((ns) => {
    const services = byNs.get(ns) || [];
    const group = groupFor(services);
    return {
      id: ns, services, group, color: groupColor(group), label: labelFor(ns, services),
      badges: (badges[ns] || []).filter((b) => BADGES[b]).sort((a, b) => BADGE_ORDER.indexOf(a) - BADGE_ORDER.indexOf(b)),
      out: [], in: [], x: 0, y: 0, vx: 0, vy: 0,
    };
  });
  const idx = new Map(nodes.map((n) => [n.id, n]));
  const edges = snap.graph.edges
    .filter((e) => idx.has(e.src) && idx.has(e.dst) && e.src !== e.dst)
    .map((e) => ({ s: idx.get(e.src), t: idx.get(e.dst), flows: e.flows }))
    .sort((a, b) => a.flows - b.flows);
  for (const e of edges) {
    e.s.out.push({ n: e.t, flows: e.flows });
    e.t.in.push({ n: e.s, flows: e.flows });
  }
  for (const n of nodes) {
    n.nbrs = new Set([...n.out.map((o) => o.n), ...n.in.map((o) => o.n)]);
    n.degree = n.nbrs.size;
    n.flows = [...n.out, ...n.in].reduce((a, o) => a + o.flows, 0);
    n.out.sort((a, b) => b.flows - a.flows);
    n.in.sort((a, b) => b.flows - a.flows);
    n.core = n.degree > 0;
    n.r = n.core ? 4.5 + 2.4 * Math.sqrt(n.degree) : 3.6;
  }
  return { nodes, edges, idx };
}

// ---------- force layout ----------

function makeSim(core, edges) {
  const links = edges.filter((e) => e.s.core && e.t.core);
  const cnt = new Map();
  for (const l of links) {
    cnt.set(l.s, (cnt.get(l.s) || 0) + 1);
    cnt.set(l.t, (cnt.get(l.t) || 0) + 1);
  }
  const springs = links.map((l) => {
    const a = cnt.get(l.s), b = cnt.get(l.t);
    return { s: l.s, t: l.t, k: 0.9 / Math.min(a, b), bias: a / (a + b), len: 58 };
  });
  const charge = (n) => -160 - 34 * n.degree;
  let gx = 0.05, gy = 0.05;

  function tick(alpha) {
    const N = core.length;
    for (let i = 0; i < N; i++) {
      const a = core[i];
      for (let j = i + 1; j < N; j++) {
        const b = core[j];
        let dx = b.x - a.x, dy = b.y - a.y, d2 = dx * dx + dy * dy;
        if (d2 < 1) { dx = (i - j) * 0.37 || 0.5; dy = 0.5; d2 = dx * dx + dy * dy; }
        const fa = (charge(b) * alpha) / d2, fb = (charge(a) * alpha) / d2;
        a.vx += dx * fa; a.vy += dy * fa;
        b.vx -= dx * fb; b.vy -= dy * fb;
        const minD = a.r + b.r + 16, d = Math.sqrt(d2);
        if (d < minD) {
          const o = ((minD - d) / d) * 0.35;
          a.vx -= dx * o; a.vy -= dy * o; b.vx += dx * o; b.vy += dy * o;
        }
      }
    }
    for (const l of springs) {
      let dx = l.t.x + l.t.vx - l.s.x - l.s.vx, dy = l.t.y + l.t.vy - l.s.y - l.s.vy;
      const d = Math.hypot(dx, dy) || 1, f = ((d - l.len) / d) * alpha * l.k;
      dx *= f; dy *= f;
      l.t.vx -= dx * l.bias; l.t.vy -= dy * l.bias;
      l.s.vx += dx * (1 - l.bias); l.s.vy += dy * (1 - l.bias);
    }
    for (const n of core) {
      n.vx -= n.x * gx * alpha; n.vy -= n.y * gy * alpha;
      if (n.fixed) { n.vx = n.vy = 0; continue; }
      n.vx *= 0.6; n.vy *= 0.6;
      n.x += n.vx; n.y += n.vy;
    }
  }

  return {
    tick,
    // aspect = stage width / height; weaker sideways gravity spreads the layout to fit the stage.
    settle(aspect) {
      const a = Math.min(1.9, Math.max(0.55, aspect));
      gy = 0.05; gx = 0.05 / (a * a);
      core.forEach((n, i) => {
        const r = 14 * Math.sqrt(0.5 + i), t = i * 2.399963229728653;
        n.x = r * Math.cos(t) * Math.sqrt(a); n.y = (r * Math.sin(t)) / Math.sqrt(a); n.vx = n.vy = 0;
      });
      let alpha = 1;
      const decay = 1 - Math.pow(0.001, 1 / 320);
      for (let i = 0; i < 320; i++) { tick(alpha); alpha -= alpha * decay; }
      return a;
    },
  };
}

// The outer ring: quiet namespaces packed two rows deep, one arc per group.
function placeRing(core, quiet, a) {
  const sx = Math.sqrt(a), sy = 1 / Math.sqrt(a);
  let R0 = 60;
  for (const n of core) R0 = Math.max(R0, Math.hypot(n.x / sx, n.y / sy));
  R0 += 46;
  const groups = new Map();
  for (const n of [...quiet].sort((p, q) => p.label.localeCompare(q.label))) {
    if (!groups.has(n.group)) groups.set(n.group, []);
    groups.get(n.group).push(n);
  }
  const order = [...groups.entries()].sort((p, q) => q[1].length - p[1].length || p[0].localeCompare(q[0]));
  const cols = order.reduce((s, [, ns]) => s + Math.ceil(ns.length / 2), 0) + order.length;
  const step = (2 * Math.PI) / Math.max(cols, 1);
  // Keep neighbouring ring points at least ~30 units apart.
  const R = Math.max(R0, (30 * cols) / (2 * Math.PI));
  const rows = [R, R + 26];
  const glabels = [];
  let col = 0.5;
  for (const [g, ns] of order) {
    const startCol = col;
    ns.forEach((n, i) => {
      const row = i % 2, c = col + Math.floor(i / 2) + row * 0.5;
      const t = -Math.PI / 2 + c * step;
      n.x = rows[row] * sx * Math.cos(t); n.y = rows[row] * sy * Math.sin(t);
    });
    col += Math.ceil(ns.length / 2);
    const mid = -Math.PI / 2 + ((startCol + col - 0.5) / 2) * step;
    glabels.push({ group: g, color: groupColor(g), t: mid, n: ns.length });
    col += 1;
  }
  return { sx, sy, R, outer: R + 26, glabels };
}

// ---------- page ----------

const $ = (id) => document.getElementById(id);
const el = (name, attrs = {}, parent) => {
  const e = document.createElementNS(SVGNS, name);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  if (parent) parent.appendChild(e);
  return e;
};

function badgePath(kind, x, y, s) {
  switch (kind) {
    case "postgres": case "mysql": return `M${x - s} ${y - s}h${2 * s}v${2 * s}h${-2 * s}Z`;
    case "redis": return `M${x} ${y - s * 1.35}L${x + s * 1.35} ${y}L${x} ${y + s * 1.35}L${x - s * 1.35} ${y}Z`;
    case "vault": return `M${x} ${y - s * 1.3}L${x + s * 1.25} ${y + s}L${x - s * 1.25} ${y + s}Z`;
    default: return `M${x - s} ${y}a${s} ${s} 0 1 0 ${2 * s} 0a${s} ${s} 0 1 0 ${-2 * s} 0`;
  }
}
const hollow = (kind) => kind === "mysql" || kind === "mail";

async function main() {
  renderSwitcher($("switcher"), "graph.html");
  let snap;
  try {
    snap = await loadSnapshot();
  } catch (err) {
    const p = $("load-error");
    p.hidden = false;
    p.textContent = `The graph data could not be loaded: ${err.message}`;
    return;
  }
  renderFooter($("footer"), snap);
  const { nodes, edges, idx } = buildModel(snap);
  const core = nodes.filter((n) => n.core);
  const quiet = nodes.filter((n) => !n.core);

  // Tally
  $("tally").innerHTML = [
    [snap.services.length, "services"],
    [nodes.length, "namespaces"],
    [edges.length, "traffic links"],
    [core.length, "namespaces with traffic"],
  ].map(([v, l]) => `<div><dt>${escapeHTML(l)}</dt><dd>${fmt.int(v)}</dd></div>`).join("");

  // Legend
  const groupCounts = new Map();
  for (const n of nodes) groupCounts.set(n.group, (groupCounts.get(n.group) || 0) + 1);
  const groupList = [...groupCounts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  const filter = new Set();
  const legend = $("legend");
  function drawLegend() {
    legend.innerHTML =
      groupList.map(([g, c]) =>
        `<button type="button" data-group="${escapeHTML(g)}" aria-pressed="${filter.has(g)}" style="--c:${groupColor(g)}"><span class="dot"></span>${escapeHTML(g)}<span class="n">${c}</span></button>`,
      ).join("") + (filter.size ? `<button type="button" class="reset" data-reset="1">Show all</button>` : "");
  }
  drawLegend();
  legend.addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    if (b.dataset.reset) filter.clear();
    else filter.has(b.dataset.group) ? filter.delete(b.dataset.group) : filter.add(b.dataset.group);
    drawLegend();
    const again = legend.querySelector(b.dataset.reset ? "button" : `button[data-group="${CSS.escape(b.dataset.group || "")}"]`);
    if (again) again.focus();
    applyListFilter();
    render();
  });

  $("key").innerHTML =
    BADGE_ORDER.map((k) =>
      `<span><svg viewBox="-6 -6 12 12" aria-hidden="true"><path class="shape" d="${badgePath(k, 0, 0, 3.4)}" ${hollow(k) ? 'style="fill:none"' : ""} stroke-width="1.2"/></svg>${escapeHTML(BADGES[k])}</span>`,
    ).join("") +
    `<span class="edge-key"><svg viewBox="0 -6 40 12" aria-hidden="true"><line x1="0" y1="0" x2="16" y2="0" stroke-width="1.2" stroke-linecap="round"/><line x1="22" y1="0" x2="40" y2="0" stroke-width="5" stroke-linecap="round"/></svg>more flows, thicker line</span>`;

  // ---------- graph ----------
  const stage = $("stage"), svg = $("sky"), panel = $("panel");
  let W = stage.clientWidth || 800, H = stage.clientHeight || 600;
  const sim = makeSim(core, edges);
  const aspect = sim.settle(W / H);
  const ring = placeRing(core, quiet, aspect);

  const gGrid = el("g", { class: "grid" }, svg);
  const gEdges = el("g", { class: "edges" }, svg);
  const gNodes = el("g", { class: "nodes" }, svg);
  const gLabels = el("g", { class: "labels" }, svg);
  const gridRings = [0.35, 0.7, 1].map((f) => ({ f, e: el("ellipse", {}, gGrid) }));
  const band = [ring.R - 14, ring.outer + 14].map((R) => ({ R, e: el("ellipse", { class: "band" }, gGrid) }));
  const spokes = Array.from({ length: 12 }, (_, i) => ({ t: (i * Math.PI) / 6, e: el("line", {}, gGrid) }));

  for (const e of edges) {
    e.w = 1 + 0.72 * Math.log10(e.flows + 1);
    e.el = el("path", { class: "edge", "stroke-width": e.w.toFixed(2) }, gEdges);
    e.el.style.setProperty("--c", e.s.color);
  }
  for (const n of nodes) {
    const g = el("g", { class: `node${n.core ? "" : " quiet"}`, "data-ns": n.id }, gNodes);
    g.style.setProperty("--c", n.color);
    if (n.core) el("circle", { class: "halo", r: (n.r + 5).toFixed(1) }, g);
    el("circle", { class: "core", r: n.r.toFixed(1) }, g);
    const s = n.core ? 2.6 : 2;
    n.badges.forEach((b, i) => {
      const t = (-62 + i * 34) * (Math.PI / 180), d = n.r + (n.core ? 6 : 4.5);
      el("path", { class: `badge${hollow(b) ? " hollow" : ""}`, d: badgePath(b, d * Math.cos(t), d * Math.sin(t), s) }, g);
    });
    if (n.core) {
      g.setAttribute("tabindex", "0");
      g.setAttribute("role", "button");
      g.setAttribute("aria-label", `${n.label}: ${n.degree} connection${n.degree === 1 ? "" : "s"}`);
    }
    n.g = g;
    n.lab = el("text", { class: `label${n.core ? (n.degree >= 5 ? " hub" : "") : " quiet"}` }, gLabels);
    n.lab.textContent = n.label;
  }
  for (const gl of ring.glabels) {
    gl.el = el("text", { class: "glabel" }, gLabels);
    gl.el.textContent = gl.group;
  }

  // Text measurement for label collision
  const ctx = document.createElement("canvas").getContext("2d");
  const widths = new Map();
  function textW(key, text, font) {
    if (!widths.has(key)) { ctx.font = font; widths.set(key, ctx.measureText(text).width); }
    return widths.get(key);
  }
  document.fonts?.ready.then(() => { widths.clear(); render(); });

  // View
  const view = { k: 1, tx: W / 2, ty: H / 2 };
  let kFit = 1;
  function bounds(list, pad) {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const n of list) { x0 = Math.min(x0, n.x); y0 = Math.min(y0, n.y); x1 = Math.max(x1, n.x); y1 = Math.max(y1, n.y); }
    return { x0: x0 - pad, y0: y0 - pad, x1: x1 + pad, y1: y1 + pad };
  }
  function fitRect(b, rect) {
    const k = Math.min(rect.w / (b.x1 - b.x0), rect.h / (b.y1 - b.y0));
    return { k, tx: rect.x + rect.w / 2 - ((b.x0 + b.x1) / 2) * k, ty: rect.y + rect.h / 2 - ((b.y0 + b.y1) / 2) * k };
  }
  function homeView() {
    const all = fitRect(bounds(nodes, 40), { x: 12, y: 12, w: W - 24, h: H - 70 });
    const narrow = W < 720;
    // On a phone the whole sky is too small to read; frame the connected core and let the ring run off the edges.
    if (narrow) {
      const c = fitRect(bounds(core, 30), { x: 8, y: 8, w: W - 16, h: H - 70 });
      if (c.k > all.k * 1.15) return c;
    }
    return all;
  }
  function resetView(animate) {
    const v = homeView();
    kFit = v.k;
    animate ? animateTo(v) : Object.assign(view, v);
    render();
  }
  let anim = 0;
  function animateTo(target, ms = 480) {
    cancelAnimationFrame(anim);
    if (reduceMotion) { Object.assign(view, target); render(); return; }
    const from = { ...view }, t0 = performance.now();
    const stepF = (now) => {
      const p = Math.min(1, (now - t0) / ms), e = 1 - Math.pow(1 - p, 3);
      view.k = from.k + (target.k - from.k) * e;
      view.tx = from.tx + (target.tx - from.tx) * e;
      view.ty = from.ty + (target.ty - from.ty) * e;
      render();
      if (p < 1) anim = requestAnimationFrame(stepF);
    };
    anim = requestAnimationFrame(stepF);
  }
  const clampK = (k) => Math.max(kFit * 0.45, Math.min(kFit * 9, k));
  function zoomAt(px, py, f) {
    const k1 = clampK(view.k * f);
    view.tx = px - ((px - view.tx) * k1) / view.k;
    view.ty = py - ((py - view.ty) * k1) / view.k;
    view.k = k1;
    render();
  }
  const SX = (n) => n.x * view.k + view.tx, SY = (n) => n.y * view.k + view.ty;

  const hint = $("hint");
  if (matchMedia("(pointer: coarse)").matches) hint.textContent = "Pinch to zoom, tap a point.";
  const overlays = [{ el: hint }, { el: stage.querySelector(".zoom") }];

  // State
  const state = { sel: null, hover: null };
  let labelBoxes = [];

  function visibleRect() {
    if (panel.hidden) return { x: 16, y: 16, w: W - 32, h: H - 76 };
    if (W < 720) {
      const ph = panel.offsetHeight;
      return { x: 16, y: 16, w: W - 32, h: Math.max(140, H - ph - 32) };
    }
    const pw = panel.offsetWidth + 24;
    return { x: 16, y: 16, w: Math.max(200, W - pw - 32), h: H - 76 };
  }

  let frame = 0;
  function render() {
    if (frame) return;
    frame = requestAnimationFrame(draw);
  }
  function draw() {
    frame = 0;
    if (stage.hidden) return;
    const { k, tx, ty } = view;
    const focus = state.hover || state.sel;
    const inFilter = (n) => !filter.size || filter.has(n.group);
    const near = (n) => !focus || n === focus || focus.nbrs.has(n);

    for (const r of gridRings) {
      const R = (ring.R - 46) * r.f;
      r.e.setAttribute("cx", tx); r.e.setAttribute("cy", ty);
      r.e.setAttribute("rx", Math.max(0, R * ring.sx * k)); r.e.setAttribute("ry", Math.max(0, R * ring.sy * k));
    }
    for (const b of band) {
      b.e.setAttribute("cx", tx); b.e.setAttribute("cy", ty);
      b.e.setAttribute("rx", b.R * ring.sx * k); b.e.setAttribute("ry", b.R * ring.sy * k);
    }
    for (const s of spokes) {
      const R1 = (ring.R - 46) * 0.35, R2 = ring.outer + 40;
      s.e.setAttribute("x1", tx + Math.cos(s.t) * R1 * ring.sx * k); s.e.setAttribute("y1", ty + Math.sin(s.t) * R1 * ring.sy * k);
      s.e.setAttribute("x2", tx + Math.cos(s.t) * R2 * ring.sx * k); s.e.setAttribute("y2", ty + Math.sin(s.t) * R2 * ring.sy * k);
    }

    for (const e of edges) {
      const x1 = SX(e.s), y1 = SY(e.s), x2 = SX(e.t), y2 = SY(e.t);
      const mx = (x1 + x2) / 2 - (y2 - y1) * 0.14, my = (y1 + y2) / 2 + (x2 - x1) * 0.14;
      e.el.setAttribute("d", `M${x1.toFixed(1)} ${y1.toFixed(1)}Q${mx.toFixed(1)} ${my.toFixed(1)} ${x2.toFixed(1)} ${y2.toFixed(1)}`);
      const hot = focus && (e.s === focus || e.t === focus);
      const dim = (focus && !hot) || (filter.size && !inFilter(e.s) && !inFilter(e.t));
      e.el.setAttribute("class", `edge${hot ? (reduceMotion ? " hot solid" : " hot") : ""}${dim ? " dim" : ""}`);
    }

    for (const n of nodes) {
      n.sx = SX(n); n.sy = SY(n);
      n.g.setAttribute("transform", `translate(${n.sx.toFixed(1)} ${n.sy.toFixed(1)})`);
      n.dim = !inFilter(n) || !near(n);
      n.g.setAttribute("class", `node${n.core ? "" : " quiet"}${n === state.sel ? " sel" : ""}${n.dim ? " dim" : ""}`);
    }

    // Labels: greedy placement by priority, skipping any that would collide.
    const zoomedIn = k >= kFit * 1.7;
    const cand = [];
    for (const n of nodes) {
      let p = -1;
      if (n === focus) p = 10000;
      else if (focus && focus.nbrs.has(n)) p = 5000 + n.degree;
      else if (n.dim) p = -1;
      else if (n.core) p = 1000 + n.degree * 20 + Math.log10(n.flows + 1);
      else if (zoomedIn || (filter.size && filter.has(n.group))) p = 100;
      if (p >= 0) cand.push([p, n]);
      else n.lab.setAttribute("display", "none");
    }
    cand.sort((a, b) => b[0] - a[0]);
    // The hint and zoom buttons sit over the bottom of the stage; keep labels off them.
    const placed = overlays.filter((o) => !o.el.hidden && o.el.offsetParent).map((o) => {
      const r = o.el.getBoundingClientRect(), s = stage.getBoundingClientRect();
      return { x0: r.left - s.left - 4, x1: r.right - s.left + 4, y0: r.top - s.top - 4, y1: r.bottom - s.top + 4 };
    });
    const hits = (b) => placed.some((o) => b.x0 < o.x1 && b.x1 > o.x0 && b.y0 < o.y1 && b.y1 > o.y0);
    const discs = nodes.filter((n) => !n.dim && n.sx > -20 && n.sx < W + 20 && n.sy > -20 && n.sy < H + 20);
    const overNode = (b, self) => discs.some((n) => n !== self && b.x0 < n.sx + n.r && b.x1 > n.sx - n.r && b.y0 < n.sy + n.r && b.y1 > n.sy - n.r);
    labelBoxes = [];
    for (const [p, n] of cand) {
      const hub = n.core && n.degree >= 5, size = n.core ? (hub ? 14 : 13) : 12;
      const w = textW(`${n.id}|${size}`, n.label, `${hub ? 700 : 400} ${size}px "Atkinson Hyperlegible", system-ui, sans-serif`);
      const h = size + 2, gap = n.r + (n.badges.length ? 9 : 5);
      const opts = [
        { x: n.sx + gap, y: n.sy + size * 0.35, a: "start", b: { x0: n.sx + gap - 2, x1: n.sx + gap + w + 2, y0: n.sy - h / 2, y1: n.sy + h / 2 } },
        { x: n.sx - gap, y: n.sy + size * 0.35, a: "end", b: { x0: n.sx - gap - w - 2, x1: n.sx - gap + 2, y0: n.sy - h / 2, y1: n.sy + h / 2 } },
        { x: n.sx, y: n.sy - gap - 3, a: "middle", b: { x0: n.sx - w / 2 - 2, x1: n.sx + w / 2 + 2, y0: n.sy - gap - h, y1: n.sy - gap } },
        { x: n.sx, y: n.sy + gap + size, a: "middle", b: { x0: n.sx - w / 2 - 2, x1: n.sx + w / 2 + 2, y0: n.sy + gap, y1: n.sy + gap + h } },
      ];
      const force = p >= 5000;
      let pick = null;
      for (const o of opts) {
        if (o.b.x0 < 2 || o.b.x1 > W - 2 || o.b.y0 < 2 || o.b.y1 > H - 2) continue;
        if (hits(o.b) || overNode(o.b, n)) continue;
        pick = o; break;
      }
      if (!pick && n === focus) pick = opts[0];
      if (!pick && force) pick = opts.find((o) => !hits(o.b)) || null;
      if (!pick) { n.lab.setAttribute("display", "none"); continue; }
      placed.push(pick.b);
      labelBoxes.push({ b: pick.b, n });
      n.lab.removeAttribute("display");
      n.lab.setAttribute("x", pick.x.toFixed(1));
      n.lab.setAttribute("y", pick.y.toFixed(1));
      n.lab.setAttribute("text-anchor", pick.a);
      n.lab.setAttribute("class", `label${n.core ? (hub ? " hub" : "") : " quiet"}`);
    }

    // Group names around the outer ring.
    const Rl = ring.outer + 30;
    for (const gl of ring.glabels) {
      const c = Math.cos(gl.t), s = Math.sin(gl.t);
      const x = tx + c * Rl * ring.sx * k, y = ty + s * Rl * ring.sy * k + (s > 0.3 ? 10 : s < -0.3 ? 0 : 4);
      const a = c > 0.35 ? "start" : c < -0.35 ? "end" : "middle";
      const w = gl.group.length * 8.4;
      const x0 = a === "start" ? x : a === "end" ? x - w : x - w / 2;
      const b = { x0, x1: x0 + w, y0: y - 12, y1: y + 2 };
      const show = !filter.size || filter.has(gl.group);
      if (!show || b.x0 < 0 || b.x1 > W || b.y0 < 0 || b.y1 > H || hits(b)) { gl.el.setAttribute("display", "none"); continue; }
      placed.push(b);
      gl.el.removeAttribute("display");
      gl.el.setAttribute("x", x.toFixed(1)); gl.el.setAttribute("y", y.toFixed(1));
      gl.el.setAttribute("text-anchor", a);
      gl.el.style.fill = gl.color;
    }
  }

  // ---------- interaction ----------
  function hitTest(x, y, touch) {
    let best = null, bd = Infinity;
    for (const n of nodes) {
      const d = Math.hypot(n.sx - x, n.sy - y), reach = touch ? Math.max(n.r + 8, 22) : n.r + 5;
      if (d <= reach && d - n.r < bd) { bd = d - n.r; best = n; }
    }
    if (best) return best;
    for (const lb of labelBoxes) if (x >= lb.b.x0 && x <= lb.b.x1 && y >= lb.b.y0 && y <= lb.b.y1) return lb.n;
    return null;
  }
  const local = (e) => { const r = svg.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };

  let liveAlpha = 0, liveFrame = 0;
  function reheat(a) {
    if (reduceMotion) return;
    liveAlpha = Math.max(liveAlpha, a);
    if (liveFrame) return;
    const loop = () => {
      sim.tick(liveAlpha);
      liveAlpha *= 0.94;
      render();
      liveFrame = liveAlpha > 0.004 ? requestAnimationFrame(loop) : 0;
    };
    liveFrame = requestAnimationFrame(loop);
  }

  const pointers = new Map();
  let gesture = null;
  svg.addEventListener("pointerdown", (e) => {
    const p = local(e);
    svg.setPointerCapture(e.pointerId);
    pointers.set(e.pointerId, p);
    cancelAnimationFrame(anim);
    if (pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      gesture = { type: "pinch", d0: Math.hypot(a.x - b.x, a.y - b.y) || 1, mid0: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }, v0: { ...view } };
      return;
    }
    if (pointers.size > 2) return;
    const hit = hitTest(p.x, p.y, e.pointerType !== "mouse");
    gesture = hit
      ? { type: "node", node: hit, x0: p.x, y0: p.y, moved: false }
      : { type: "pan", x0: p.x, y0: p.y, tx0: view.tx, ty0: view.ty, moved: false };
  });
  svg.addEventListener("pointermove", (e) => {
    const p = local(e);
    if (pointers.has(e.pointerId)) pointers.set(e.pointerId, p);
    if (!gesture) {
      if (e.pointerType === "mouse") {
        const h = hitTest(p.x, p.y, false);
        svg.classList.toggle("on-node", !!h);
        if (h !== state.hover) { state.hover = h; render(); }
      }
      return;
    }
    if (gesture.type === "pinch" && pointers.size >= 2) {
      const [a, b] = [...pointers.values()];
      const d = Math.hypot(a.x - b.x, a.y - b.y), mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      const { v0, mid0 } = gesture;
      const k1 = clampK((v0.k * d) / gesture.d0);
      const wx = (mid0.x - v0.tx) / v0.k, wy = (mid0.y - v0.ty) / v0.k;
      view.k = k1; view.tx = mid.x - wx * k1; view.ty = mid.y - wy * k1;
      render();
      return;
    }
    const dx = p.x - gesture.x0, dy = p.y - gesture.y0;
    if (!gesture.moved && Math.hypot(dx, dy) < 5) return;
    gesture.moved = true;
    if (gesture.type === "pan") {
      svg.classList.add("panning");
      view.tx = gesture.tx0 + dx; view.ty = gesture.ty0 + dy;
      render();
    } else if (gesture.type === "node") {
      const n = gesture.node;
      n.x = (p.x - view.tx) / view.k; n.y = (p.y - view.ty) / view.k;
      if (n.core) { n.fixed = true; reheat(0.12); }
      render();
    }
  });
  function endPointer(e) {
    pointers.delete(e.pointerId);
    svg.classList.remove("panning");
    if (!gesture) return;
    if (gesture.type === "pinch") {
      if (pointers.size === 1) {
        const [q] = pointers.values();
        gesture = { type: "pan", x0: q.x, y0: q.y, tx0: view.tx, ty0: view.ty, moved: true };
      } else if (!pointers.size) gesture = null;
      return;
    }
    if (pointers.size) return;
    if (!gesture.moved && e.type === "pointerup") {
      if (gesture.type === "node") select(gesture.node, { reveal: true });
      else select(null);
    }
    gesture = null;
  }
  svg.addEventListener("pointerup", endPointer);
  svg.addEventListener("pointercancel", endPointer);
  svg.addEventListener("pointerleave", (e) => {
    if (e.pointerType === "mouse" && state.hover) { state.hover = null; svg.classList.remove("on-node"); render(); }
  });
  svg.addEventListener("wheel", (e) => {
    e.preventDefault();
    const p = local(e);
    const unit = e.deltaMode === 1 ? 0.05 : e.deltaMode === 2 ? 1 : 0.0018;
    zoomAt(p.x, p.y, Math.exp(-e.deltaY * unit));
  }, { passive: false });
  svg.addEventListener("focusin", (e) => {
    const g = e.target.closest?.(".node");
    if (g && g.matches(":focus-visible")) { state.hover = idx.get(g.dataset.ns); render(); }
  });
  svg.addEventListener("focusout", () => { state.hover = null; render(); });
  svg.addEventListener("keydown", (e) => {
    const g = e.target.closest?.(".node");
    if (g && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); select(idx.get(g.dataset.ns), { reveal: true }); }
  });
  $("zoom-in").addEventListener("click", () => zoomAt(W / 2, H / 2, 1.4));
  $("zoom-out").addEventListener("click", () => zoomAt(W / 2, H / 2, 1 / 1.4));
  $("zoom-fit").addEventListener("click", () => resetView(true));
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && state.sel) select(null); });

  // ---------- detail panel ----------
  const nbrList = (list) =>
    list.length
      ? `<ul class="nbrs">${list.map(({ n, flows }) =>
          `<li><button type="button" data-ns="${escapeHTML(n.id)}" style="--c:${n.color}"><span class="dot"></span><span class="who">${escapeHTML(n.label)}</span><span class="flows">${escapeHTML(fmt.compact(flows))} flows</span></button></li>`,
        ).join("")}</ul>`
      : `<p class="none">None observed.</p>`;
  const safeURL = (u) => (/^https:\/\//.test(u || "") ? u : "");
  function serviceHTML(s, color) {
    const icon = iconURL(s.icon);
    const letter = escapeHTML((s.name || "?").trim().charAt(0).toUpperCase());
    const access = ACCESS[s.access];
    const tf = safeURL(s.stack_url);
    return `<div class="svc" style="--c:${color}">` +
      (icon ? `<img class="icon" src="${escapeHTML(icon)}" alt="" loading="lazy" data-letter="${letter}">` : `<span class="avatar" aria-hidden="true">${letter}</span>`) +
      `<span class="name">${escapeHTML(s.name)}</span>` +
      `<span class="desc">${escapeHTML(s.description || "")}</span>` +
      `<span class="meta">${access ? `<span title="${escapeHTML(access.detail)}">${escapeHTML(access.label)}</span>` : ""}` +
      (tf ? `<a href="${escapeHTML(tf)}" target="_blank" rel="noopener">Terraform: stacks/${escapeHTML(s.stack)}</a>` : "") +
      `</span></div>`;
  }
  function fixIcons(root) {
    root.querySelectorAll("img.icon").forEach((img) =>
      img.addEventListener("error", () => {
        const a = document.createElement("span");
        a.className = "avatar"; a.setAttribute("aria-hidden", "true"); a.textContent = img.dataset.letter || "?";
        img.replaceWith(a);
      }, { once: true }));
  }
  function panelHTML(n) {
    const plural = (c, w) => `${c} ${w}${c === 1 ? "" : "s"}`;
    return `<div class="panel-head"><div class="titles"><h2>${escapeHTML(n.label)}</h2><div class="ns">namespace ${escapeHTML(n.id)}</div></div>` +
      `<button type="button" class="close" aria-label="Close details">&times;</button></div>` +
      `<div class="chips"><span class="chip" style="--c:${n.color}"><span class="dot"></span>${escapeHTML(n.group)}</span>` +
      `<span class="chip">${n.degree ? plural(n.degree, "connection") : "no observed traffic"}</span>` +
      n.badges.map((b) => `<span class="chip">uses ${escapeHTML(BADGES[b])}</span>`).join("") + `</div>` +
      (n.services.length ? `<h3>${n.services.length === 1 ? "Service" : `${n.services.length} services`}</h3>${n.services.map((s) => serviceHTML(s, n.color)).join("")}` : "") +
      (n.degree
        ? `<h3>Sends traffic to</h3>${nbrList(n.out)}<h3>Receives traffic from</h3>${nbrList(n.in)}`
        : `<h3>Traffic</h3><p class="none">No traffic to or from the other namespaces on this graph in the last 30 days.</p>`);
  }
  panel.addEventListener("click", (e) => {
    if (e.target.closest(".close")) { select(null); return; }
    const b = e.target.closest("button[data-ns]");
    if (b) select(idx.get(b.dataset.ns), { reveal: true, frame: true });
  });

  function frameNeighbourhood(n) {
    const set = [n, ...n.nbrs];
    const rect = visibleRect();
    const v = fitRect(bounds(set, set.length > 1 ? 50 : 120), rect);
    v.k = Math.max(kFit * 0.9, Math.min(kFit * 3, v.k));
    const cx = (bounds(set, 0).x0 + bounds(set, 0).x1) / 2, cy = (bounds(set, 0).y0 + bounds(set, 0).y1) / 2;
    v.tx = rect.x + rect.w / 2 - cx * v.k; v.ty = rect.y + rect.h / 2 - cy * v.k;
    animateTo(v);
  }
  function select(n, opts = {}) {
    state.sel = n || null;
    if (!n) {
      panel.hidden = true;
      stage.classList.remove("has-panel");
      history.replaceState(null, "", location.pathname + location.search);
      render();
      return;
    }
    panel.innerHTML = panelHTML(n);
    panel.hidden = false;
    panel.scrollTop = 0;
    stage.classList.add("has-panel");
    fixIcons(panel);
    history.replaceState(null, "", `#n=${encodeURIComponent(n.id)}`);
    if (opts.frame) frameNeighbourhood(n);
    else if (opts.reveal) {
      const r = visibleRect(), x = SX(n), y = SY(n);
      if (x < r.x || x > r.x + r.w || y < r.y || y > r.y + r.h) frameNeighbourhood(n);
    }
    render();
  }

  // ---------- list view ----------
  const list = $("list");
  const byRank = (a, b) => b.degree - a.degree || b.flows - a.flows || a.label.localeCompare(b.label);
  function listItem(n) {
    const link = ({ n: m, flows }) => `<li><a href="#ns-${escapeHTML(m.id)}" data-jump="${escapeHTML(m.id)}">${escapeHTML(m.label)}</a><span class="flows">${escapeHTML(fmt.compact(flows))}</span></li>`;
    const svcs = n.services.map((s) => {
      const tf = safeURL(s.stack_url), access = ACCESS[s.access];
      return `<p><strong>${escapeHTML(s.name)}</strong>${s.description ? `: ${escapeHTML(s.description)}` : ""}${access ? ` (${escapeHTML(access.label)})` : ""}${tf ? ` <a href="${escapeHTML(tf)}" target="_blank" rel="noopener">Terraform</a>` : ""}</p>`;
    }).join("");
    return `<li id="ns-${escapeHTML(n.id)}" data-group="${escapeHTML(n.group)}"><details><summary style="--c:${n.color}"><span class="dot"></span><span class="nm">${escapeHTML(n.label)}</span>` +
      `<span class="deg">${n.degree ? `${n.degree} link${n.degree === 1 ? "" : "s"}` : "quiet"}</span></summary><div class="body">` +
      `<p>${escapeHTML(n.group)} · namespace <code>${escapeHTML(n.id)}</code>${n.badges.length ? ` · uses ${n.badges.map((b) => escapeHTML(BADGES[b])).join(", ")}` : ""}</p>` +
      svcs +
      (n.out.length ? `<div class="dir">Sends traffic to (flows)</div><ul class="nl">${n.out.map(link).join("")}</ul>` : "") +
      (n.in.length ? `<div class="dir">Receives traffic from (flows)</div><ul class="nl">${n.in.map(link).join("")}</ul>` : "") +
      `</div></details></li>`;
  }
  list.innerHTML =
    `<h2>Namespaces with traffic, most connected first</h2><ol>${[...core].sort(byRank).map(listItem).join("")}</ol>` +
    `<h2>Quiet namespaces</h2><ol>${[...quiet].sort((a, b) => a.group.localeCompare(b.group) || a.label.localeCompare(b.label)).map(listItem).join("")}</ol>`;
  list.addEventListener("click", (e) => {
    const a = e.target.closest("a[data-jump]");
    if (!a) return;
    e.preventDefault();
    const li = document.getElementById(`ns-${a.dataset.jump}`);
    if (!li) return;
    li.hidden = false;
    const d = li.querySelector("details");
    d.open = true;
    li.scrollIntoView({ behavior: reduceMotion ? "auto" : "smooth", block: "start" });
    d.querySelector("summary").focus({ preventScroll: true });
  });
  function applyListFilter() {
    list.querySelectorAll("li[data-group]").forEach((li) => { li.hidden = filter.size > 0 && !filter.has(li.dataset.group); });
  }

  // ---------- view toggle ----------
  const bGraph = $("view-graph"), bList = $("view-list");
  function setMode(mode) {
    const isList = mode === "list";
    bGraph.setAttribute("aria-pressed", String(!isList));
    bList.setAttribute("aria-pressed", String(isList));
    stage.hidden = isList;
    $("key").hidden = isList;
    list.hidden = !isList;
    if (!isList) { measure(); render(); }
  }
  bGraph.addEventListener("click", () => setMode("graph"));
  bList.addEventListener("click", () => setMode("list"));

  // ---------- sizing ----------
  function measure() {
    const w = stage.clientWidth, h = stage.clientHeight;
    if (!w || !h || (w === W && h === H)) return;
    view.tx += (w - W) / 2; view.ty += (h - H) / 2;
    W = w; H = h;
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
  }
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
  new ResizeObserver(() => { measure(); render(); }).observe(stage);

  resetView(false);
  draw();
  const m = /^#n=(.+)$/.exec(location.hash);
  if (m && idx.has(decodeURIComponent(m[1]))) select(idx.get(decodeURIComponent(m[1])), { frame: true });
}

main();
