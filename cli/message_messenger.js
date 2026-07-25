// homelab message — Facebook Messenger (messenger.com) automation, run via the
// shared chrome-service --shared-context session. Inputs via HOMELAB_MSG_* env;
// page/context/browser/log in scope. Actions: send | read | contacts.
// Selectors verified against messenger.com 2026. Sibling of message_wa.js.

const ACTION = process.env.HOMELAB_MSG_ACTION || '';
const TO = process.env.HOMELAB_MSG_TO || '';
const TEXT = process.env.HOMELAB_MSG_TEXT || '';
const SEARCH = process.env.HOMELAB_MSG_SEARCH || '';
const LIMIT = parseInt(process.env.HOMELAB_MSG_LIMIT || '20', 10);

const SEL = {
  search: '[aria-label="Search Messenger"]',
  threadLink: 'a[href*="/t/"]',
  composer: 'div[contenteditable="true"][role="textbox"][aria-label^="Write to"]',
  main: '[role="main"]',
};
// Conversation-list links that are NOT people/groups.
const NAV = new Set(['Chats', 'Marketplace', 'Requests', 'Archive', 'Message requests']);

const sleep = (ms) => page.waitForTimeout(ms);
const rnd = (a, b) => a + Math.random() * (b - a);

async function typeHuman(s) {
  for (const ch of s) {
    await page.keyboard.type(ch);
    let d = rnd(55, 150);
    if (ch === ' ') d += rnd(40, 160);
    else if ('.,!?;:'.includes(ch)) d += rnd(120, 380);
    if (Math.random() < 0.03) d += rnd(300, 850);
    await sleep(Math.round(d));
  }
}

async function ensureLoggedIn() {
  await page.goto('https://www.messenger.com/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  try {
    await page.locator(SEL.search).first().waitFor({ state: 'visible', timeout: 60000 });
  } catch (e) {
    throw new Error('messenger.com is not logged in (no search box appeared). Log in via noVNC at chrome.viktorbarzin.me, then retry.');
  }
  await sleep(1500);
}

// open the conversation for `title` (send: exact; read: fuzzy). Returns nothing.
async function openConversation(title) {
  let link = page.locator(SEL.threadLink).filter({ hasText: title }).first();
  if (await link.count() === 0) {
    await page.locator(SEL.search).first().click();
    await sleep(500);
    await page.keyboard.type(title);
    await sleep(2200);
    link = page.locator(SEL.threadLink).filter({ hasText: title }).first();
  }
  if (await link.count() === 0) throw new Error('Messenger conversation not found: ' + title);
  await link.click();
  await sleep(2800);
}

// verify the open thread matches `title` via the composer's "Write to <name>" aria.
async function verifiedComposer(title) {
  const composer = page.locator(SEL.composer).first();
  await composer.waitFor({ state: 'visible', timeout: 15000 });
  const aria = (await composer.getAttribute('aria-label')) || '';
  if (aria.includes(title)) return composer;
  const header = await page.locator(`${SEL.main} h1, ${SEL.main} [role="heading"]`).first().innerText().catch(() => '');
  if (header.includes(title)) return composer;
  throw new Error(`recipient verification FAILED — open thread is not ${JSON.stringify(title)} (composer aria=${JSON.stringify(aria)}). Not sending.`);
}

async function doSend() {
  if (!TO) throw new Error('HOMELAB_MSG_TO empty');
  if (!TEXT) throw new Error('HOMELAB_MSG_TEXT empty');
  await openConversation(TO);
  const composer = await verifiedComposer(TO);
  await composer.click();
  await sleep(rnd(300, 800));
  await typeHuman(TEXT);
  await sleep(rnd(350, 1000));
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => {
    const c = document.querySelector('div[contenteditable="true"][role="textbox"][aria-label^="Write to"]');
    return c && (c.innerText || '').replace(/​/g, '').trim() === '';
  }, null, { timeout: 12000 });
  log(`sent to ${TO} (${[...TEXT].length} chars)`);
  return { sent: true, to: TO, chars: [...TEXT].length };
}

async function doRead() {
  if (!TO) throw new Error('read requires --to');
  await openConversation(TO);
  const msgs = await page.evaluate((limit) => {
    const clean = (s) => (s || '').replace(/\s+/g, ' ').trim();
    const main = document.querySelector('[role="main"]') || document.body;
    const els = [...main.querySelectorAll('[aria-label*="Message sent"], [aria-label*="You sent"]')];
    return els.slice(-limit).map((e) => {
      const al = e.getAttribute('aria-label') || '';
      const out = /You sent/.test(al);
      const m = al.match(/(?:You sent|by .+?):\s*([\s\S]*)$/);
      let text = m ? m[1] : '';
      if (!text) text = clean(e.innerText).replace(/^Enter,?\s*/, '');
      return { dir: out ? 'out' : 'in', text: clean(text).slice(0, 1500) };
    }).filter((x) => x.text && !/^Message (sent|actions)/.test(x.text));
  }, LIMIT);
  console.log(`--- ${TO} (last ${msgs.length}) ---`);
  for (const m of msgs) console.log((m.dir === 'out' ? '→ ' : '← ') + m.text);
  return { read: msgs.length };
}

async function doContacts() {
  if (SEARCH) {
    await page.locator(SEL.search).first().click();
    await sleep(500);
    await page.keyboard.type(SEARCH);
    await sleep(2000);
  }
  const names = await page.evaluate(() => {
    const out = [];
    for (const a of document.querySelectorAll('a[href*="/t/"]')) {
      const label = (a.getAttribute('aria-label') || (a.querySelector('span[dir="auto"]') || {}).innerText || '').replace(/\s+/g, ' ').trim();
      const name = label.split('\n')[0].trim();
      if (name && name.length < 60 && !out.includes(name)) out.push(name);
    }
    return out;
  });
  const NAV = new Set(['Chats', 'Marketplace', 'Requests', 'Archive', 'Message requests']);
  for (const n of names.filter((x) => !NAV.has(x))) console.log(n);
  return { contacts: names.length };
}

await ensureLoggedIn();
if (ACTION === 'send') return await doSend();
if (ACTION === 'read') return await doRead();
if (ACTION === 'contacts') return await doContacts();
throw new Error('unknown HOMELAB_MSG_ACTION: ' + ACTION);
