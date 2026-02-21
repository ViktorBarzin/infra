// Toast notification system
const TOAST_ICONS = {
  success: '\u2705',
  error: '\u274C',
  warning: '\u26A0\uFE0F',
  info: '\u2139\uFE0F'
};

function showToast(message, type = 'info', duration = 4000) {
  const container = document.getElementById('toast-container');
  const toast = document.createElement('div');
  toast.className = `toast ${type}`;
  toast.innerHTML = `
    <span class="toast-icon">${TOAST_ICONS[type] || TOAST_ICONS.info}</span>
    <span class="toast-message">${escapeHtml(message)}</span>
    <button class="toast-close" onclick="dismissToast(this.parentElement)">&times;</button>
  `;
  container.appendChild(toast);

  if (duration > 0) {
    setTimeout(() => dismissToast(toast), duration);
  }
}

function dismissToast(toast) {
  if (!toast || toast.classList.contains('toast-out')) return;
  toast.classList.add('toast-out');
  toast.addEventListener('animationend', () => toast.remove());
}

// Confirm dialog (replaces window.confirm)
function showConfirm(message) {
  return new Promise((resolve) => {
    const overlay = document.createElement('div');
    overlay.className = 'confirm-overlay';
    overlay.innerHTML = `
      <div class="confirm-box">
        <div class="confirm-msg">${escapeHtml(message)}</div>
        <div class="confirm-actions">
          <button class="btn-secondary" id="confirm-cancel">Cancel</button>
          <button class="btn-primary" id="confirm-ok">Confirm</button>
        </div>
      </div>
    `;
    document.body.appendChild(overlay);

    overlay.querySelector('#confirm-ok').addEventListener('click', () => {
      overlay.remove();
      resolve(true);
    });
    overlay.querySelector('#confirm-cancel').addEventListener('click', () => {
      overlay.remove();
      resolve(false);
    });
    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) {
        overlay.remove();
        resolve(false);
      }
    });
  });
}

// Mobile nav hamburger toggle
function toggleMobileNav() {
  const tabs = document.getElementById('tabs');
  tabs.classList.toggle('open');
}

// Tab switching
function switchTab(tab) {
  closeRedditViewer();

  document.querySelectorAll('.tab-btn').forEach(b => {
    b.classList.toggle('active', b.dataset.tab === tab);
  });
  document.querySelectorAll('.tab-content').forEach(c => {
    c.classList.toggle('active', c.id === 'content-' + tab);
  });

  // Close mobile nav
  document.getElementById('tabs').classList.remove('open');

  // Load data for the tab
  switch (tab) {
    case 'streams':
      loadPublicStreams();
      break;
    case 'reddit':
      loadRedditLinks();
      break;
    case 'mine':
      loadMyStreams();
      break;
    case 'admin':
      loadAdminStreams();
      break;
  }
}

// Initialize
document.addEventListener('DOMContentLoaded', async () => {
  checkAuth();
  await loadPublicStreams();

  const grid = document.getElementById('stream-grid');
  const badge = document.getElementById('live-badge');
  if (badge && grid && grid.children.length > 0) {
    badge.hidden = false;
  }
});

// Close Reddit viewer on Escape
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    const viewer = document.getElementById('reddit-viewer');
    if (viewer && !viewer.classList.contains('hidden')) {
      closeRedditViewer();
    }
  }
});
