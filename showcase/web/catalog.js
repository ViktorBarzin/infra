import {
  loadSnapshot, renderSwitcher, renderFooter, fmt, STATS, ACCESS, GATES, dnsLabel, STORAGE, BADGES, iconURL, escapeHTML,
} from "./shared.js";

const $ = (s) => document.querySelector(s);
const esc = escapeHTML;
const ACCESS_ORDER = ["sso", "app", "lan"];
const HEADLINE = ["services", "stacks", "pods", "requests_per_day", "commits_per_week", "agent_fixes_30d"];

renderSwitcher($("#switcher"), "catalog.html");

let snap;
try {
  snap = await loadSnapshot();
} catch (e) {
  $("#grid").innerHTML = `<p class="err">The catalogue data could not be loaded (${esc(e.message)}).</p>`;
  throw e;
}

const services = [...snap.services].sort((a, b) => a.name.localeCompare(b.name, "en", { sensitivity: "base" }));
const badges = snap.graph?.badges || {};
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
services.forEach((s, i) => {
  s._no = String(i + 1).padStart(3, "0");
  s._id = slug(s.name);
  s._hay = `${s.name} ${s.description} ${s.group} ${s.namespace}`.toLowerCase();
});
const byId = new Map(services.map((s) => [s._id, s]));

// Groups in alphabetical order, with the catch-all "Other" last.
const groups = [...new Set(services.map((s) => s.group))].sort((a, b) =>
  a === "Other" ? 1 : b === "Other" ? -1 : a.localeCompare(b),
);

/* ---------- header copy ---------- */
$("#title-n").textContent = fmt.int(services.length);
$("#edition").textContent = `snapshot ${new Date(snap.generated.at).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" })}`;
renderFooter($("#footer"), snap);

/* ---------- hardware plate ---------- */
function renderHardware() {
  const hw = snap.hardware;
  const stats = STATS.filter((s) => HEADLINE.includes(s.key) && snap.stats[s.key] != null);
  const statsHTML = stats
    .map((s) => `<div><dt>${esc(s.label)}</dt><dd>${esc(fmt.compact(snap.stats[s.key]))}</dd></div>`)
    .join("");

  const server = hw.sites.flatMap((s) => s.kit).find((k) => k.live === "proxmox") || { name: "Proxmox host", role: "" };
  const gpu = hw.sites.flatMap((s) => s.kit).find((k) => /nvidia|gpu|tesla/i.test(k.name));
  const maxMem = Math.max(...hw.nodes.map((n) => n.memory_gib));
  const nodeRows = hw.nodes
    .map((n) => `<tr>
      <td>${esc(n.name)}${n.gpu ? '<span class="gpu" title="Has the GPU">GPU</span>' : ""}</td>
      <td class="role">${esc(n.role === "control-plane" ? "control plane" : n.role)}</td>
      <td class="num">${esc(fmt.int(n.cpu))}</td>
      <td class="num">${esc(fmt.int(n.memory_gib))}</td>
      <td class="col-bar"><span class="bar"><i style="width:${Math.round((n.memory_gib / maxMem) * 100)}%"></i></span></td>
    </tr>`)
    .join("");

  const sitesHTML = hw.sites
    .map((s, i) => `<div class="site${i === 0 ? " site--main" : ""}">
      <h3>${esc(s.name)}</h3><p>${esc(s.role)}</p>
      <ul class="kit">${s.kit.map((k) => `<li><b>${esc(k.name)}</b><span>${esc(k.role)}</span></li>`).join("")}</ul>
    </div>`)
    .join("");

  $("#hw-body").innerHTML = `
    <dl class="titleblock" aria-label="Headline numbers">${statsHTML}</dl>
    <div class="hw">
      <div>
        <p class="fig__cap">Fig. 1 · The server</p>
        <p class="host__name">${esc(server.name)}</p>
        <p class="host__role">${esc(server.role)}${gpu ? ` Fitted with an ${esc(gpu.name)}.` : ""}</p>
        <dl class="spec">
          <div><dt>CPU threads</dt><dd>${esc(fmt.int(hw.host.threads))}</dd></div>
          <div><dt>Memory</dt><dd>${esc(fmt.int(hw.host.memory_gib))}<small>GiB</small></dd></div>
          <div><dt>Storage</dt><dd>${esc(fmt.compact(hw.host.storage_tb))}<small>TB</small></dd></div>
        </dl>
        <p class="vms">${esc(fmt.int(hw.vms.length))} VMs running on it: ${hw.vms.map((v) => `<code>${esc(v)}</code>`).join(", ")}.</p>
      </div>
      <div>
        <p class="fig__cap">Fig. 2 · The Kubernetes nodes (VMs on that server)</p>
        <table class="nodes">
          <thead><tr><th scope="col">Node</th><th scope="col" class="role">Role</th><th scope="col" class="num">vCPU</th><th scope="col" class="num">GiB</th><th scope="col" class="col-bar"><span class="sr-only">Memory share</span></th></tr></thead>
          <tbody>${nodeRows}</tbody>
        </table>
      </div>
    </div>
    <p class="fig__cap fig__cap--sites">Fig. 3 · Sites and the kit at each</p>
    <div class="sites">${sitesHTML}</div>`;
}
renderHardware();

