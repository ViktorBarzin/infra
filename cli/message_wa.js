// homelab message — WhatsApp Web automation (embedded in the Go CLI, run via the
// same chrome-service --shared-context path as `homelab browser run`). Inputs
// arrive via HOMELAB_MSG_* env vars; page/context/browser/log are in scope.
// Actions: send | read | contacts. Selectors verified against WhatsApp Web 2026.
// Design: docs/plans/2026-07-20-homelab-message-personal-messaging-design.md

const ACTION = process.env.HOMELAB_MSG_ACTION || '';
const TO = process.env.HOMELAB_MSG_TO || '';
const TEXT = process.env.HOMELAB_MSG_TEXT || '';
const SEARCH = process.env.HOMELAB_MSG_SEARCH || '';
const LIMIT = parseInt(process.env.HOMELAB_MSG_LIMIT || '20', 10);

const SEL = {
  paneSide: '#pane-side',
  search: '[aria-label="Ask Meta AI or Search"]',
  composer: 'footer div[contenteditable="true"][role="textbox"]',
};

const sleep = (ms) => page.waitForTimeout(ms);
const rnd = (a, b) => a + Math.random() * (b - a);
const cssTitle = (t) => `span[title=${JSON.stringify(t)}]`;

// Human-like typing: per-character non-deterministic delay, longer at word and
// punctuation boundaries, with rare "thinking" pauses. Defends against
// client-side input-cadence fingerprinting (design safety-model §7). Real
// keyboard events are required anyway — the composer is a Lexical editor.
//
// A newline goes in as Shift+Enter: Enter alone sends, so typing a multi-line
// text (a delegation is one) would otherwise post every line as its own message.
async function typeHuman(s) {
  for (const ch of s) {
    if (ch === '\n') await page.keyboard.press('Shift+Enter');
    else await page.keyboard.type(ch);
    let d = rnd(55, 150);
    if (ch === ' ') d += rnd(40, 160);
    else if ('.,!?;:'.includes(ch)) d += rnd(120, 380);
    if (Math.random() < 0.03) d += rnd(300, 850); // occasional pause
    await sleep(Math.round(d));
  }
}

async function ensureLoggedIn() {
  await page.goto('https://web.whatsapp.com/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  try {
    await page.locator(SEL.paneSide).first().waitFor({ state: 'visible', timeout: 60000 });
  } catch (e) {
    throw new Error('WhatsApp Web is not logged in (no chat list appeared). Log in via noVNC at chrome.viktorbarzin.me, then retry.');
  }
  await sleep(1200);
}

// openExact opens the chat whose row title is `title`, ignoring case, and
// returns the title as WhatsApp shows it. A chat with no row in the list is
// looked up through search; a miss lists what search did find.
async function openExact(title) {
  const sel = (scope) => `${scope}div[role="row"]:has(span[title=${JSON.stringify(title)} i])`;
  let row = page.locator(sel(`${SEL.paneSide} `)).first();
  if (await row.count() === 0) {
    await page.locator(SEL.search).first().click();
    await sleep(400);
    await page.keyboard.type(title);
    await sleep(1800);
    row = page.locator(sel('')).first();
  }
  if (await row.count() === 0) {
    const seen = await page.evaluate(() => [...new Set([...document.querySelectorAll('div[role="row"]')]
      .map((r) => r.querySelector('span[title]')?.getAttribute('title')).filter(Boolean))].slice(0, 8));
    throw new Error('contact not found in WhatsApp: ' + title + (seen.length ? ` (search found: ${seen.join(', ')})` : ''));
  }
  const titles = await row.locator('span[title]').evaluateAll((els) => els.map((e) => e.getAttribute('title')));
  const opened = titles.find((t) => t.toLowerCase() === title.toLowerCase()) || title;
  await row.click();
  await sleep(2500);
  return opened;
}

// openFuzzy opens the best matching chat for a free-text query (read path) and
// returns the actual opened title.
async function openFuzzy(q) {
  let row = page.locator(`${SEL.paneSide} div[role="row"]:has(${cssTitle(q)})`).first();
  if (await row.count() === 0) {
    await page.locator(SEL.search).first().click();
    await sleep(400);
    await page.keyboard.type(q);
    await sleep(1800);
    row = page.locator('div[role="row"]:has(span[title])').first();
  }
  if (await row.count() === 0) throw new Error('no chat found for: ' + q);
  const opened = await row.locator('span[title]').first().getAttribute('title');
  await row.click();
  await sleep(2500);
  return opened;
}

// verifyRecipient guards against a wrong-recipient send: the open chat must match
// `title` via the composer's own aria-label ("Type a message to <name>") or, as a
// fallback, the conversation header text.
async function verifyRecipient(title) {
  const composer = page.locator(SEL.composer).first();
  await composer.waitFor({ state: 'visible', timeout: 15000 });
  const aria = (await composer.getAttribute('aria-label')) || '';
  if (aria.includes(title)) return composer;
  const header = await page.locator('header').first().innerText().catch(() => '');
  if (header.includes(title)) return composer;
  throw new Error(`recipient verification FAILED — opened chat is not ${JSON.stringify(title)} (composer aria=${JSON.stringify(aria)}). Not sending.`);
}

