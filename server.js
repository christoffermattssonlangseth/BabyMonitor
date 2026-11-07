// BabyMonitor server: serves the web app and relays WebRTC signaling between
// one baby station and any number of parent stations. Media flows directly
// peer-to-peer; this server never sees the video or audio.

import { createServer as createHttpsServer } from 'node:https';
import { createServer as createHttpServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { networkInterfaces } from 'node:os';
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(ROOT, 'public');
const CERT_DIR = path.join(ROOT, 'certs');

const PORT = Number(process.env.PORT) || 8443;
const PASSWORD = process.env.MONITOR_PASSWORD || '';
// Set USE_HTTP=1 when running behind a reverse proxy / tunnel that terminates TLS.
const USE_HTTP = process.env.USE_HTTP === '1';
const ICE_SERVERS = parseIceServers(process.env.ICE_SERVERS);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
};

function parseIceServers(raw) {
  if (!raw) return [{ urls: 'stun:stun.l.google.com:19302' }];
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) throw new Error('must be a JSON array');
    return parsed;
  } catch (err) {
    console.error(`Invalid ICE_SERVERS: ${err.message}`);
    process.exit(1);
  }
}

const hash = (s) => createHash('sha256').update(String(s)).digest();
const PASSWORD_HASH = hash(PASSWORD);
function checkPassword(candidate) {
  return typeof candidate === 'string' && timingSafeEqual(hash(candidate), PASSWORD_HASH);
}

// ---------------------------------------------------------------------------
// Static file serving
// ---------------------------------------------------------------------------

async function handleRequest(req, res) {
  const url = new URL(req.url, 'http://localhost');
  let pathname = decodeURIComponent(url.pathname);
  if (pathname.endsWith('/')) pathname += 'index.html';
  const filePath = path.normalize(path.join(PUBLIC_DIR, pathname));
  if (!filePath.startsWith(PUBLIC_DIR + path.sep)) {
    res.writeHead(403).end('Forbidden');
    return;
  }
  try {
    const body = await readFile(filePath);
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream',
      'Cache-Control': 'no-cache',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
    });
    res.end(body);
  } catch {
    res.writeHead(404).end('Not found');
  }
}

// ---------------------------------------------------------------------------
// Signaling
// ---------------------------------------------------------------------------

/** @type {Map<string, {ws: import('ws').WebSocket, role: 'baby'|'parent', name: string}>} */
const clients = new Map();
const failedLogins = new Map(); // ip -> { count, until }

function send(ws, msg) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
}

function findBaby() {
  for (const [id, c] of clients) if (c.role === 'baby') return { id, ...c };
  return null;
}

function parents() {
  return [...clients].filter(([, c]) => c.role === 'parent');
}

function broadcastParents(msg) {
  for (const [, c] of parents()) send(c.ws, msg);
}

function notifyParentCount() {
  const baby = findBaby();
  if (baby) {
    send(baby.ws, {
      type: 'parents',
      parents: parents().map(([id, c]) => ({ id, name: c.name })),
    });
  }
}

function isRateLimited(ip) {
  const entry = failedLogins.get(ip);
  return entry && entry.until > Date.now();
}

function recordFailedLogin(ip) {
  const entry = failedLogins.get(ip) || { count: 0, until: 0 };
  entry.count += 1;
  if (entry.count >= 5) {
    entry.until = Date.now() + 60_000;
    entry.count = 0;
  }
  failedLogins.set(ip, entry);
}

