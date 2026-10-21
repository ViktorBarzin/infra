import {
  loadSnapshot, renderSwitcher, renderFooter, fmt,
  ACCESS, GATES, dnsLabel, STORAGE, BADGES, iconURL, escapeHTML,
} from "./shared.js";

const $ = (s) => document.querySelector(s);
const esc = escapeHTML;
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const DEFAULTS = ["Immich", "Nextcloud"];
const AUTOPLAY_MS = 2400;
const MAX_CALLS = 8;

// Small line pictograms, one per kind of stop. Stroke follows currentColor.
const ICON = {
  browser: '<rect x="3" y="4.5" width="18" height="15" rx="2"/><path d="M3 9h18M6.5 6.8h.01M9 6.8h.01"/>',
  dns: '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.6 2.5 3.8 5.3 3.8 8.5s-1.2 6-3.8 8.5c-2.6-2.5-3.8-5.3-3.8-8.5S9.4 6 12 3.5z"/>',
  gate: '<path d="M12 3 4.5 6v5.5c0 4.6 3.1 8 7.5 9.5 4.4-1.5 7.5-4.9 7.5-9.5V6z"/><path d="m8.8 12 2.2 2.2 4.2-4.4"/>',
  traefik: '<path d="M4 12h5l3-6h8M12 12h8M9 12l3 6h8"/><path d="m17.5 3.5 2.5 2.5-2.5 2.5M17.5 9.5 20 12l-2.5 2.5M17.5 15.5 20 18l-2.5 2.5"/>',
  pod: '<path d="M12 3 20 7.5v9L12 21l-8-4.5v-9z"/><path d="M4 7.5 12 12l8-4.5M12 12v9"/>',
  deps: '<ellipse cx="12" cy="6" rx="7" ry="2.8"/><path d="M5 6v6c0 1.5 3.1 2.8 7 2.8s7-1.3 7-2.8V6M5 12v6c0 1.5 3.1 2.8 7 2.8s7-1.3 7-2.8v-6"/>',
  storage: '<rect x="3.5" y="5" width="17" height="6" rx="1.5"/><rect x="3.5" y="13" width="17" height="6" rx="1.5"/><path d="M7 8h.01M7 16h.01M11 8h6M11 16h6"/>',
  end: '<path d="M5 21V4M5 4h11l-2 3.5L16 11H5"/>',
};
const svg = (k) => `<svg viewBox="0 0 24 24" aria-hidden="true">${ICON[k]}</svg>`;

const state = { snap: null, services: [], svc: null, stops: [], i: 0, timer: null, active: -1 };

function avatar(svc, cls = "avatar") {
  const letter = esc((svc.name || "?").trim().charAt(0).toUpperCase());
  const url = iconURL(svc.icon);
  return url
    ? `<span class="${cls}" data-letter="${letter}"><img src="${esc(url)}" alt="" loading="lazy" decoding="async"></span>`
    : `<span class="${cls} is-letter" data-letter="${letter}">${letter}</span>`;
}

// Replace a broken icon with its letter avatar.
document.addEventListener("error", (e) => {
  const img = e.target;
  if (!(img instanceof HTMLImageElement)) return;
  const box = img.parentElement;
  if (!box || !box.dataset.letter) return;
  box.classList.add("is-letter");
  box.textContent = box.dataset.letter;
}, true);

// hostHTML lets a long hostname wrap only after a dot (or after "//"): each
// piece is unbreakable, so hyphens inside a label never split it either.
const hostHTML = (h) =>
  String(h).split(/(?<=\.|\/\/)/).map((part) => `<span class="nb">${esc(part)}</span>`).join("<wbr>");

const slug = (name) => encodeURIComponent(name.toLowerCase().replace(/\s+/g, "-"));
const findBySlug = (s) => state.services.find((x) => slug(x.name) === s);

function nsLabel(ns) {
  const owners = state.services.filter((s) => s.namespace === ns).map((s) => s.name);
  if (owners.length === 1) return { name: owners[0], sub: `namespace ${ns}` };
  if (owners.length > 1) {
    const shown = owners.slice(0, 2).join(", ");
    return { name: ns, sub: owners.length > 2 ? `${shown} and ${owners.length - 2} more` : shown };
  }
  return { name: ns, sub: "namespace" };
}

