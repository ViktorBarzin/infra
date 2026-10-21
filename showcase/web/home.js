// Home variant: the home automation side of the homelab. Counts come from
// snap.home (aggregates only: no entity, room, person or automation names);
// the dashboard shots come from home/manifest.json, captured on demand.
import {
  loadSnapshot, renderSwitcher, renderFooter, fmt, escapeHTML,
  HOME_KINDS, HOME_RADIOS, HOME_AUTOMATIONS,
} from "./shared.js";

const $ = (s) => document.querySelector(s);
const esc = escapeHTML;
const label = (map, id) => map[id] || { label: id, detail: "" };
const plural = (n, one, many) => `${fmt.int(n)} ${n === 1 ? one : many}`;

function renderHero(h) {
  if (h.stale && h.as_of) {
    const d = new Date(h.as_of).toLocaleDateString(undefined, { dateStyle: "medium" });
    $("#asof").textContent = ` · as of ${d}`;
  }
  $("#site").textContent = h.site || "Sofia";
  const c = h.counts || {};
  $("#lede").innerHTML =
    `One <strong>Home Assistant</strong> instance, a VM on the same server as the cluster, runs the family home: ` +
    `<strong>${plural(c.devices || 0, "device", "devices")}</strong> from <strong>${plural(c.integration_kinds || 0, "kind", "kinds")} of integration</strong>, ` +
    `and <strong>${plural(c.automations || 0, "automation", "automations")}</strong> keeping them in step.`;
  const stats = [
    ["devices", "devices"],
    ["integration_kinds", "kinds of integration"],
    ["automations", "automations"],
    ["dashboards", "dashboards"],
  ].filter(([k]) => c[k] != null);
  $("#stats").innerHTML = stats
    .map(([k, l]) => `<div><dt>${esc(l)}</dt><dd>${esc(fmt.compact(c[k]))}</dd></div>`).join("");
}

function bars(rows) {
  const max = Math.max(...rows.map((r) => r.n), 1);
  return rows.map((r) => `<li>
    <span class="bl">${esc(r.label)}</span><span class="bn">${fmt.int(r.n)}</span>
    <span class="track" aria-hidden="true"><span class="fill" style="width:${((r.n / max) * 100).toFixed(1)}%"></span></span>
    ${r.detail ? `<span class="bd">${esc(r.detail)}</span>` : ""}</li>`).join("");
}

function securityLine(s) {
  if (!s) return "";
  const parts = [
    s.cameras ? plural(s.cameras, "camera", "cameras") : "",
    s.alarm_panels ? plural(s.alarm_panels, "alarm panel", "alarm panels") : "",
    s.locks ? plural(s.locks, "smart lock", "smart locks") : "",
  ].filter(Boolean);
  if (!parts.length) return "";
  const text = parts.length > 1 ? `${parts.slice(0, -1).join(", ")} and ${parts.at(-1)}` : parts[0];
  return `<p class="security__tag">Security</p><p class="security__text">${esc(text)}.</p>
    <p class="security__note">Counted, not named: the brands and how they are wired stay off this page.</p>`;
}

function renderInventory(h) {
  const kinds = (h.kinds || []).filter((k) => k.count > 0);
  $("#kinds").innerHTML = kinds.map((k) => {
    const L = label(HOME_KINDS, k.id);
    return `<div><dt><b>${esc(L.label)}</b>${L.detail ? `<span>${esc(L.detail)}</span>` : ""}</dt><dd>${esc(fmt.compact(k.count))}</dd></div>`;
  }).join("");
  const sec = securityLine(h.security);
  $("#security").innerHTML = sec;
  $("#security").hidden = !sec;

  const radios = (h.radios || []).filter((r) => r.devices > 0)
    .map((r) => ({ ...label(HOME_RADIOS, r.id), n: r.devices }))
    .sort((a, b) => b.n - a.n);
  $("#radios").innerHTML = bars(radios);

  const autos = (h.automations || []).filter((a) => a.count > 0)
    .map((a) => ({ ...label(HOME_AUTOMATIONS, a.id), n: a.count }));
  $("#autos").innerHTML = bars(autos);

  const ints = [...(h.integrations || [])].sort((a, b) => (b.devices || 0) - (a.devices || 0) || a.name.localeCompare(b.name));
  $("#integrations").innerHTML = ints.map((i) =>
    `<li><span>${esc(i.name)}</span>${i.devices ? `<b>${fmt.int(i.devices)}</b>` : ""}</li>`).join("");
  const kindsN = h.counts?.integration_kinds;
  $("#int-note").textContent = kindsN && kindsN > ints.length
    ? `${ints.length} of ${kindsN} kinds named here. The rest are Home Assistant's own helpers and the security integrations, which this page counts but does not name.`
    : "";
  $("#inventory").hidden = false;
}