function attachSignaling(server) {
  const wss = new WebSocketServer({ server, path: '/ws', maxPayload: 256 * 1024 });

  wss.on('connection', (ws, req) => {
    const ip = req.socket.remoteAddress;
    let id = null;
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });

    // Must authenticate within 10 seconds.
    const authTimer = setTimeout(() => { if (!id) ws.close(4001, 'auth timeout'); }, 10_000);

    ws.on('message', (raw) => {
      let msg;
      try { msg = JSON.parse(raw); } catch { return; }
      if (!msg || typeof msg !== 'object') return;

      if (!id) {
        if (msg.type !== 'join') return;
        if (isRateLimited(ip)) {
          send(ws, { type: 'error', error: 'Too many wrong passwords. Wait a minute and try again.' });
          ws.close(4003, 'rate limited');
          return;
        }
        if (!checkPassword(msg.password)) {
          recordFailedLogin(ip);
          send(ws, { type: 'error', error: 'Wrong family password.' });
          ws.close(4003, 'bad password');
          return;
        }
        if (msg.role !== 'baby' && msg.role !== 'parent') {
          ws.close(4000, 'bad role');
          return;
        }
        clearTimeout(authTimer);
        failedLogins.delete(ip);
        id = randomUUID();
        const name = String(msg.name || (msg.role === 'baby' ? 'Baby station' : 'Parent')).slice(0, 40);

        if (msg.role === 'baby') {
          // Only one baby station at a time; a new one replaces the old.
          const old = findBaby();
          if (old) {
            send(old.ws, { type: 'error', error: 'Another device became the baby station.' });
            clients.delete(old.id);
            old.ws.close(4004, 'replaced');
          }
          clients.set(id, { ws, role: 'baby', name });
          send(ws, { type: 'welcome', id, iceServers: ICE_SERVERS });
          broadcastParents({ type: 'baby-online', babyId: id });
          notifyParentCount();
        } else {
          clients.set(id, { ws, role: 'parent', name });
          const baby = findBaby();
          send(ws, { type: 'welcome', id, iceServers: ICE_SERVERS, babyId: baby ? baby.id : null });
          notifyParentCount();
        }
        return;
      }

      const me = clients.get(id);
      if (!me) return;

      switch (msg.type) {
        case 'signal': {
          // Only allow baby <-> parent signaling.
          const target = clients.get(msg.to);
          if (!target || target.role === me.role) return;
          send(target.ws, { type: 'signal', from: id, data: msg.data });
          break;
        }
        case 'status': {
          // Sound level / state updates from the baby station.
          if (me.role !== 'baby') return;
          broadcastParents({
            type: 'status',
            level: Number(msg.level) || 0,
            camera: !!msg.camera,
            t: Date.now(),
          });
          break;
        }
        case 'ping':
          send(ws, { type: 'pong' });
          break;
      }
    });

    ws.on('close', () => {
      clearTimeout(authTimer);
      if (!id) return;
      const me = clients.get(id);
      if (!me || me.ws !== ws) return;
      clients.delete(id);
      if (me.role === 'baby') {
        broadcastParents({ type: 'baby-offline' });
      } else {
        const baby = findBaby();
        if (baby) send(baby.ws, { type: 'peer-left', id });
        notifyParentCount();
      }
    });
  });

  // Detect dead connections (phone went to sleep, Wi-Fi dropped, ...).
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.isAlive) { ws.terminate(); continue; }
      ws.isAlive = false;
      ws.ping();
    }
  }, 10_000);
  wss.on('close', () => clearInterval(heartbeat));
  server.on('close', () => {
    for (const ws of wss.clients) ws.terminate();
    wss.close();
  });
  return wss;
}

// ---------------------------------------------------------------------------
// TLS (browsers only allow camera/microphone on HTTPS pages)
// ---------------------------------------------------------------------------

function localAddresses() {
  const out = [];
  for (const list of Object.values(networkInterfaces())) {
    for (const a of list || []) if (!a.internal) out.push(a.address);
  }
  return out;
}

async function loadOrCreateCert() {
  if (process.env.TLS_CERT && process.env.TLS_KEY) {
    return { cert: await readFile(process.env.TLS_CERT), key: await readFile(process.env.TLS_KEY) };
  }
  const certFile = path.join(CERT_DIR, 'cert.pem');
  const keyFile = path.join(CERT_DIR, 'key.pem');
  if (existsSync(certFile) && existsSync(keyFile)) {
    return { cert: await readFile(certFile), key: await readFile(keyFile) };
  }
  const { default: selfsigned } = await import('selfsigned');
  const altNames = [
    { type: 2, value: 'localhost' },
    { type: 7, ip: '127.0.0.1' },
    ...localAddresses().filter((a) => !a.includes(':')).map((ip) => ({ type: 7, ip })),
  ];
  const notAfterDate = new Date();
  notAfterDate.setFullYear(notAfterDate.getFullYear() + 5);
  const pems = await selfsigned.generate([{ name: 'commonName', value: 'BabyMonitor' }], {
    algorithm: 'sha256',
    keySize: 2048,
    notAfterDate,
    extensions: [
      { name: 'basicConstraints', cA: false },
      { name: 'keyUsage', digitalSignature: true, keyEncipherment: true },
      { name: 'extKeyUsage', serverAuth: true },
      { name: 'subjectAltName', altNames },
    ],
  });
  await mkdir(CERT_DIR, { recursive: true });
  await writeFile(certFile, pems.cert);
  await writeFile(keyFile, pems.private, { mode: 0o600 });
  console.log(`Created a self-signed certificate in ${CERT_DIR}`);
  return { cert: pems.cert, key: pems.private };
}

// ---------------------------------------------------------------------------

export async function start({ port = PORT, http = USE_HTTP } = {}) {
  if (!PASSWORD) {
    throw new Error('Set a family password first, e.g.  MONITOR_PASSWORD="something-long" npm start');
  }
  const server = http
    ? createHttpServer(handleRequest)
    : createHttpsServer(await loadOrCreateCert(), handleRequest);
  attachSignaling(server);
  await new Promise((resolve) => server.listen(port, resolve));
  return server;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const server = await start();
    const { port } = server.address();
    const scheme = USE_HTTP ? 'http' : 'https';
    console.log('\nBabyMonitor is running. Open one of these on your phones:');
    for (const host of ['localhost', ...localAddresses().filter((a) => !a.includes(':'))]) {
      console.log(`  ${scheme}://${host}:${port}`);
    }
    if (!USE_HTTP) {
      console.log('\n(The certificate is self-signed: accept the browser warning once per device.)');
    }
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}
