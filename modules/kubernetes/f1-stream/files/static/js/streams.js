async function loadPublicStreams() {
  const grid = document.getElementById('stream-grid');
  const empty = document.getElementById('streams-empty');

  try {
    const resp = await fetch('/api/streams/public');
    const streams = await resp.json();

    if (!streams || streams.length === 0) {
      grid.innerHTML = '';
      empty.style.display = '';
      return;
    }

    empty.style.display = 'none';
    grid.innerHTML = streams.map(s => streamCard(s, !!currentUser)).join('');
  } catch (e) {
    console.error('Failed to load streams:', e);
    grid.innerHTML = '';
    empty.style.display = '';
  }
}

async function loadMyStreams() {
  const grid = document.getElementById('my-stream-grid');
  const empty = document.getElementById('mine-empty');

  try {
    const resp = await fetch('/api/streams/mine');
    const streams = await resp.json();

    if (!streams || streams.length === 0) {
      grid.innerHTML = '';
      empty.style.display = '';
      return;
    }

    empty.style.display = 'none';
    grid.innerHTML = streams.map(s => streamCard(s, true)).join('');
  } catch (e) {
    console.error('Failed to load my streams:', e);
  }
}

async function loadRedditLinks() {
  const list = document.getElementById('reddit-list');
  const empty = document.getElementById('reddit-empty');

  try {
    const [scrapedResp, streamsResp] = await Promise.all([
      fetch('/api/scraped'),
      fetch('/api/streams/public')
    ]);
    const links = await scrapedResp.json();
    const streams = await streamsResp.json();

    const importedURLs = new Set((streams || []).map(s => s.url));

    if (!links || links.length === 0) {
      list.innerHTML = '';
      empty.style.display = '';
      return;
    }

    empty.style.display = 'none';
    list.innerHTML = links.map(l => {
      const imported = importedURLs.has(l.url);
      const actionHtml = imported
        ? `<span class="badge badge-imported">Imported</span>`
        : `<button class="btn-import" onclick="importRedditLink('${escapeHtml(l.id)}')">Import</button>`;
      return `
      <li>
        <span class="link-source-badge">${escapeHtml(l.source)}</span>
        <div class="link-title">
          <a href="${escapeHtml(l.url)}" target="_blank" rel="noopener">${escapeHtml(l.title || l.url)}</a>
        </div>
        ${actionHtml}
        <a href="${escapeHtml(l.url)}" target="_blank" rel="noopener" class="link-open-icon-wrap" title="Open in new tab">
          <svg class="link-open-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>
        </a>
      </li>
    `;
    }).join('');
  } catch (e) {
    console.error('Failed to load Reddit links:', e);
  }
}

async function importRedditLink(id) {
  try {
    const resp = await fetch(`/api/scraped/${id}/import`, { method: 'POST' });
    if (!resp.ok) {
      const err = await resp.json();
      showToast(err.error || 'Failed to import', 'error');
      return;
    }
    showToast('Stream imported', 'success');
    loadRedditLinks();
    loadPublicStreams();
  } catch (e) {
    showToast('Failed to import stream', 'error');
  }
}

async function loadAdminStreams() {
  const container = document.getElementById('admin-stream-list');
  const statsContainer = document.getElementById('admin-stats');
  try {
    const resp = await fetch('/api/admin/streams');
    const streams = await resp.json();

    if (!streams || streams.length === 0) {
      statsContainer.innerHTML = '';
      container.innerHTML = '<div class="empty-state"><span class="empty-icon">&#128203;</span><div class="empty-title">No Streams</div><p class="empty-desc">No streams have been submitted yet.</p></div>';
      return;
    }

    const total = streams.length;
    const published = streams.filter(s => s.published).length;
    const drafts = total - published;

    statsContainer.innerHTML = `
      <div class="stat-card">
        <div class="stat-number">${total}</div>
        <div class="stat-label">Total</div>
      </div>
      <div class="stat-card">
        <div class="stat-number">${published}</div>
        <div class="stat-label">Published</div>
      </div>
      <div class="stat-card">
        <div class="stat-number">${drafts}</div>
        <div class="stat-label">Drafts</div>
      </div>
    `;

    container.innerHTML = streams.map(s => `
      <div class="admin-stream">
        <div class="info">
          <span class="status-dot ${s.published ? 'published' : 'draft'}"></span>
          <div class="stream-details">
            <div class="stream-title">
              ${escapeHtml(s.title)}
              <span class="badge ${s.published ? 'badge-published' : 'badge-draft'}">
                ${s.published ? 'Published' : 'Draft'}
              </span>
            </div>
            <div class="stream-url">${escapeHtml(s.url)}</div>
            ${s.submitted_by ? `<div class="stream-submitter">by ${escapeHtml(s.submitted_by)}</div>` : ''}
          </div>
        </div>
        <div class="actions">
          <button onclick="togglePublish('${s.id}')" class="${s.published ? 'btn-secondary-sm' : 'btn-primary-sm'}">
            ${s.published ? 'Unpublish' : 'Publish'}
          </button>
          <button onclick="deleteStream('${s.id}', true)" class="btn-danger-sm">Delete</button>
        </div>
      </div>
    `).join('');
  } catch (e) {
    console.error('Failed to load admin streams:', e);
  }
}

