import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import WebSocket from 'ws';

process.env.MONITOR_PASSWORD = 'correct horse';
const { start } = await import('../server.js');

let server;
let url;
before(async () => {
  server = await start({ port: 0, http: true });
  url = `ws://127.0.0.1:${server.address().port}/ws`;
});
after(() => { server.close(); server.closeAllConnections(); });

// Connect a client that records every message it receives.
function client(role, password = 'correct horse') {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const inbox = [];
    const waiters = [];
    ws.on('message', (raw) => {
      const msg = JSON.parse(raw);
      inbox.push(msg);
      for (const w of [...waiters]) if (w.match(msg)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(msg); }
    });
    ws.next = (type) => {
      const i = inbox.findIndex((m) => m.type === type);
      if (i >= 0) return Promise.resolve(inbox.splice(i, 1)[0]);
      return new Promise((res) => waiters.push({ match: (m) => m.type === type && inbox.splice(inbox.indexOf(m), 1), resolve: res }));
    };
    ws.closed = new Promise((res) => ws.on('close', (code) => res(code)));
    ws.on('open', () => { ws.send(JSON.stringify({ type: 'join', role, password })); resolve(ws); });
    ws.on('error', reject);
  });
}

test('rejects a wrong password', async () => {
  const ws = await client('parent', 'nope');
  const err = await ws.next('error');
  assert.match(err.error, /password/i);
  assert.equal(await ws.closed, 4003);
});

test('relays signaling between parent and baby and broadcasts status', async () => {
  const parent = await client('parent');
  const welcome = await parent.next('welcome');
  assert.equal(welcome.babyId, null);
  assert.ok(Array.isArray(welcome.iceServers));

  const baby = await client('baby');
  const babyWelcome = await baby.next('welcome');
  const online = await parent.next('baby-online');
  assert.equal(online.babyId, babyWelcome.id);
  const list = await baby.next('parents');
  assert.equal(list.parents.length, 1);

  parent.send(JSON.stringify({ type: 'signal', to: online.babyId, data: { requestOffer: true } }));
  const req = await baby.next('signal');
  assert.deepEqual(req.data, { requestOffer: true });
  assert.equal(req.from, welcome.id);

  baby.send(JSON.stringify({ type: 'signal', to: req.from, data: { description: { type: 'offer', sdp: 'x' } } }));
  const offer = await parent.next('signal');
  assert.equal(offer.data.description.type, 'offer');

  baby.send(JSON.stringify({ type: 'status', level: 42, camera: true }));
  const status = await parent.next('status');
  assert.equal(status.level, 42);

  // Parents cannot signal other parents or spoof status.
  const parent2 = await client('parent');
  const w2 = await parent2.next('welcome');
  parent.send(JSON.stringify({ type: 'signal', to: w2.id, data: { evil: true } }));
  parent.send(JSON.stringify({ type: 'status', level: 99 }));
  baby.send(JSON.stringify({ type: 'status', level: 7 }));
  assert.equal((await parent2.next('status')).level, 7);

  parent2.close();
  const left = await baby.next('peer-left');
  assert.equal(left.id, w2.id);

  baby.close();
  await parent.next('baby-offline');
  parent.close();
});

test('a new baby station replaces the old one', async () => {
  const first = await client('baby');
  await first.next('welcome');
  const second = await client('baby');
  await second.next('welcome');
  assert.equal(await first.closed, 4004);
  second.close();
});

test('serves the app but not files outside public/', async () => {
  const base = `http://127.0.0.1:${server.address().port}`;
  const res = await fetch(base + '/');
  assert.equal(res.status, 200);
  assert.match(await res.text(), /Baby Monitor/);
  const bad = await fetch(base + '/%2e%2e/server.js');
  assert.notEqual(bad.status, 200);
});
