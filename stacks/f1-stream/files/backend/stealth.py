"""Vendored Playwright stealth init script.

Mirror of `stacks/chrome-service/files/stealth.js`. Kept in sync by hand
— update both files together if the JS is changed.
"""

STEALTH_JS = r"""
(() => {
  Object.defineProperty(Navigator.prototype, 'webdriver', { get: () => undefined });
  if (!window.chrome) window.chrome = {};
  window.chrome.runtime = window.chrome.runtime || {};
  Object.defineProperty(navigator, 'plugins', {
    get: () => [{ name: 'Chrome PDF Plugin' }, { name: 'Chrome PDF Viewer' }, { name: 'Native Client' }],
  });
  Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
  const origQuery = window.navigator.permissions && window.navigator.permissions.query;
  if (origQuery) {
    window.navigator.permissions.query = (parameters) =>
      parameters && parameters.name === 'notifications'
        ? Promise.resolve({ state: Notification.permission })
        : origQuery(parameters);
  }
  const spoofGl = (proto) => {
    if (!proto) return;
    const orig = proto.getParameter;
    proto.getParameter = function (parameter) {
      if (parameter === 37445) return 'Intel Inc.';
      if (parameter === 37446) return 'Intel Iris OpenGL Engine';
      return orig.apply(this, arguments);
    };
  };
  spoofGl(window.WebGLRenderingContext && window.WebGLRenderingContext.prototype);
  spoofGl(window.WebGL2RenderingContext && window.WebGL2RenderingContext.prototype);
  // disable-devtool.js auto-init evasion: hide the marker attribute so the
  // library's IIFE exits early. Without this, hmembeds-class players redirect
  // to google.com when the Performance detector trips under Playwright.
  const origQS = Document.prototype.querySelector;
  Document.prototype.querySelector = function (sel) {
    if (typeof sel === 'string' && sel.indexOf('disable-devtool-auto') !== -1) return null;
    return origQS.apply(this, arguments);
  };
})();
"""