// buildStops turns one service into the ordered list of stops a request passes.
function buildStops(svc) {
  const stops = [];
  const proto = svc.host.endsWith(".lan") ? "http(s)://" : "https://";
  stops.push({
    kind: "browser", line: "Start", title: "Your browser",
    body: `<p>You type <code class="host">${hostHTML(proto + svc.host)}</code> and press Enter. One request sets off.</p>`,
    count: false,
  });

  const dns = dnsLabel(svc);
  stops.push({
    kind: "dns", line: "DNS", title: dns.label,
    body: `<p>${esc(dns.detail)}</p><p class="meta"><span class="meta__k">Name</span> <code class="host">${hostHTML(svc.host)}</code></p>`,
    count: true,
  });

  const gates = svc.route.gates || [];
  gates.forEach((g, n) => {
    const info = GATES[g] || { label: g, detail: "" };
    stops.push({
      kind: "gate", line: `Gate ${n + 1} of ${gates.length}`, title: info.label,
      body: `<p>${esc(info.detail)}</p>`,
      count: true,
    });
  });

  stops.push({
    kind: "traefik", line: "Ingress", title: "Traefik",
    body: `<p>Traefik matches the hostname and hands the request to the service in namespace <code>${esc(svc.namespace)}</code>.</p>`,
    count: true,
  });

  const acc = ACCESS[svc.access];
  stops.push({
    kind: "pod", line: "Arrival", title: svc.name,
    titleHTML: `${avatar(svc, "avatar avatar--lg")}<span>${esc(svc.name)}</span>`,
    body:
      `<p class="pod__desc">${esc(svc.description || "")}</p>` +
      `<dl class="facts">` +
      (acc ? `<div><dt>Who gets in</dt><dd><strong>${esc(acc.label)}.</strong> ${esc(acc.detail)}</dd></div>` : "") +
      `<div><dt>Category</dt><dd>${esc(svc.group || "")}</dd></div>` +
      `<div><dt>Namespace</dt><dd><code>${esc(svc.namespace)}</code></dd></div>` +
      `</dl>`,
    count: true,
  });

  const badges = (state.snap.graph.badges || {})[svc.namespace] || [];
  const calls = (state.snap.graph.edges || [])
    .filter((e) => e.src === svc.namespace && e.dst !== svc.namespace)
    .sort((a, b) => b.flows - a.flows);
  let deps = "";
  if (badges.length) {
    deps += `<p class="sub">Backing services</p><ul class="chips">` +
      badges.map((b) => `<li class="chip chip--db">${esc(BADGES[b] || b)}</li>`).join("") + `</ul>`;
  }
  if (calls.length) {
    deps += `<p class="sub">Calls out to</p><ul class="calls">` +
      calls.slice(0, MAX_CALLS).map((e) => {
        const l = nsLabel(e.dst);
        return `<li><span class="calls__name">${esc(l.name)}</span><span class="calls__sub">${esc(l.sub)}</span>` +
          `<span class="calls__n">${esc(fmt.compact(e.flows))} flows</span></li>`;
      }).join("") + `</ul>` +
      (calls.length > MAX_CALLS ? `<p class="meta">and ${calls.length - MAX_CALLS} more</p>` : "");
  }
  if (!deps) deps = `<p>The snapshot records no database and no calls to other services from this namespace.</p>`;
  else deps = `<p>From namespace <code>${esc(svc.namespace)}</code> the pod reaches:</p>` + deps;
  stops.push({ kind: "deps", line: "Talks to", title: "What the pod talks to", body: deps, count: false, extra: badges.length + calls.length });

  const storage = svc.route.storage || [];
  const stBody = storage.length
    ? `<p>Its volumes come from ${storage.length === 1 ? "one storage class" : `${storage.length} storage classes`}:</p><ul class="chips">` +
      storage.map((s) => `<li class="chip chip--disk">${esc(STORAGE[s] || s)}<code>${esc(s)}</code></li>`).join("") + `</ul>`
    : `<p>It keeps no persistent volume.</p>`;
  stops.push({ kind: "storage", line: "Terminus", title: "Where the data lives", body: stBody, count: false, extra: storage.length });

  const touched = stops.reduce((n, s) => n + (s.count ? 1 : 0) + (s.extra || 0), 0);
  stops.push({ kind: "end", line: "End of the line", title: "", touched, gates: gates.length, deps: badges.length + calls.length, storage: storage.length });
  return stops;
}

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