function streamCard(stream, canDelete) {
  const deleteBtn = canDelete
    ? `<button onclick="event.stopPropagation(); deleteStream('${stream.id}', false)" class="icon-btn danger" title="Delete stream">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>
      </button>`
    : '';

  return `
    <div class="stream-card" data-stream-id="${stream.id}"
         onclick="openBrowserSession('${stream.id}', '${escapeAttr(stream.title)}', '${escapeAttr(stream.url)}')">
      <div class="card-body">
        <div class="card-icon">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="14" rx="2" ry="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>
        </div>
        <div class="card-title">${escapeHtml(stream.title)}</div>
        <div class="card-url">${escapeHtml(stream.url)}</div>
      </div>
      <div class="card-bar">
        <div class="card-actions">
          <a href="${escapeHtml(stream.url)}" target="_blank" rel="noopener" onclick="event.stopPropagation()" class="icon-btn" title="Open original">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>
          </a>
          ${deleteBtn}
        </div>
      </div>
    </div>
  `;
}

async function _submitStreamCommon(urlId, titleId, successMsg, reloadFn) {
  const urlInput = document.getElementById(urlId);
  const titleInput = document.getElementById(titleId);
  const url = urlInput.value.trim();
  const title = titleInput.value.trim();

  if (!url) {
    showToast('URL is required', 'warning');
    return;
  }

  try {
    new URL(url);
  } catch {
    showToast('Please enter a valid URL', 'warning');
    return;
  }

  try {
    const resp = await fetch('/api/streams', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url, title })
    });

    if (!resp.ok) {
      const err = await resp.json();
      showToast(err.error || 'Failed to add stream', 'error');
      return;
    }

    urlInput.value = '';
    titleInput.value = '';
    showToast(successMsg, 'success');
    reloadFn();
  } catch (e) {
    showToast('Failed to add stream', 'error');
  }
}

async function addPublicStream() {
  await _submitStreamCommon('public-submit-url', 'public-submit-title', 'Stream added', loadPublicStreams);
}

async function submitStream() {
  await _submitStreamCommon('submit-url', 'submit-title', 'Stream submitted for review', loadMyStreams);
}

async function deleteStream(id, isAdmin) {
  const confirmed = await showConfirm('Delete this stream?');
  if (!confirmed) return;

  try {
    const resp = await fetch(`/api/streams/${id}`, { method: 'DELETE' });
    if (!resp.ok) {
      const err = await resp.json();
      showToast(err.error || 'Failed to delete', 'error');
      return;
    }
    showToast('Stream deleted', 'success');
    if (isAdmin) {
      loadAdminStreams();
    } else {
      loadMyStreams();
    }
    loadPublicStreams();
  } catch (e) {
    showToast('Failed to delete stream', 'error');
  }
}

async function togglePublish(id) {
  try {
    const resp = await fetch(`/api/streams/${id}/publish`, { method: 'PUT' });
    if (!resp.ok) {
      showToast('Failed to toggle publish', 'error');
      return;
    }
    showToast('Stream updated', 'success');
    loadAdminStreams();
    loadPublicStreams();
  } catch (e) {
    showToast('Failed to toggle publish', 'error');
  }
}

