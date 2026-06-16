// t3-afk auto-pair dispatcher
// ----------------------------------------------------------------------------
// Replicates the devvm t3-dispatch experience for the single in-cluster T3
// instance. The ingress is Authentik-gated (auth=required), so every request
// that reaches here is already authenticated. On a cookieless *document*
// navigation we mint a one-time pairing credential (`t3 auth pairing create`)
// and exchange it at the t3 server's /api/auth/browser-session endpoint for the
// `t3_session` cookie, then 302 back — so the user never sees the manual
// /pair#token screen. Everything else (incl. WebSocket upgrades for the cockpit
// live stream + terminals) is reverse-proxied straight through to t3 serve.
//
// Single upstream, same pod (localhost) — kept dependency-free (Node stdlib).
'use strict';
const http = require('http');
const net = require('net');
const { execFile } = require('child_process');

const UPSTREAM_HOST = '127.0.0.1';
const UPSTREAM_PORT = Number(process.env.T3_UPSTREAM_PORT || 3773);
const LISTEN_PORT = Number(process.env.DISPATCHER_PORT || 8080);
const T3_BIN = process.env.T3_BIN || '/data/npm-global/bin/t3';
const BASE_DIR = process.env.T3CODE_HOME || '/data/t3';
const COOKIE = 't3_session';
const childEnv = { ...process.env, PATH: '/data/npm-global/bin:' + (process.env.PATH || ''), HOME: '/home/node' };

const hasSession = (req) =>
  (req.headers.cookie || '').split(/;\s*/).some((c) => c.startsWith(COOKIE + '='));

const isDocNav = (req) => {
  if (req.method !== 'GET') return false;
  const dest = req.headers['sec-fetch-dest'];
  if (dest) return dest === 'document';
  return (req.headers['accept'] || '').includes('text/html');
};

const mintCredential = () =>
  new Promise((resolve, reject) => {
    execFile(
      T3_BIN,
      ['auth', 'pairing', 'create', '--base-dir', BASE_DIR, '--ttl', '5m', '--json'],
      { env: childEnv, timeout: 15000 },
      (err, stdout) => {
        if (err) return reject(err);
        try {
          const cred = JSON.parse(stdout).credential;
          cred ? resolve(cred) : reject(new Error('no credential in pairing output'));
        } catch (e) {
          reject(e);
        }
      },
    );
  });

const exchange = (credential) =>
  new Promise((resolve, reject) => {
    const body = JSON.stringify({ credential });
    const r = http.request(
      {
        host: UPSTREAM_HOST,
        port: UPSTREAM_PORT,
        path: '/api/auth/browser-session',
        method: 'POST',
        headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) },
      },
      (resp) => {
        const setCookie = resp.headers['set-cookie'] || [];
        resp.resume();
        resp.on('end', () =>
          resp.statusCode === 200 && setCookie.length
            ? resolve(setCookie)
            : reject(new Error('browser-session exchange returned ' + resp.statusCode)),
        );
      },
    );
    r.on('error', reject);
    r.write(body);
    r.end();
  });

const proxyHttp = (req, res) => {
  const up = http.request(
    { host: UPSTREAM_HOST, port: UPSTREAM_PORT, path: req.url, method: req.method, headers: req.headers },
    (r) => {
      res.writeHead(r.statusCode, r.headers);
      r.pipe(res);
    },
  );
  up.on('error', () => {
    if (!res.headersSent) res.writeHead(502);
    res.end('bad gateway');
  });
  req.pipe(up);
};

const server = http.createServer(async (req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200);
    return res.end('ok');
  }
  if (!hasSession(req) && isDocNav(req)) {
    try {
      const cred = await mintCredential();
      const setCookie = await exchange(cred);
      res.writeHead(302, { location: req.url || '/', 'set-cookie': setCookie, 'cache-control': 'no-store' });
      return res.end();
    } catch (err) {
      // Fall through to a plain proxy; the cockpit's own /pair screen is the
      // fallback if auto-pair ever fails, so we never hard-fail the request.
      console.error('auto-pair failed, proxying through:', err.message);
    }
  }
  proxyHttp(req, res);
});

// WebSocket / Upgrade passthrough — the cockpit's live orchestration stream and
// terminals need this. Reconstruct the upgrade request and splice the sockets.
server.on('upgrade', (req, socket, head) => {
  const up = net.connect(UPSTREAM_PORT, UPSTREAM_HOST, () => {
    up.write(
      `${req.method} ${req.url} HTTP/1.1\r\n` +
        Object.entries(req.headers)
          .map(([k, v]) => `${k}: ${v}`)
          .join('\r\n') +
        '\r\n\r\n',
    );
    if (head && head.length) up.write(head);
    socket.pipe(up);
    up.pipe(socket);
  });
  up.on('error', () => socket.destroy());
  socket.on('error', () => up.destroy());
});

server.listen(LISTEN_PORT, '0.0.0.0', () =>
  console.log(`t3-afk dispatcher listening on :${LISTEN_PORT} -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}`),
);