function renderHighlights(h) {
  const hs = h.highlights || [];
  if (!hs.length) return;
  $("#highlights").innerHTML = hs.map((x, i) => `<article class="hl">
    <p class="hl__no">Detail ${String.fromCharCode(65 + i)}</p>
    <h3 class="hl__title">${esc(x.title)}</h3>
    ${String(x.body || "").split(/\n{2,}/).map((p) => `<p>${esc(p.trim())}</p>`).join("")}
    ${x.url ? `<a class="hl__link" href="${esc(x.url)}">Read the doc <span aria-hidden="true">&rarr;</span></a>` : ""}
  </article>`).join("");
  $("#how").hidden = false;
}

// ---------- dashboards ----------
const dash = { list: [], at: 0, form: window.matchMedia("(max-width: 640px)").matches ? "phone" : "desktop" };
const dark = window.matchMedia("(prefers-color-scheme: dark)");
const titleOf = (d) => d.title || (d.id.length <= 2 ? d.id.toUpperCase() : d.id.charAt(0).toUpperCase() + d.id.slice(1));

function dashHTML(d) {
  const f = d.files || {};
  const light = f[`${dash.form}-light`], darkF = f[`${dash.form}-dark`] || light;
  if (!light) return `<p class="empty">No ${dash.form} capture of this dashboard yet.</p>`;
  const full = dark.matches ? darkF : light;
  return `<figure class="dash dash--${dash.form}">
    <a class="dash__frame" href="${esc(full)}" target="_blank" rel="noopener" aria-label="${esc(titleOf(d))}: open the full screenshot">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="${esc(darkF)}">
        <img src="${esc(light)}" alt="${esc(titleOf(d))} dashboard: ${esc(d.caption)}">
      </picture>
      <span class="dash__open">Open full size <span aria-hidden="true">&nearr;</span></span>
    </a>
    <figcaption><b>${esc(titleOf(d))}</b> ${esc(d.caption)}</figcaption>
  </figure>`;
}

function renderDashes() {
  $("#dash-tabs").innerHTML = dash.list.map((d, i) =>
    `<button type="button" data-dash="${i}" aria-pressed="${i === dash.at}">${esc(titleOf(d))}</button>`).join("");
  $("#dashes").innerHTML = dashHTML(dash.list[dash.at]);
  document.querySelectorAll("[data-form]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.form === dash.form)));
}

async function loadDashboards() {
  let list;
  try {
    const r = await fetch("home/manifest.json", { cache: "no-cache" });
    const type = r.headers.get("content-type") || "";
    if (!r.ok || !type.includes("json")) return;
    list = await r.json();
  } catch {
    return;
  }
  if (!Array.isArray(list) || !list.length) return;
  dash.list = list;
  renderDashes();
  $("#dashboards").addEventListener("click", (e) => {
    const t = e.target.closest("[data-dash]"), f = e.target.closest("[data-form]");
    if (t) dash.at = +t.dataset.dash;
    else if (f) dash.form = f.dataset.form;
    else return;
    renderDashes();
  });
  dark.addEventListener("change", renderDashes);
  $("#dashboards").hidden = false;
}

async function main() {
  renderSwitcher($("#switcher"), "home.html");
  let snap;
  try {
    snap = await loadSnapshot();
  } catch (err) {
    $("#lede").textContent = `Could not load the snapshot: ${err.message}`;
    return;
  }
  renderFooter($("#footer"), snap);
  const h = snap.home;
  if (!h) {
    $("#lede").textContent = "The home section is unavailable right now. The rest of the homelab is a tab away.";
    $("#stats").hidden = true;
    return;
  }
  renderHero(h);
  renderInventory(h);
  renderHighlights(h);
  loadDashboards();
}

main();
