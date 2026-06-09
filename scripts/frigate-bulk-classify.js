// Frigate Bulk Classification Labeler
// Paste this into the browser console on the Frigate /classification page
// while viewing a model's training images.
//
// Image URL pattern: /clips/{modelName}/train/{filename}
// Categorize API: POST /api/classification/{modelName}/dataset/categorize
//   body: { category: "...", training_file: "..." }
// Delete API: POST /api/classification/{modelName}/train/delete
//   body: { ids: ["..."] }
// Dataset API: GET /api/classification/{modelName}/dataset
//   returns: { categories: { catName: [files...] }, training_metadata: {...} }

(async () => {
  "use strict";

  // --- Configuration ---
  const API_BASE = window.location.origin + "/api";
  const TOOLBAR_ID = "bulk-classify-toolbar";
  // Frigate's axios instance sends these headers on every request.
  // X-CSRF-TOKEN is required for state-modifying (POST/PUT/DELETE) requests.
  const API_HEADERS = {
    "Content-Type": "application/json",
    "X-CSRF-TOKEN": "1",
    "X-CACHE-BYPASS": "1",
  };

  // Abort if already injected
  if (document.getElementById(TOOLBAR_ID)) {
    console.log("Bulk classifier already active. Refresh page to re-inject.");
    return;
  }

  // --- Extract model name from page ---
  // Training images use src="/clips/{modelName}/train/{filename}"
  let modelName = null;

  // Method 1: Extract from training image src on the page
  for (const img of document.querySelectorAll("img")) {
    const src = img.getAttribute("src") || "";
    const m = src.match(/\/clips\/([^/]+)\/train\//);
    if (m) { modelName = decodeURIComponent(m[1]); break; }
  }

  // Method 2: List all custom models from config and let the user pick
  if (!modelName) {
    try {
      const resp = await fetch(`${API_BASE}/config`);
      const config = await resp.json();
      // Custom classification models are under config.classification.custom
      const models = Object.keys(config.classification?.custom || {});
      if (models.length === 1) {
        modelName = models[0];
      } else if (models.length > 1) {
        modelName = prompt(
          `Multiple classification models found. Enter the model name:\n\n${models.join(", ")}`,
        );
      }
    } catch (_) {}
  }

  if (!modelName) {
    alert(
      "Could not detect model name.\nMake sure you are on the /classification page with training images visible.",
    );
    return;
  }

  console.log(`[bulk-classify] Detected model: "${modelName}"`);

  // --- Fetch categories from the dataset API ---
  let categories = [];
  try {
    const resp = await fetch(`${API_BASE}/classification/${encodeURIComponent(modelName)}/dataset`);
    const data = await resp.json();
    // Dataset response: { categories: { catName: [files...] }, training_metadata: {...} }
    categories = Object.keys(data.categories || data);
  } catch (e) {
    console.error("Failed to fetch categories:", e);
  }

  // Deduplicate
  categories = [...new Set(categories)];
  console.log("[bulk-classify] Categories:", categories);

  // --- Fetch all training filenames and build event groups ---
  // Frigate groups training images by eventId (first two segments of the filename).
  // Filename format: {timestamp}-{randomId}-{timestamp2}-{label}-{score}.webp
  // EventId = "{timestamp}-{randomId}"
  let allTrainFiles = [];
  const eventGroups = {}; // eventId -> [filename, ...]

  function parseEventId(filename) {
    const base = filename.replace(/\.webp$/, "");
    const parts = base.split("-");
    if (parts.length >= 2) return `${parts[0]}-${parts[1]}`;
    return filename; // fallback: treat as its own group
  }

  try {
    const resp = await fetch(
      `${API_BASE}/classification/${encodeURIComponent(modelName)}/train`,
      { headers: API_HEADERS },
    );
    allTrainFiles = await resp.json();
    for (const f of allTrainFiles) {
      const eid = parseEventId(f);
      if (!eventGroups[eid]) eventGroups[eid] = [];
      eventGroups[eid].push(f);
    }
    console.log(
      `[bulk-classify] Loaded ${allTrainFiles.length} training files in ${Object.keys(eventGroups).length} event groups.`,
    );
  } catch (e) {
    console.error("[bulk-classify] Failed to fetch training files:", e);
  }

  // Get all filenames in the same event group as the given filename
  function getGroupFiles(filename) {
    const eid = parseEventId(filename);
    return eventGroups[eid] || [filename];
  }

  // --- State ---
  const selected = new Set();

  // --- Inject styles ---
  const style = document.createElement("style");
  style.textContent = `
    #${TOOLBAR_ID} {
      position: fixed;
      bottom: 20px;
      left: 50%;
      transform: translateX(-50%);
      z-index: 99999;
      background: #1e1e2e;
      border: 1px solid #444;
      border-radius: 12px;
      padding: 12px 20px;
      display: flex;
      align-items: center;
      gap: 12px;
      box-shadow: 0 8px 32px rgba(0,0,0,0.5);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      font-size: 14px;
      color: #cdd6f4;
    }
    #${TOOLBAR_ID} button {
      padding: 6px 14px;
      border: 1px solid #555;
      border-radius: 6px;
      background: #313244;
      color: #cdd6f4;
      cursor: pointer;
      font-size: 13px;
      white-space: nowrap;
    }
    #${TOOLBAR_ID} button:hover {
      background: #45475a;
    }
    #${TOOLBAR_ID} button.primary {
      background: #89b4fa;
      color: #1e1e2e;
      border-color: #89b4fa;
      font-weight: 600;
    }
    #${TOOLBAR_ID} button.primary:hover {
      background: #74c7ec;
    }
    #${TOOLBAR_ID} button.primary:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    #${TOOLBAR_ID} button.danger {
      background: #f38ba8;
      color: #1e1e2e;
      border-color: #f38ba8;
      font-weight: 600;
    }
    #${TOOLBAR_ID} button.danger:hover {
      background: #eba0ac;
    }
    .bulk-classify-dropdown {
      position: relative;
      display: inline-block;
    }
    .bulk-classify-dropdown-btn {
      padding: 6px 14px;
      border: 1px solid #555;
      border-radius: 6px;
      background: #313244;
      color: #cdd6f4;
      cursor: pointer;
      font-size: 13px;
      white-space: nowrap;
      min-width: 140px;
      text-align: left;
    }
    .bulk-classify-dropdown-btn::after {
      content: " ▾";
      float: right;
      margin-left: 8px;
    }
    .bulk-classify-dropdown-menu {
      display: none;
      position: absolute;
      bottom: 100%;
      left: 0;
      margin-bottom: 4px;
      background: #313244;
      border: 1px solid #555;
      border-radius: 6px;
      max-height: 250px;
      overflow-y: auto;
      min-width: 180px;
      box-shadow: 0 -4px 16px rgba(0,0,0,0.4);
      z-index: 100000;
    }
    .bulk-classify-dropdown-menu.open {
      display: block;
    }
    .bulk-classify-dropdown-item {
      padding: 8px 14px;
      cursor: pointer;
      font-size: 13px;
      color: #cdd6f4;
      white-space: nowrap;
    }
    .bulk-classify-dropdown-item:hover {
      background: #45475a;
    }
    .bulk-classify-dropdown-item.active {
      background: #89b4fa;
      color: #1e1e2e;
    }
    #${TOOLBAR_ID} .count {
      font-weight: 600;
      min-width: 30px;
      text-align: center;
    }
    #${TOOLBAR_ID} .separator {
      width: 1px;
      height: 24px;
      background: #555;
    }
    #${TOOLBAR_ID} .progress {
      font-size: 12px;
      color: #a6adc8;
    }
    .bulk-classify-checkbox {
      position: absolute;
      top: 6px;
      left: 6px;
      z-index: 9999;
      width: 22px;
      height: 22px;
      cursor: pointer;
      accent-color: #89b4fa;
      pointer-events: auto;
    }
    .bulk-classify-selected {
      outline: 3px solid #89b4fa !important;
      outline-offset: -3px;
    }
    .bulk-classify-overlay {
      position: fixed;
      inset: 0;
      z-index: 99998;
      background: rgba(0,0,0,0.6);
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .bulk-classify-dialog {
      background: #1e1e2e;
      border: 1px solid #444;
      border-radius: 12px;
      padding: 24px;
      min-width: 350px;
      color: #cdd6f4;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    .bulk-classify-dialog h3 {
      margin: 0 0 16px;
      font-size: 16px;
    }
    .bulk-classify-dialog .progress-bar {
      width: 100%;
      height: 8px;
      background: #313244;
      border-radius: 4px;
      overflow: hidden;
      margin: 12px 0;
    }
    .bulk-classify-dialog .progress-fill {
      height: 100%;
      background: #89b4fa;
      transition: width 0.2s;
    }
    .bulk-classify-dialog .status {
      font-size: 13px;
      color: #a6adc8;
    }
  `;
  document.head.appendChild(style);

  // --- Helper: find all training image cards ---
  function getImageCards() {
    // Training images use src="/clips/{modelName}/train/{filename}"
    // Filenames are like: 1770573871.602803-in4y00-1770573889.027752-none-1.0.webp
    const pattern = /\/clips\/[^/]+\/train\/([^/?#]+)/;
    const imgs = document.querySelectorAll("img");
    const cards = [];
    const seen = new Set();
    for (const img of imgs) {
      const src = img.getAttribute("src") || "";
      const match = src.match(pattern);
      if (match && !seen.has(match[1])) {
        seen.add(match[1]);
        // Walk up to find the card container (Frigate uses aspect-square divs)
        let card =
          img.closest("[class*='aspect-']") ||
          img.closest("[class*='card']") ||
          img.parentElement?.parentElement ||
          img.parentElement;
        // Resolve the full group of filenames for this card
        const groupFiles = getGroupFiles(match[1]);
        cards.push({ element: card, filename: match[1], img, groupFiles });
      }
    }
    return cards;
  }

  // --- Debug: log what images we found ---
  const debugImgs = document.querySelectorAll("img");
  const debugSrcs = Array.from(debugImgs)
    .map((i) => i.getAttribute("src"))
    .filter(Boolean);
  console.log(
    `[bulk-classify] Found ${debugSrcs.length} <img> elements. Sample srcs:`,
    debugSrcs.slice(0, 5),
  );
  const initialCards = getImageCards();
  console.log(
    `[bulk-classify] Matched ${initialCards.length} training image cards.`,
  );

  // --- Add checkboxes to all cards ---
  function injectCheckboxes() {
    const cards = getImageCards();
    for (const { element, filename, groupFiles } of cards) {
      if (element.querySelector(".bulk-classify-checkbox")) continue;

      // Ensure relative positioning for absolute checkbox
      element.style.position = "relative";

      const cb = document.createElement("input");
      cb.type = "checkbox";
      cb.className = "bulk-classify-checkbox";
      cb.dataset.filename = filename;
      cb.checked = selected.has(filename);

      // Show group count badge next to checkbox if group has >1 image
      let badge = null;
      if (groupFiles.length > 1) {
        badge = document.createElement("span");
        badge.className = "bulk-classify-badge";
        badge.textContent = groupFiles.length;
        badge.style.cssText =
          "position:absolute;top:6px;left:32px;z-index:9999;background:#89b4fa;color:#1e1e2e;" +
          "font-size:11px;font-weight:700;padding:1px 5px;border-radius:8px;pointer-events:none;";
      }

      cb.addEventListener("change", (e) => {
        e.stopPropagation();
        if (cb.checked) {
          // Select ALL files in this event group
          for (const f of groupFiles) selected.add(f);
          element.classList.add("bulk-classify-selected");
        } else {
          for (const f of groupFiles) selected.delete(f);
          element.classList.remove("bulk-classify-selected");
        }
        updateCount();
      });

      // Also allow clicking the image to toggle
      element.addEventListener("click", (e) => {
        // Don't intercept if clicking the checkbox itself or a button
        if (
          e.target === cb ||
          e.target.closest("button") ||
          e.target.closest("a")
        )
          return;
        e.preventDefault();
        e.stopPropagation();
        cb.checked = !cb.checked;
        cb.dispatchEvent(new Event("change"));
      });

      element.prepend(cb);
      if (badge) element.appendChild(badge);
    }
  }

  // --- Toolbar ---
  const toolbar = document.createElement("div");
  toolbar.id = TOOLBAR_ID;

  const countLabel = document.createElement("span");
  countLabel.className = "count";
  countLabel.textContent = "0";

  const countText = document.createElement("span");
  countText.textContent = "selected";

  const sep1 = document.createElement("div");
  sep1.className = "separator";

  const selectAllBtn = document.createElement("button");
  selectAllBtn.textContent = "Select All";
  selectAllBtn.addEventListener("click", () => {
    const cards = getImageCards();
    for (const { element, groupFiles } of cards) {
      for (const f of groupFiles) selected.add(f);
      element.classList.add("bulk-classify-selected");
      const cb = element.querySelector(".bulk-classify-checkbox");
      if (cb) cb.checked = true;
    }
    updateCount();
  });

  const deselectBtn = document.createElement("button");
  deselectBtn.textContent = "Deselect All";
  deselectBtn.addEventListener("click", () => {
    const cards = getImageCards();
    for (const { element, groupFiles } of cards) {
      for (const f of groupFiles) selected.delete(f);
      element.classList.remove("bulk-classify-selected");
      const cb = element.querySelector(".bulk-classify-checkbox");
      if (cb) cb.checked = false;
    }
    updateCount();
  });

  const sep2 = document.createElement("div");
  sep2.className = "separator";

  // --- Custom dropdown (replaces native <select> which React intercepts) ---
  let selectedCategory = "";
  const dropdown = document.createElement("div");
  dropdown.className = "bulk-classify-dropdown";

  const dropdownBtn = document.createElement("div");
  dropdownBtn.className = "bulk-classify-dropdown-btn";
  dropdownBtn.textContent = "-- pick category --";

  const dropdownMenu = document.createElement("div");
  dropdownMenu.className = "bulk-classify-dropdown-menu";

  function buildMenuItems() {
    dropdownMenu.innerHTML = "";
    for (const cat of categories) {
      const item = document.createElement("div");
      item.className = "bulk-classify-dropdown-item";
      if (cat === selectedCategory) item.classList.add("active");
      item.textContent = cat;
      item.addEventListener("mousedown", (e) => {
        e.preventDefault();
        e.stopPropagation();
        selectedCategory = cat;
        dropdownBtn.textContent = cat;
        dropdownMenu.classList.remove("open");
        buildMenuItems(); // refresh active state
      });
      dropdownMenu.appendChild(item);
    }
  }
  buildMenuItems();

  dropdownBtn.addEventListener("mousedown", (e) => {
    e.preventDefault();
    e.stopPropagation();
    dropdownMenu.classList.toggle("open");
  });

  // Close dropdown when clicking outside
  document.addEventListener("mousedown", (e) => {
    if (!dropdown.contains(e.target)) {
      dropdownMenu.classList.remove("open");
    }
  });

  dropdown.appendChild(dropdownBtn);
  dropdown.appendChild(dropdownMenu);

  // Allow typing a new category
  const newCatInput = document.createElement("input");
  newCatInput.type = "text";
  newCatInput.placeholder = "or type new...";
  newCatInput.style.cssText =
    "padding:6px 10px;border:1px solid #555;border-radius:6px;background:#313244;color:#cdd6f4;font-size:13px;width:120px;";

  const categorizeBtn = document.createElement("button");
  categorizeBtn.className = "primary";
  categorizeBtn.textContent = "Categorize Selected";

  const deleteBtn = document.createElement("button");
  deleteBtn.className = "danger";
  deleteBtn.textContent = "Delete Selected";

  toolbar.append(
    countLabel,
    countText,
    sep1,
    selectAllBtn,
    deselectBtn,
    sep2,
    dropdown,
    newCatInput,
    categorizeBtn,
    deleteBtn,
  );

  // Prevent events from bubbling out of toolbar to React's root handler
  for (const evt of ["click", "mousedown", "mouseup", "pointerdown", "pointerup", "focus", "blur"]) {
    toolbar.addEventListener(evt, (e) => e.stopPropagation());
  }

  document.body.appendChild(toolbar);

  function updateCount() {
    countLabel.textContent = selected.size;
    categorizeBtn.disabled = selected.size === 0;
  }

  // --- Progress dialog ---
  function showProgress(title, total) {
    const overlay = document.createElement("div");
    overlay.className = "bulk-classify-overlay";
    const dialog = document.createElement("div");
    dialog.className = "bulk-classify-dialog";
    dialog.innerHTML = `
      <h3>${title}</h3>
      <div class="status">0 / ${total}</div>
      <div class="progress-bar"><div class="progress-fill" style="width:0%"></div></div>
      <div class="errors" style="color:#f38ba8;font-size:12px;margin-top:8px"></div>
    `;
    overlay.appendChild(dialog);
    document.body.appendChild(overlay);

    return {
      update(current, errorMsg) {
        const pct = Math.round((current / total) * 100);
        dialog.querySelector(".status").textContent =
          `${current} / ${total}`;
        dialog.querySelector(".progress-fill").style.width = pct + "%";
        if (errorMsg) {
          dialog.querySelector(".errors").textContent += errorMsg + "\n";
        }
      },
      close() {
        overlay.remove();
      },
    };
  }

  // --- Categorize handler ---
  // POST /api/classification/{modelName}/dataset/categorize
  // body: { category: "...", training_file: "..." }
  categorizeBtn.addEventListener("click", async () => {
    const category = newCatInput.value.trim() || selectedCategory;
    if (!category) {
      alert("Select a category or type a new one.");
      return;
    }
    if (selected.size === 0) {
      alert("No images selected.");
      return;
    }

    const files = Array.from(selected);
    if (
      !confirm(
        `Categorize ${files.length} image(s) as "${category}"?`,
      )
    )
      return;

    const progress = showProgress(
      `Categorizing as "${category}"`,
      files.length,
    );
    let errors = 0;

    for (let i = 0; i < files.length; i++) {
      try {
        const resp = await fetch(
          `${API_BASE}/classification/${encodeURIComponent(modelName)}/dataset/categorize`,
          {
            method: "POST",
            headers: API_HEADERS,
            body: JSON.stringify({
              category: category,
              training_file: files[i],
            }),
          },
        );
        if (!resp.ok) {
          const text = await resp.text();
          progress.update(i + 1, `Failed: ${files[i]} - ${text}`);
          errors++;
        } else {
          progress.update(i + 1);
        }
      } catch (e) {
        progress.update(i + 1, `Error: ${files[i]} - ${e.message}`);
        errors++;
      }
    }

    setTimeout(() => {
      progress.close();
      if (errors === 0) {
        selected.clear();
        updateCount();
        alert(
          `Done! ${files.length} image(s) categorized as "${category}".\nRefreshing the training view...`,
        );
        window.location.reload();
      } else {
        alert(
          `Completed with ${errors} error(s). Check console for details.`,
        );
      }
    }, 500);
  });

  // --- Delete handler ---
  // POST /api/classification/{modelName}/train/delete
  // body: { ids: ["filename1", "filename2", ...] }
  deleteBtn.addEventListener("click", async () => {
    if (selected.size === 0) {
      alert("No images selected.");
      return;
    }

    const files = Array.from(selected);
    if (
      !confirm(
        `DELETE ${files.length} training image(s)? This cannot be undone.`,
      )
    )
      return;

    const progress = showProgress("Deleting training images", 1);

    try {
      const resp = await fetch(
        `${API_BASE}/classification/${encodeURIComponent(modelName)}/train/delete`,
        {
          method: "POST",
          headers: API_HEADERS,
          body: JSON.stringify({ ids: files }),
        },
      );
      if (!resp.ok) {
        const text = await resp.text();
        progress.update(1, `Failed: ${text}`);
      } else {
        progress.update(1);
      }
    } catch (e) {
      progress.update(1, `Error: ${e.message}`);
    }

    setTimeout(() => {
      progress.close();
      selected.clear();
      updateCount();
      alert(`Deleted ${files.length} training image(s).\nRefreshing...`);
      window.location.reload();
    }, 500);
  });

  // --- Initial injection + MutationObserver for dynamic loading ---
  injectCheckboxes();

  const observer = new MutationObserver(() => {
    injectCheckboxes();
  });
  observer.observe(document.body, { childList: true, subtree: true });

  updateCount();
  console.log(
    `Bulk classifier active for model "${modelName}". ${categories.length} categories found: [${categories.join(", ")}]`,
  );
})();