function summary(s, svc) {
  const parts = ["DNS", plural(s.gates, "gate", "gates"), "Traefik", `the ${svc.name} pod`];
  if (s.deps) parts.push(plural(s.deps, "thing it talks to", "things it talks to"));
  if (s.storage) parts.push(plural(s.storage, "storage class", "storage classes"));
  return `${parts.slice(0, -1).join(", ")} and ${parts.at(-1)}.`;
}

function renderRoute() {
  const { svc, stops } = state;
  const route = $("#route");
  route.innerHTML = stops.map((s, n) => {
    if (s.kind === "end") {
      return `<li class="stop stop--end" data-kind="end" data-i="${n}">
        <button class="stop__marker" type="button" aria-label="Jump to the end of the line"><span></span></button>
        <div class="stop__card endcard">
          <p class="stop__line">${esc(s.line)}</p>
          <p class="endcard__big">This request touched <span class="endcard__n">${s.touched}</span> component${s.touched === 1 ? "" : "s"}.</p>
          <p class="endcard__sum">${esc(summary(s, svc))}</p>
          <div class="endcard__actions">
            <a class="btn btn-primary" href="${esc(svc.stack_url)}" rel="noopener">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 6 2.5 12 8 18M16 6l5.5 6-5.5 6"/></svg>
              <span>Read the <code>${esc(svc.stack)}</code> Terraform</span>
            </a>
            <button type="button" class="btn" data-action="another">Follow another request</button>
          </div>
        </div>
      </li>`;
    }
    return `<li class="stop" data-kind="${s.kind}" data-i="${n}">
      <button class="stop__marker" type="button" aria-label="Go to stop ${n + 1}: ${esc(s.title)}"><span></span></button>
      <div class="stop__card">
        <p class="stop__line"><span class="stop__icon">${svg(s.kind)}</span>${esc(s.line)}</p>
        <h2 class="stop__title">${s.titleHTML || esc(s.title)}</h2>
        <div class="stop__body">${s.body}</div>
      </div>
    </li>`;
  }).join("") + `<li class="packet" aria-hidden="true"><span></span></li>`;

  $("#ticket").innerHTML = `
    <p class="ticket__eyebrow">Now following</p>
    <div class="ticket__svc">${avatar(svc)}<div><p class="ticket__name">${esc(svc.name)}</p><p class="ticket__host">${hostHTML(svc.host)}</p></div></div>
    <p class="ticket__desc">${esc(svc.description || "")}</p>
    <p class="ticket__access ticket__access--${esc(svc.access)}">${esc((ACCESS[svc.access] || {}).label || svc.access)}</p>`;

  const n = state.services.indexOf(svc) + 1;
  $("#issue").textContent = `Route ${n} of ${state.services.length}`;
  $("#headline").innerHTML = `Follow a request to <em>${esc(svc.name)}</em>.`;
  $("#dek").textContent =
    `${svc.description ? svc.description + ". " : ""}One request, ${stops.length - 1} stops: from your browser to the disk where the data lives. Pick any of the ${state.services.length} services to follow another.`;
  document.title = `Follow a request to ${svc.name} · Viktor's homelab`;
}

// markerY uses offsets, not client rects, so the entrance animation's
// transforms never knock the packet off its station.
function markerY(i) {
  const li = $(`#route .stop[data-i="${i}"]`);
  const m = li && li.querySelector(".stop__marker");
  if (!m) return 0;
  return li.offsetTop + m.offsetTop + m.offsetHeight / 2;
}