/* ---------- state <-> URL hash ---------- */
const state = { q: "", g: "", a: "", sort: "name", open: "" };
function readHash() {
  const p = new URLSearchParams(location.hash.slice(1));
  state.q = p.get("q") || "";
  state.g = groups.includes(p.get("g")) ? p.get("g") : "";
  state.a = ACCESS_ORDER.includes(p.get("a")) ? p.get("a") : "";
  state.sort = p.get("sort") === "group" ? "group" : "name";
  state.open = byId.has(p.get("open")) ? p.get("open") : "";
}
function writeHash() {
  const p = new URLSearchParams();
  if (state.q) p.set("q", state.q);
  if (state.g) p.set("g", state.g);
  if (state.a) p.set("a", state.a);
  if (state.sort !== "name") p.set("sort", state.sort);
  if (state.open) p.set("open", state.open);
  const h = p.toString();
  history.replaceState(null, "", h ? `#${h}` : location.pathname + location.search);
}

/* ---------- filtering ---------- */
const matchQ = (s) => !state.q || state.q.toLowerCase().split(/\s+/).filter(Boolean).every((t) => s._hay.includes(t));
const matchG = (s) => !state.g || s.group === state.g;
const matchA = (s) => !state.a || s.access === state.a;

function iconHTML(s) {
  const letter = `<span class="letter" aria-hidden="true">${esc((s.name.match(/[A-Za-z0-9]/) || ["?"])[0])}</span>`;
  const icon = s.icon || "";
  const m = icon.match(/^(mdi|si)-([a-z0-9-]+)$/);
  if (m) {
    const url = m[1] === "mdi"
      ? `https://cdn.jsdelivr.net/npm/@mdi/svg@7.4.47/svg/${m[2]}.svg`
      : `https://cdn.jsdelivr.net/npm/simple-icons@13.21.0/icons/${m[2]}.svg`;
    return `<span class="glyph" style="--m:url('${url}')" aria-hidden="true"></span>`;
  }
  const url = iconURL(icon);
  if (!url) return letter;
  return `<img src="${esc(url)}" alt="" width="40" height="40" loading="lazy" decoding="async" data-letter="${esc(s.name)}">`;
}

