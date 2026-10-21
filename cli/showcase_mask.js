// Masks a rendered Home Assistant dashboard before `homelab showcase shots`
// takes its screenshot. Called as (dark) => JSON string of counts by reason.
//
// It never edits HA's DOM: it draws blueprint-coloured overlays in a fixed
// layer above the page, at the boxes of what must not be seen. The words it
// redacts come from hass.states and hass.user at runtime (people, their
// trackers, zones including a renamed home zone), so no name is ever written
// into the repo or the output.
(dark) => {
  const ha = document.querySelector("home-assistant");
  const hass = ha && ha.hass;
  const counts = { _words: 0 };
  const bump = (r) => (counts[r] = (counts[r] || 0) + 1);
  if (!hass) return JSON.stringify(counts);

  const ink = dark ? "#9ccbff" : "#1f4f86";
  const paper = dark ? "#0d2240" : "#f3f0e6";
  const layer = document.createElement("div");
  layer.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:2147483647";
  document.body.appendChild(layer);

  const box = (r, label) => {
    if (r.width < 2 || r.height < 2) return;
    const d = document.createElement("div");
    d.style.cssText =
      `position:fixed;left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px;` +
      `background:${paper};border:1.5px solid ${ink};border-radius:6px;box-sizing:border-box;` +
      `display:flex;align-items:center;justify-content:center;color:${ink};` +
      `font:600 13px/1.2 "JetBrains Mono",ui-monospace,monospace;letter-spacing:.08em;text-transform:uppercase`;
    if (r.width > 90 && r.height > 24) d.textContent = label;
    layer.appendChild(d);
  };
  const bar = (r) => {
    if (r.width < 1 || r.height < 1) return;
    const d = document.createElement("div");
    d.style.cssText = `position:fixed;left:${r.left - 1}px;top:${r.top}px;width:${r.width + 2}px;height:${r.height}px;background:${ink};border-radius:2px`;
    layer.appendChild(d);
  };

  // every element and text node, through shadow roots
  const elements = [];
  const roots = [document];
  (function walk(root) {
    for (const el of root.querySelectorAll("*")) {
      elements.push(el);
      if (el.shadowRoot) {
        roots.push(el.shadowRoot);
        walk(el.shadowRoot);
      }
    }
  })(document);

  // 1. whole cards and rows that show cameras, places, people or security
  const SENSITIVE = {
    camera: "camera", image: "camera", person: "presence", device_tracker: "presence",
    zone: "presence", lock: "lock", alarm_control_panel: "alarm",
  };
  const BY_TAG = {
    "hui-picture-glance-card": "camera", "hui-picture-entity-card": "camera",
    "hui-picture-card": "picture", "hui-picture-elements-card": "picture",
    "hui-map-card": "map", "hui-alarm-panel-card": "alarm", "hui-logbook-card": "logbook",
    "hui-iframe-card": "embedded page", "advanced-camera-card": "camera", "frigate-card": "camera",
    "webrtc-camera": "camera", "hui-image": "camera",
  };
  const entitiesOf = (cfg) => {
    const out = [];
    if (!cfg || typeof cfg !== "object") return out;
    for (const k of ["entity", "camera_image", "image_entity"]) if (typeof cfg[k] === "string") out.push(cfg[k]);
    if (Array.isArray(cfg.entities)) for (const e of cfg.entities) {
      if (typeof e === "string") out.push(e);
      else if (e && typeof e.entity === "string") out.push(e.entity);
    }
    return out;
  };
  const masked = new Set();
  const isInsideMasked = (el) => {
    for (let n = el; n; n = n.parentNode || n.host) if (masked.has(n)) return true;
    return false;
  };
  for (const el of elements) {
    const t = el.localName;
    const card = t.endsWith("-card") || t.endsWith("-row") || t.includes("badge") || t === "hui-image" || t === "webrtc-camera";
    if (!card || t === "ha-card") continue;
    let reason = BY_TAG[t];
    if (!reason) {
      const cfg = el._config || el.config;
      for (const e of entitiesOf(cfg)) {
        const r = SENSITIVE[e.split(".")[0]];
        if (r) { reason = r; break; }
      }
    }
    if (!reason || isInsideMasked(el)) continue;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) continue;
    masked.add(el);
    box(r, "masked");
    bump(reason);
  }
  // raw <video>/<img> of camera streams anywhere else
  for (const el of elements) {
    if ((el.localName === "video" || (el.localName === "img" && /camera_proxy|api\/frigate|go2rtc/.test(el.src || ""))) && !isInsideMasked(el)) {
      const r = el.getBoundingClientRect();
      if (r.width > 2 && r.height > 2) { masked.add(el); box(r, "masked"); bump("camera"); }
    }
  }

  // 2. words: people, their devices, places
  const words = new Set();
  const add = (s, split) => {
    if (!s) return;
    s = String(s).trim();
    if (s.length >= 3) words.add(s);
    if (split) for (const w of s.split(/[\s'’]+/)) if (w.length >= 3) words.add(w);
  };
  const people = Object.values(hass.states).filter(
    (s) => s.entity_id.startsWith("person.") && (s.attributes.user_id || (s.attributes.device_trackers || []).length),
  );
  for (const p of people) add(p.attributes.friendly_name, true);
  if (hass.user) add(hass.user.name, true);
  const personWords = new Set(words);
  for (const s of Object.values(hass.states)) {
    const [domain, obj] = s.entity_id.split(".");
    const name = s.attributes.friendly_name;
    // zone.home is often renamed to the place itself; keep only a generic "Home"
    if (domain === "zone" && !(obj === "home" && /^(home|дом|вкъщи)$/i.test(name || ""))) add(name, false);
    if (domain === "device_tracker" && name) {
      // a tracker named after a person ("<name>'s phone"); other trackers
      // name things (a TV, a router) and would redact ordinary words
      const parts = name.split(/[\s'’]+/);
      if (parts.some((w) => personWords.has(w))) add(name, false);
    }
  }
  counts._words = words.size;
  const list = [...words].sort((a, b) => b.length - a.length);
  const lower = list.map((w) => w.toLocaleLowerCase());

  let hits = 0;
  for (const root of roots) {
    const tw = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let n = tw.nextNode(); n; n = tw.nextNode()) {
      const text = n.nodeValue;
      if (!text || text.length < 3) continue;
      const low = text.toLocaleLowerCase();
      for (const w of lower) {
        let i = low.indexOf(w);
        while (i !== -1) {
          const range = document.createRange();
          range.setStart(n, i);
          range.setEnd(n, i + w.length);
          for (const r of range.getClientRects()) bar(r);
          hits++;
          i = low.indexOf(w, i + w.length);
        }
      }
    }
  }
  // values typed into inputs are not text nodes
  for (const el of elements) {
    if ((el.localName === "input" || el.localName === "textarea") && el.value) {
      const v = el.value.toLocaleLowerCase();
      if (lower.some((w) => v.includes(w))) { bar(el.getBoundingClientRect()); hits++; }
    }
  }
  if (hits) counts["name text"] = hits;
  return JSON.stringify(counts);
}