function placePacket(animate) {
  const route = $("#route");
  const p = route.querySelector(".packet");
  if (!p) return;
  const still = !animate || reduceMotion.matches;
  p.classList.toggle("no-anim", still);
  route.classList.toggle("no-anim", still);
  const y = markerY(state.i);
  p.style.transform = `translateY(${y}px)`;
  route.style.setProperty("--rail-top", `${markerY(0)}px`);
  route.style.setProperty("--rail-end", `${markerY(state.stops.length - 1)}px`);
  route.style.setProperty("--travelled", `${y}px`);
}

function go(i, { scroll = true, fromUser = true } = {}) {
  const max = state.stops.length - 1;
  i = Math.max(0, Math.min(max, i));
  if (fromUser && state.timer) stop();
  state.i = i;
  document.querySelectorAll("#route .stop").forEach((el) => {
    const k = +el.dataset.i;
    el.classList.toggle("is-past", k < i);
    el.classList.toggle("is-current", k === i);
    el.classList.toggle("is-future", k > i);
    if (k === i) el.setAttribute("aria-current", "step"); else el.removeAttribute("aria-current");
  });
  placePacket(true);
  const s = state.stops[i];
  $("#count").textContent = s.kind === "end" ? "Arrived" : `Stop ${i + 1} of ${max}`;
  $("#back").disabled = i === 0;
  $("#next").disabled = i === max;
  $("#live").textContent = s.kind === "end"
    ? `End of the line. This request touched ${s.touched} components.`
    : `Stop ${i + 1}: ${s.line}, ${s.title}.`;
  if (scroll) {
    const el = $(`#route .stop[data-i="${i}"]`);
    const r = el.getBoundingClientRect();
    const controls = $(".controls").getBoundingClientRect();
    const bottomLimit = Math.min(window.innerHeight, controls.top > 0 ? controls.top : window.innerHeight);
    if (r.top < 70 || r.bottom > bottomLimit - 16) {
      el.scrollIntoView({ block: "center", behavior: reduceMotion.matches ? "auto" : "smooth" });
    }
  }
}

function stop() {
  clearInterval(state.timer);
  state.timer = null;
  $("#play").setAttribute("aria-pressed", "false");
  $("#play .play__text").textContent = "Play";
}

function play() {
  if (state.i >= state.stops.length - 1) go(0, { fromUser: false });
  $("#play").setAttribute("aria-pressed", "true");
  $("#play .play__text").textContent = "Pause";
  state.timer = setInterval(() => {
    if (state.i >= state.stops.length - 1) return stop();
    go(state.i + 1, { fromUser: false });
    if (state.i >= state.stops.length - 1) stop();
  }, reduceMotion.matches ? AUTOPLAY_MS + 800 : AUTOPLAY_MS);
}

function choose(svc, { scroll = false, updateHash = true } = {}) {
  if (state.timer) stop();
  state.svc = svc;
  state.stops = buildStops(svc);
  renderRoute();
  go(0, { scroll: false, fromUser: false });
  if (updateHash) history.replaceState(null, "", `#${slug(svc.name)}`);
  if (scroll) $(".layout").scrollIntoView({ behavior: reduceMotion.matches ? "auto" : "smooth", block: "start" });
}

function surprise() {
  let pick;
  do pick = state.services[Math.floor(Math.random() * state.services.length)];
  while (state.services.length > 1 && pick === state.svc);
  choose(pick, { scroll: true });
}