function detailHTML(s) {
  const dns = dnsLabel(s);
  const gates = (s.route?.gates || []).map((g) => GATES[g] || { label: g, detail: "" });
  const hops = [dns, ...gates, { label: "The app", detail: `Pods in the ${s.namespace} namespace answer the request.`, dest: true }];
  const storage = s.route?.storage || [];
  const used = (badges[s.namespace] || []).map((b) => BADGES[b] || b);
  const acc = ACCESS[s.access] || { label: s.access, detail: "" };
  return `
    <h4>How a request reaches it</h4>
    <ol class="route">${hops.map((h) => `<li${h.dest ? ' class="dest"' : ""}><b>${esc(h.label)}</b><span>${esc(h.detail)}</span></li>`).join("")}</ol>
    <dl class="facts">
      <div><dt>Getting in</dt><dd>${esc(acc.label)}<span>${esc(acc.detail)}</span></dd></div>
      <div><dt>Storage</dt><dd>${storage.length ? storage.map((x) => esc(STORAGE[x] || x)).join("<br>") : "No persistent volume"}</dd></div>
      <div><dt>Namespace</dt><dd><code>${esc(s.namespace)}</code>${used.length ? `<span>Uses ${esc(used.join(", "))}</span>` : ""}</dd></div>
    </dl>`;
}

const tfIcon = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 17 17 7M9 7h8v8"/></svg>';
function cardHTML(s, i) {
  const open = state.open === s._id;
  const acc = ACCESS[s.access] || { label: s.access };
  const used = (badges[s.namespace] || []).map((b) => `<span class="badge">${esc(BADGES[b] || b)}</span>`).join("");
  return `<article class="card" style="--i:${Math.min(i, 24)}" data-id="${esc(s._id)}"${open ? " data-open" : ""}>
    <button type="button" class="card__btn" aria-expanded="${open}" aria-controls="d-${esc(s._id)}">
      <span class="card__no"><span class="grp">No. ${s._no} · ${esc(s.group)}</span><span class="plus" aria-hidden="true"></span></span>
      <span class="ico">${iconHTML(s)}</span>
      <span class="card__name">${esc(s.name)}</span>
      <span class="card__desc">${esc(s.description)}</span>
    </button>
    <div class="card__meta"><span class="acc acc--${esc(s.access)}">${esc(acc.label)}</span>${used}</div>
    <div class="card__foot"><a class="tf" href="${esc(s.stack_url)}" target="_blank" rel="noopener"><span class="tf__k">Terraform</span><span class="tf__p" title="stacks/${esc(s.stack)}">stacks/${esc(s.stack)}</span>${tfIcon}</a></div>
    <div class="detail" id="d-${esc(s._id)}"${open ? "" : " hidden"}>${open ? detailHTML(s) : ""}</div>
  </article>`;
}

let first = true;
function render() {
  const visible = services.filter((s) => matchQ(s) && matchG(s) && matchA(s));
  if (state.sort === "group") {
    visible.sort((a, b) => groups.indexOf(a.group) - groups.indexOf(b.group) || a.name.localeCompare(b.name, "en", { sensitivity: "base" }));
  }

  // Group counts honour search + access; access counts honour search + group.
  const forGroups = services.filter((s) => matchQ(s) && matchA(s));
  const forAccess = services.filter((s) => matchQ(s) && matchG(s));
  const gCount = (g) => forGroups.filter((s) => s.group === g).length;
  const aCount = (a) => forAccess.filter((s) => s.access === a).length;

  $("#groups").innerHTML =
    `<button type="button" data-g="" aria-pressed="${!state.g}"><span>All groups</span><span class="n">${forGroups.length}</span></button>` +
    groups
      .map((g) => {
        const n = gCount(g);
        return `<button type="button" data-g="${esc(g)}" aria-pressed="${state.g === g}"${n || state.g === g ? "" : " disabled"}><span>${esc(g)}</span><span class="n">${n}</span></button>`;
      })
      .join("");

  $("#access").innerHTML =
    `<button type="button" data-a="" aria-pressed="${!state.a}"><span class="lbl">Any</span><span class="n">${forAccess.length}</span></button>` +
    ACCESS_ORDER.map(
      (a) => `<button type="button" data-a="${a}" aria-pressed="${state.a === a}"><span class="lbl"><span class="acc acc--${a}" aria-hidden="true"></span>${esc(ACCESS[a].label)}</span><span class="n">${aCount(a)}</span></button>`,
    ).join("");

  $("#sort").innerHTML = [["name", "By name"], ["group", "By group"]]
    .map(([k, l]) => `<button type="button" data-sort="${k}" aria-pressed="${state.sort === k}"><span class="lbl">${l}</span></button>`)
    .join("");

  let html = "";
  let lastGroup = null;
  visible.forEach((s, i) => {
    if (state.sort === "group" && s.group !== lastGroup) {
      lastGroup = s.group;
      const n = visible.filter((x) => x.group === s.group).length;
      html += `<h3 class="grouphead"><span>${esc(s.group)}</span><span class="n">${n}</span></h3>`;
    }
    html += cardHTML(s, first ? i : 0);
  });
  const grid = $("#grid");
  grid.innerHTML = html;
  grid.classList.toggle("no-anim", !first);
  if (!first) grid.querySelectorAll(".card").forEach((c) => (c.style.animation = "none"));
  first = false;

  const filtered = state.q || state.g || state.a;
  $("#tally").innerHTML = filtered
    ? `<strong>${visible.length}</strong> of ${services.length} services`
    : `<strong>${services.length}</strong> services, A to ${state.sort === "group" ? "Z within each group" : "Z"}`;
  $("#reset").hidden = !filtered;
  $("#empty").hidden = visible.length > 0;
  if ($("#q").value !== state.q) $("#q").value = state.q;
  // Keep the selected chip visible inside its own scrolling row on phones.
  for (const row of [$("#groups"), $("#access")]) {
    const on = row.querySelector('[aria-pressed="true"]');
    if (on && row.scrollWidth > row.clientWidth) {
      const l = on.offsetLeft - row.offsetLeft;
      if (l < row.scrollLeft || l + on.offsetWidth > row.scrollLeft + row.clientWidth) row.scrollLeft = l - 16;
    }
  }
}

