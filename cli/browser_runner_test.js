// Unit tests for the browser_runner pre-connect target sweep.
// Run directly (`node cli/browser_runner_test.js`) or via TestBrowserRunnerJS.
'use strict';
const assert = require('assert');
const {
  contextlessTargets,
  browserWSURL,
  exitCleanup,
  isTurnstileFrameURL,
  solveTurnstileFrame,
  watchTurnstile,
} = require('./browser_runner.js');

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

// What the runner closes on exit. It opens a page of its own before every
// script, and a --shared-context script often drives an existing tab instead.
// On 2026-10-31 twenty-one such runs with --keep-open each left that unused
// page behind as a blank tab in the master browser.
check('keep-open on the shared profile still closes the runner page it never used', () => {
  assert.strictEqual(exitCleanup({ createdContext: false, keepOpen: true, pageURL: 'about:blank' }), 'page');
});

check('keep-open leaves the runner page open once the script navigated it', () => {
  assert.strictEqual(exitCleanup({ createdContext: false, keepOpen: true, pageURL: 'https://x.test/' }), 'none');
});

check('without keep-open the shared profile loses only the runner page', () => {
  assert.strictEqual(exitCleanup({ createdContext: false, keepOpen: false, pageURL: 'https://x.test/' }), 'page');
});

check('a context the runner created is closed whole', () => {
  assert.strictEqual(exitCleanup({ createdContext: true, keepOpen: false, pageURL: 'https://x.test/' }), 'context');
});

check('keep-open on a created context closes only an unused runner page', () => {
  assert.strictEqual(exitCleanup({ createdContext: true, keepOpen: true, pageURL: 'about:blank' }), 'page');
  assert.strictEqual(exitCleanup({ createdContext: true, keepOpen: true, pageURL: 'https://x.test/' }), 'none');
});

// Cloudflare Turnstile checkbox. Measured 2026-11-15 on a pool worker against
// turnstile-lab.viktorbarzin.me: a CDP mouse click on the checkbox fails with
// error 600010, while focusing it and pressing Space passed 4 of 4 runs.
check('recognises the Turnstile challenge frame and nothing else', () => {
  assert.strictEqual(isTurnstileFrameURL('https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/b/turnstile/if/ov2/av0/rcv/abc/0x4AAA/auto/fbE/new/normal/auto/'), true);
  assert.strictEqual(isTurnstileFrameURL('https://challenges.cloudflare.com.evil.test/x'), false);
  assert.strictEqual(isTurnstileFrameURL('https://example.com/?u=https://challenges.cloudflare.com/'), false);
  assert.strictEqual(isTurnstileFrameURL('about:blank'), false);
  assert.strictEqual(isTurnstileFrameURL(undefined), false);
});

// A fake challenge frame. `appearsAfter` polls until the checkbox shows;
// pressing Space hides it when `passes` is true, as Turnstile's "Success!" does.
function fakeChallenge({ appearsAfter = 0, passes = true, token = '', neverShows = false } = {}) {
  const calls = [];
  let polls = 0;
  let pressed = false;
  const frame = {
    url: () => 'https://challenges.cloudflare.com/cdn-cgi/challenge-platform/turnstile/if/x',
    isDetached: () => false,
    locator: (sel) => {
      assert.strictEqual(sel, 'input[type="checkbox"]');
      return {
        isVisible: async () => {
          polls++;
          if (neverShows) return false;
          if (pressed && passes) return false;
          return polls > appearsAfter;
        },
        focus: async () => calls.push('focus'),
      };
    },
  };
  const page = {
    keyboard: {
      press: async (k) => {
        calls.push('press:' + k);
        pressed = true;
      },
    },
    waitForTimeout: async () => {},
    locator: (sel) => {
      assert.strictEqual(sel, 'input[name="cf-turnstile-response"]');
      return {
        all: async () => {
          const t = token || (pressed && passes ? '0.solved' : '');
          return t ? [{ inputValue: async () => t }] : [];
        },
      };
    },
  };
  frame.page = () => page;
  return { frame, page, calls };
}