async function refreshRedditLinks() {
  try {
    const resp = await fetch('/api/scraped/refresh', { method: 'POST' });
    if (!resp.ok) {
      showToast('Failed to trigger refresh', 'error');
      return;
    }
    showToast('Refreshing links from Reddit...', 'info');

    let attempts = 0;
    const maxAttempts = 15;
    const poll = setInterval(async () => {
      attempts++;
      await loadRedditLinks();
      if (attempts >= maxAttempts) {
        clearInterval(poll);
      }
    }, 2000);
  } catch (e) {
    showToast('Failed to trigger refresh', 'error');
  }
}

async function triggerScrape() {
  try {
    await fetch('/api/admin/scrape', { method: 'POST' });
    showToast('Scrape triggered', 'success');
  } catch (e) {
    showToast('Failed to trigger scrape', 'error');
  }
}

function closeRedditViewer() {
  const viewer = document.getElementById('reddit-viewer');
  if (!viewer) return;
  viewer.classList.add('hidden');
  const contentEl = viewer.querySelector('.reddit-viewer-content');
  contentEl.querySelectorAll(':scope > :not(#reddit-viewer-loader)').forEach(el => el.remove());
}

// --- Browser Session Viewer (Iframe Proxy) ---

function openBrowserSession(streamId, streamTitle, streamURL) {
  const viewer = document.getElementById('browser-viewer');
  const statusEl = viewer.querySelector('.browser-viewer-status');
  const contentEl = viewer.querySelector('.browser-viewer-content');
  const loader = document.getElementById('browser-viewer-loader');
  const urlText = document.getElementById('browser-url');
  const openOriginal = document.getElementById('browser-open-original');

  statusEl.textContent = 'Loading...';
  statusEl.classList.remove('connected');
  loader.classList.remove('hidden');

  // Parse the stream URL to extract origin and path
  let parsed;
  try {
    parsed = new URL(streamURL);
  } catch (e) {
    statusEl.textContent = 'Invalid URL';
    loader.classList.add('hidden');
    showToast('Invalid stream URL', 'error');
    return;
  }

  const origin = parsed.origin;
  const pathAndSearch = parsed.pathname + parsed.search + parsed.hash;

  // Base64-encode the origin (URL-safe, no padding)
  const b64Origin = btoa(origin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  // Build proxy URL
  const proxyURL = '/proxy/' + b64Origin + pathAndSearch;

  if (urlText) urlText.textContent = streamURL;
  if (openOriginal) openOriginal.href = streamURL;

  // Hide all tab content sections and show the viewer
  document.querySelectorAll('.tab-content').forEach(s => s.classList.remove('active'));
  viewer.classList.remove('hidden');
  viewer.classList.add('active');

  // Remove any existing iframe
  contentEl.querySelectorAll('.browser-iframe').forEach(el => el.remove());

  // Create iframe with sandbox to prevent frame-busting and top-navigation
  const iframe = document.createElement('iframe');
  iframe.src = proxyURL;
  iframe.className = 'browser-iframe';
  iframe.setAttribute('sandbox', 'allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox allow-presentation');
  iframe.setAttribute('allow', 'autoplay; encrypted-media; fullscreen');
  iframe.setAttribute('allowfullscreen', '');
  iframe.onload = function() {
    loader.classList.add('hidden');
    statusEl.textContent = 'Connected';
    statusEl.classList.add('connected');
  };
  contentEl.appendChild(iframe);
}

function closeBrowserSession() {
  const viewer = document.getElementById('browser-viewer');
  viewer.classList.add('hidden');
  viewer.classList.remove('active');
  const contentEl = viewer.querySelector('.browser-viewer-content');
  contentEl.querySelectorAll('.browser-iframe').forEach(el => el.remove());
  const statusEl = viewer.querySelector('.browser-viewer-status');
  statusEl.textContent = '';
  statusEl.classList.remove('connected');
  const urlText = document.getElementById('browser-url');
  if (urlText) urlText.textContent = '';

  // Restore the previously active tab
  const activeTab = document.querySelector('.tab-btn.active');
  if (activeTab) {
    const tabName = activeTab.dataset.tab;
    const content = document.getElementById('content-' + tabName);
    if (content) content.classList.add('active');
  }
}