/* ---------- events ---------- */
function update(patch) {
  Object.assign(state, patch);
  writeHash();
  render();
}

$("#q").addEventListener("input", (e) => update({ q: e.target.value }));
$("#groups").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-g]");
  if (b) update({ g: b.dataset.g });
});
$("#access").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-a]");
  if (b) update({ a: b.dataset.a });
});
$("#sort").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-sort]");
  if (b) update({ sort: b.dataset.sort });
});
$("#reset").addEventListener("click", () => update({ q: "", g: "", a: "" }));

// Expanding a card patches it in place so the grid does not re-render or jump.
$("#grid").addEventListener("click", (e) => {
  const btn = e.target.closest(".card__btn");
  if (!btn) return;
  const card = btn.closest(".card");
  const id = card.dataset.id;
  const prev = state.open && state.open !== id ? $(`.card[data-id="${CSS.escape(state.open)}"]`) : null;
  if (prev) setOpen(prev, false);
  const opening = state.open !== id;
  setOpen(card, opening);
  state.open = opening ? id : "";
  writeHash();
  if (opening) card.scrollIntoView({ block: "nearest", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
});
function setOpen(card, open) {
  const s = byId.get(card.dataset.id);
  const d = card.querySelector(".detail");
  card.toggleAttribute("data-open", open);
  card.querySelector(".card__btn").setAttribute("aria-expanded", String(open));
  d.innerHTML = open ? detailHTML(s) : "";
  d.hidden = !open;
}

// Icons the CDN does not have fall back to a letter avatar.
$("#grid").addEventListener("error", (e) => {
  const img = e.target;
  if (img.tagName !== "IMG") return;
  const ch = (img.dataset.letter.match(/[A-Za-z0-9]/) || ["?"])[0];
  const span = document.createElement("span");
  span.className = "letter";
  span.setAttribute("aria-hidden", "true");
  span.textContent = ch;
  img.replaceWith(span);
}, true);

$("#jump").addEventListener("click", () => $("#idx-title").parentElement.scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" }));
window.addEventListener("hashchange", () => { readHash(); render(); });

readHash();
render();
if (state.open) {
  const c = $(`.card[data-id="${CSS.escape(state.open)}"]`);
  if (c) requestAnimationFrame(() => c.scrollIntoView({ block: "center" }));
}