const quick = { pollMS: 0, timeoutMS: 50, settleMS: 0, frameWaitMS: 0 };

async function checkAsync(name, fn) {
  try {
    await fn();
    console.log('ok   ' + name);
  } catch (e) {
    failures++;
    console.log('FAIL ' + name + ': ' + e.message);
  }
}

(async () => {
  await checkAsync('waits for the checkbox, focuses it, presses Space once', async () => {
    const c = fakeChallenge({ appearsAfter: 3 });
    const got = await solveTurnstileFrame(c.page, c.frame, quick);
    assert.strictEqual(got, 'solved');
    assert.deepStrictEqual(c.calls, ['focus', 'press:Space']);
  });

  await checkAsync('reports unsolved when the checkbox stays after Space', async () => {
    const c = fakeChallenge({ passes: false });
    const got = await solveTurnstileFrame(c.page, c.frame, quick);
    assert.strictEqual(got, 'unsolved');
    assert.deepStrictEqual(c.calls, ['focus', 'press:Space']);
  });

  await checkAsync('an invisible pass (token set, no checkbox) needs no key press', async () => {
    const c = fakeChallenge({ neverShows: true, token: '0.abc' });
    const got = await solveTurnstileFrame(c.page, c.frame, quick);
    assert.strictEqual(got, 'passed');
    assert.deepStrictEqual(c.calls, []);
  });

  await checkAsync('a frame that detaches (interstitial reloaded) counts as solved', async () => {
    const c = fakeChallenge({ neverShows: true });
    let n = 0;
    c.frame.isDetached = () => ++n > 2;
    assert.strictEqual(await solveTurnstileFrame(c.page, c.frame, quick), 'solved');
  });

  await checkAsync('gives up quietly when no checkbox ever shows', async () => {
    const c = fakeChallenge({ neverShows: true });
    assert.strictEqual(await solveTurnstileFrame(c.page, c.frame, quick), 'no-checkbox');
    assert.deepStrictEqual(c.calls, []);
  });

  await checkAsync('the watcher solves each challenge frame once and ignores other frames', async () => {
    const c = fakeChallenge();
    const handlers = {};
    c.page.on = (ev, fn) => (handlers[ev] = fn);
    c.page.frames = () => [];
    const context = { on: () => {}, pages: () => [c.page] };
    const solver = watchTurnstile(context, () => {}, quick);
    handlers.framenavigated({ url: () => 'https://example.com/', page: () => c.page });
    handlers.framenavigated(c.frame);
    handlers.framenavigated(c.frame);
    assert.strictEqual(await solver.settle(c.page), 'solved');
    assert.deepStrictEqual(c.calls, ['focus', 'press:Space']);
  });

  // Hit live 2026-11-15: three visits in one run, and visits 2 and 3 got
  // visit 1's 'solved' before their own checkbox had loaded.
  await checkAsync('a new page load forgets the last result', async () => {
    const c = fakeChallenge();
    const handlers = {};
    const main = { url: () => 'https://example.com/', page: () => c.page };
    c.page.on = (ev, fn) => (handlers[ev] = fn);
    c.page.frames = () => [];
    c.page.mainFrame = () => main;
    const solver = watchTurnstile({ on: () => {}, pages: () => [c.page] }, () => {}, quick);
    handlers.framenavigated(c.frame);
    assert.strictEqual(await solver.settle(c.page), 'solved');
    handlers.framenavigated(main);
    assert.strictEqual(await solver.settle(c.page), 'no-challenge');
  });

  await checkAsync('settle on a page with no challenge returns at once', async () => {
    const c = fakeChallenge();
    c.page.on = () => {};
    c.page.frames = () => [];
    const solver = watchTurnstile({ on: () => {}, pages: () => [c.page] }, () => {}, quick);
    assert.strictEqual(await solver.settle(c.page), 'no-challenge');
  });

  if (failures) {
    console.error(`${failures} test(s) failed`);
    process.exit(1);
  }
  console.log('all browser_runner tests passed');
})();
