// Unit tests for the browser_runner pre-connect target sweep.
// Run directly (`node cli/browser_runner_test.js`) or via TestBrowserRunnerJS.
'use strict';
const assert = require('assert');
const { contextlessTargets, browserWSURL } = require('./browser_runner.js');

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log('ok   ' + name);
  } catch (e) {
    failures++;
    console.log('FAIL ' + name + ': ' + e.message);
  }
}

// The exact targetInfo patchright choked on in infra issue #98, copied from the
// crash dump. No browserContextId field at all, which is the whole problem.
const orphanFromIssue98 = {
  targetId: '6D71A05B00BDB41A185ADD2043A71627',
  type: 'service_worker',
  title: 'Service Worker https://embed.st/embed/admin/ppv-azerbaijan-grand-prix-practice-3/sw.js',
  url: 'https://embed.st/embed/admin/ppv-azerbaijan-grand-prix-practice-3/sw.js',
  attached: true,
  canAccessOpener: false,
};

// Measured on a live pool worker (chrome-worker-801567ad, 2026-09-19): the
// worker's own extension service workers sit in the default context with a
// real id. They must survive the sweep.
const extensionWorkerA = {
  targetId: 'C7BBAD4B2FC41B59507B0395409E6EB9',
  type: 'service_worker',
  url: 'chrome-extension://fignfifoniblkonapihmkfakmlgkbkcf/service_worker.js',
  browserContextId: '6C17B9C6E7BDD7B39504AA902A8EFF45',
};
const extensionWorkerB = {
  targetId: 'F7602413F6E0937078CBA96AA488667E',
  type: 'service_worker',
  url: 'chrome-extension://ghbmnnjooekpmoecnnnilnnbdlolhkhi/service_worker.js',
  browserContextId: '6C17B9C6E7BDD7B39504AA902A8EFF45',
};
const idlePage = {
  targetId: '4D76166497541BB6B64C279042A3BFFD',
  type: 'page',
  url: 'about:blank',
  browserContextId: '6C17B9C6E7BDD7B39504AA902A8EFF45',
};
const browserTarget = { targetId: 'B00', type: 'browser', url: '' };

check('selects the orphan from issue #98', () => {
  const got = contextlessTargets([orphanFromIssue98]);
  assert.strictEqual(got.length, 1);
  assert.strictEqual(got[0].targetId, '6D71A05B00BDB41A185ADD2043A71627');
});

check('leaves the extension service workers alone', () => {
  const got = contextlessTargets([extensionWorkerA, extensionWorkerB, idlePage]);
  assert.deepStrictEqual(got, []);
});

check('picks only the orphan out of a real target list', () => {
  const live = [extensionWorkerA, extensionWorkerB, orphanFromIssue98, idlePage];
  const got = contextlessTargets(live);
  assert.strictEqual(got.length, 1);
  assert.strictEqual(got[0].url, orphanFromIssue98.url);
});

check('never closes the browser target itself', () => {
  // The browser target legitimately has no browserContextId; patchright returns
  // before its assert for this type, and closing it would kill the browser.
  assert.deepStrictEqual(contextlessTargets([browserTarget]), []);
});

check('an orphaned page is swept too, not just workers', () => {
  // The assert fires for every non-browser type, so the sweep must match it.
  const orphanPage = { targetId: 'P1', type: 'page', url: 'https://x.test/' };
  assert.strictEqual(contextlessTargets([orphanPage]).length, 1);
});

check('tolerates junk input', () => {
  assert.deepStrictEqual(contextlessTargets(undefined), []);
  assert.deepStrictEqual(contextlessTargets([]), []);
  assert.deepStrictEqual(contextlessTargets([null]), []);
});

check('websocket url keeps the path but uses the port we dialled', () => {
  const got = browserWSURL(
    'ws://localhost:9222/devtools/browser/0eb407ed-3b64-4a55-bf48-95c786293416',
    'http://127.0.0.1:35841'
  );
  assert.strictEqual(got, 'ws://127.0.0.1:35841/devtools/browser/0eb407ed-3b64-4a55-bf48-95c786293416');
});

if (failures) {
  console.error(`${failures} test(s) failed`);
  process.exit(1);
}
console.log('all browser_runner tests passed');
