// Minimal stealth init script for Playwright-driven Chromium.
// Vendored from puppeteer-extra-plugin-stealth/evasions/* (MIT) — covers:
//   webdriver, chrome.runtime, navigator.plugins, navigator.languages,
//   Permissions.query, WebGL getParameter (vendor + renderer spoof).
// Run via context.add_init_script() so it executes before any page script.
(() => {
  // navigator.webdriver — most common detection, removed entirely.
  Object.defineProperty(Navigator.prototype, 'webdriver', { get: () => undefined });

  // window.chrome.runtime — many sites check that real Chrome exposes this.
  if (!window.chrome) window.chrome = {};
  window.chrome.runtime = window.chrome.runtime || {};

  // navigator.plugins — headless reports zero; spoof a plausible PDF viewer.
  Object.defineProperty(navigator, 'plugins', {
    get: () => [{ name: 'Chrome PDF Plugin' }, { name: 'Chrome PDF Viewer' }, { name: 'Native Client' }],
  });

  // navigator.languages — headless returns empty array.
  Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });

  // Permissions.query — headless returns 'denied' for notifications instead of 'default'.
  const origQuery = window.navigator.permissions && window.navigator.permissions.query;
  if (origQuery) {
    window.navigator.permissions.query = (parameters) =>
      parameters && parameters.name === 'notifications'
        ? Promise.resolve({ state: Notification.permission })
        : origQuery(parameters);
  }

  // WebGL getParameter — spoof vendor + renderer strings to a real GPU.
  const spoofGl = (proto) => {
    if (!proto) return;
    const orig = proto.getParameter;
    proto.getParameter = function (parameter) {
      if (parameter === 37445) return 'Intel Inc.';                   // UNMASKED_VENDOR_WEBGL
      if (parameter === 37446) return 'Intel Iris OpenGL Engine';     // UNMASKED_RENDERER_WEBGL
      return orig.apply(this, arguments);
    };
  };
  spoofGl(window.WebGLRenderingContext && window.WebGLRenderingContext.prototype);
  spoofGl(window.WebGL2RenderingContext && window.WebGL2RenderingContext.prototype);

  // disable-devtool.js (theajack/disable-devtool) auto-inits via a script
  // tag with `disable-devtool-auto`. Its Performance detector trips under
  // Playwright (CDP adds console.log latency vs console.table) and the
  // redirect URL is hard-coded — for hmembeds that's google.com.
  // Hide the auto-init marker so the library's IIFE exits early.
  const origQS = Document.prototype.querySelector;
  Document.prototype.querySelector = function (sel) {
    if (typeof sel === 'string' && sel.indexOf('disable-devtool-auto') !== -1) return null;
    return origQS.apply(this, arguments);
  };
})();