// The thread's message rows, by data-id, newest last.
const rowIds = () => page.evaluate(() => [...document.querySelectorAll('#main div[data-id]')].map((e) => e.getAttribute('data-id')));

// waitSent holds the tab open until WhatsApp marks every new outgoing row Sent,
// Delivered or Read. Closing the tab sooner (the runner does, as soon as this
// script returns) leaves the message stuck with a red "Something went wrong"
// badge, which is how sends were failing while the audit log said "sent".
async function waitSent(before) {
  const deadline = Date.now() + 90000;
  let state = 'no new message row appeared';
  while (Date.now() < deadline) {
    state = await page.evaluate((before) => {
      const seen = new Set(before);
      const labels = [...document.querySelectorAll('#main div[data-id]')]
        .filter((e) => !seen.has(e.getAttribute('data-id')))
        .map((e) => [...e.querySelectorAll('[aria-label]')].map((l) => l.getAttribute('aria-label').trim()))
        .filter((ls) => ls.includes('You:')); // outgoing only; a reply arriving meanwhile has no status
      if (labels.length === 0) return 'no new message row appeared';
      if (labels.some((ls) => ls.some((l) => l.startsWith('Something went wrong')))) return 'failed';
      if (labels.every((ls) => ls.some((l) => ['Sent', 'Delivered', 'Read'].includes(l)))) return 'ok';
      return 'still pending';
    }, before);
    if (state === 'ok' || state === 'failed') break;
    await sleep(1000);
  }
  if (state !== 'ok') {
    const why = state === 'failed' ? 'it shows "Something went wrong" in the chat' : state + ' after 90s';
    throw new Error(`WhatsApp did not send the message to ${JSON.stringify(TO)} (${why})`);
  }
}

async function doSend() {
  if (!TO) throw new Error('HOMELAB_MSG_TO empty');
  if (!TEXT) throw new Error('HOMELAB_MSG_TEXT empty');
  const title = await openExact(TO);
  const composer = await verifyRecipient(title);
  const before = await rowIds();
  await composer.click();
  await sleep(rnd(300, 800)); // pre-type pause
  await typeHuman(TEXT);
  await sleep(rnd(350, 1000)); // pre-send pause
  await page.keyboard.press('Enter');
  // Success signal: the composer clears once the message is committed.
  await page.waitForFunction(() => {
    const c = document.querySelector('footer div[contenteditable="true"][role="textbox"]');
    return c && (c.innerText || '').replace(/​/g, '').trim() === '';
  }, null, { timeout: 12000 });
  await waitSent(before);
  log(`sent to ${title} (${[...TEXT].length} chars)`);
  return { sent: true, to: title, chars: [...TEXT].length };
}

async function doRead() {
  if (!TO) throw new Error('read requires --to');
  const opened = await openFuzzy(TO);
  // WhatsApp Web (2026) exposes no direction on the message DOM — the old
  // .message-in/.message-out classes, the tick-icon (data-icon="msg-*"), and the
  // span.copyable-text[data-pre-plain-text] sender are ALL gone. The robust,
  // build-independent signal is geometry: outgoing bubbles are right-aligned in
  // the conversation column (#main), incoming left. Classify by the bubble's
  // centre-x vs the column midpoint.
  const msgs = await page.evaluate((limit) => {
    const clean = (s) => (s || '').replace(/\s+/g, ' ').trim();
    const anchor = document.querySelector('#main') || document.querySelector('div[role="application"]') || document.body;
    const p = anchor.getBoundingClientRect();
    const mid = p.left + p.width / 2;
    const els = [...anchor.querySelectorAll('div[data-id]')].filter((e) => e.querySelector('span.copyable-text'));
    return els.slice(-limit).map((e) => {
      const cp = e.querySelector('span.copyable-text');
      const r = cp.getBoundingClientRect();
      const dir = r.left + r.width / 2 > mid ? 'out' : 'in';
      const inner = cp.querySelector('span.selectable-text, span._ao3e') || cp;
      return { dir, text: clean(inner.innerText).slice(0, 1500) };
    }).filter((m) => m.text);
  }, LIMIT);
  console.log(`--- ${opened} (last ${msgs.length}) ---`);
  for (const m of msgs) console.log((m.dir === 'out' ? '→ ' : '← ') + m.text);
  return { read: msgs.length, opened };
}

async function doContacts() {
  if (SEARCH) {
    await page.locator(SEL.search).first().click();
    await sleep(400);
    await page.keyboard.type(SEARCH);
    await sleep(1600);
  }
  // Take the FIRST span[title] per row = the chat name. (A row's later
  // span[title] is the last-message preview — must not be listed as a contact.)
  const rowSel = SEARCH ? 'div[role="row"]' : `${SEL.paneSide} div[role="row"]`;
  const titles = await page.evaluate((sel) => {
    const names = [...document.querySelectorAll(sel)]
      .map((r) => { const s = r.querySelector('span[title]'); return s ? s.getAttribute('title') : null; })
      .filter(Boolean);
    return [...new Set(names)];
  }, rowSel);
  for (const t of titles) console.log(t);
  return { contacts: titles.length };
}

await ensureLoggedIn();
if (ACTION === 'send') return await doSend();
if (ACTION === 'read') return await doRead();
if (ACTION === 'contacts') return await doContacts();
throw new Error('unknown HOMELAB_MSG_ACTION: ' + ACTION);