/* ---------- searchable picker (combobox) ---------- */
function setupPicker() {
  const input = $("#svc-search");
  const list = $("#svc-list");
  let matches = [];
  let active = -1;

  input.placeholder = `Search ${state.services.length} services`;

  const open = (on) => {
    list.hidden = !on;
    input.setAttribute("aria-expanded", String(on));
    if (!on) input.removeAttribute("aria-activedescendant");
  };
  const highlight = (n) => {
    active = n;
    list.querySelectorAll("[role=option]").forEach((o, k) => o.setAttribute("aria-selected", String(k === n)));
    const el = list.querySelector(`#opt-${n}`);
    if (el) { input.setAttribute("aria-activedescendant", el.id); el.scrollIntoView({ block: "nearest" }); }
  };
  const fill = () => {
    const q = input.value.trim().toLowerCase();
    matches = state.services.filter((s) =>
      !q || [s.name, s.description, s.group, s.host, s.namespace].some((f) => (f || "").toLowerCase().includes(q)));
    list.innerHTML = matches.length
      ? matches.map((s, k) =>
        `<li role="option" id="opt-${k}" data-k="${k}" aria-selected="false">${avatar(s)}<span class="opt__text"><span class="opt__name">${esc(s.name)}</span><span class="opt__desc">${esc(s.description || s.group || "")}</span></span></li>`).join("")
      : `<li class="opt__none">No service matches “${esc(input.value)}”.</li>`;
    highlight(matches.length ? 0 : -1);
    open(true);
  };
  const pick = (k) => {
    const s = matches[k];
    if (!s) return;
    input.value = "";
    open(false);
    input.blur();
    choose(s, { scroll: true });
  };

  input.addEventListener("focus", fill);
  input.addEventListener("input", fill);
  input.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") { e.preventDefault(); if (list.hidden) fill(); else highlight(Math.min(matches.length - 1, active + 1)); }
    else if (e.key === "ArrowUp") { e.preventDefault(); highlight(Math.max(0, active - 1)); }
    else if (e.key === "Enter") { e.preventDefault(); pick(active); }
    else if (e.key === "Escape") { open(false); input.blur(); }
  });
  list.addEventListener("pointerdown", (e) => e.preventDefault()); // keep focus so click lands
  list.addEventListener("click", (e) => {
    const o = e.target.closest("[role=option]");
    if (o) pick(+o.dataset.k);
  });
  input.addEventListener("blur", () => setTimeout(() => open(false), 120));
}

function setupControls() {
  $("#next").addEventListener("click", () => go(state.i + 1));
  $("#back").addEventListener("click", () => go(state.i - 1));
  $("#play").addEventListener("click", () => (state.timer ? stop() : play()));
  $("#surprise").addEventListener("click", surprise);
  $("#route").addEventListener("click", (e) => {
    if (e.target.closest("[data-action=another]")) {
      $("#svc-search").focus();
      $(".hero").scrollIntoView({ behavior: reduceMotion.matches ? "auto" : "smooth" });
      return;
    }
    if (e.target.closest("a, button.btn")) return;
    const li = e.target.closest(".stop");
    if (li) go(+li.dataset.i);
  });
  document.addEventListener("keydown", (e) => {
    if (e.target.closest("input, textarea, select, [contenteditable]")) return;
    if (e.altKey || e.ctrlKey || e.metaKey) return;
    if (e.key === "ArrowRight" || e.key === "ArrowDown") { e.preventDefault(); go(state.i + 1); }
    else if (e.key === "ArrowLeft" || e.key === "ArrowUp") { e.preventDefault(); go(state.i - 1); }
  });
  window.addEventListener("hashchange", () => {
    const s = findBySlug(location.hash.slice(1));
    if (s && s !== state.svc) choose(s, { updateHash: false });
  });
  new ResizeObserver(() => placePacket(false)).observe($("#route"));
}

async function main() {
  renderSwitcher($("#switcher"), "request.html");
  try {
    state.snap = await loadSnapshot();
  } catch (err) {
    $("#route").innerHTML = `<li class="stop stop--error"><div class="stop__card"><p>${esc(err.message)}</p></div></li>`;
    return;
  }
  state.services = [...state.snap.services].sort((a, b) => a.name.localeCompare(b.name, "en"));
  renderFooter($("#footer"), state.snap);
  setupPicker();
  setupControls();
  const fromHash = findBySlug(location.hash.slice(1));
  const fallback = DEFAULTS.map((n) => state.services.find((s) => s.name === n)).find(Boolean) || state.services[0];
  choose(fromHash || fallback, { updateHash: !!fromHash });
  document.body.classList.add("is-ready");
}

main();
