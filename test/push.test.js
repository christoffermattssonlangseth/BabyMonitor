import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { PushAlerts, LOST_AFTER_MS } from '../push.js';

const sub = (n) => ({ endpoint: `https://push.example/${n}`, keys: { p256dh: 'p', auth: 'a' } });

async function setup() {
  const dir = await mkdtemp(path.join(tmpdir(), 'bm-'));
  const sent = [];
  const push = await new PushAlerts({
    dataDir: dir,
    subject: 'https://example.com',
    send: async (s, payload, opts) => { sent.push({ endpoint: s.endpoint, ...JSON.parse(payload), urgency: opts.urgency }); },
  }).init();
  return { push, sent, cleanup: async () => { await push.saving; await rm(dir, { recursive: true, force: true }); } };
}

test('sends a noise alert only after the sound lasts long enough, then cools down', async () => {
  const { push, sent, cleanup } = await setup();
  push.upsert(sub(1), { threshold: 40, sustain: 2 });
  const none = () => false;
  push.onLevel(80, none, 0);
  push.onLevel(80, none, 1000);
  assert.equal(sent.length, 0);
  push.onLevel(80, none, 2000);
  await Promise.resolve();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].tag, 'noise');
  assert.equal(sent[0].urgency, 'high');
  push.onLevel(80, none, 10_000);
  assert.equal(sent.length, 1, 'cooldown');
  // A dip resets the timer.
  push.onLevel(80, none, 61_000);
  push.onLevel(10, none, 62_000);
  push.onLevel(80, none, 63_000);
  push.onLevel(80, none, 64_000);
  assert.equal(sent.length, 1);
  await cleanup();
});

test('respects per-parent thresholds and skips parents watching on screen', async () => {
  const { push, sent, cleanup } = await setup();
  push.upsert(sub(1), { threshold: 30, sustain: 0 });
  push.upsert(sub(2), { threshold: 90, sustain: 0 });
  push.upsert(sub(3), { threshold: 30, sustain: 0 });
  push.onLevel(50, (e) => e.endsWith('/3'), 0);
  await Promise.resolve();
  assert.deepEqual(sent.map((s) => s.endpoint), ['https://push.example/1']);
  await cleanup();
});

test('raises lost contact once per outage and reports recovery', async () => {
  const { push, sent, cleanup } = await setup();
  push.upsert(sub(1));
  const none = () => false;
  push.checkContact(none, 100_000);
  assert.equal(sent.length, 0, 'no alarm before the baby station was ever seen');
  push.onLevel(0, none, 0);
  push.checkContact(none, LOST_AFTER_MS - 1);
  assert.equal(sent.length, 0);
  push.checkContact(none, LOST_AFTER_MS + 1);
  push.checkContact(none, LOST_AFTER_MS + 5000);
  await Promise.resolve();
  assert.equal(sent.length, 1);
  assert.match(sent[0].title, /Lost contact/);
  push.onLevel(0, none, LOST_AFTER_MS + 6000);
  await Promise.resolve();
  assert.equal(sent.length, 2);
  assert.match(sent[1].title, /back/);
  await cleanup();
});

test('drops expired subscriptions and persists the rest', async () => {
  const { push, cleanup } = await setup();
  push.sendImpl = async () => { throw Object.assign(new Error('gone'), { statusCode: 410 }); };
  push.upsert(sub(1));
  push.upsert(sub(2));
  assert.equal(push.upsert({ endpoint: 'http://insecure', keys: { p256dh: 'p', auth: 'a' } }), false);
  await push.sendTo('https://push.example/1', { title: 'x' });
  assert.deepEqual([...push.subs.keys()], ['https://push.example/2']);
  await push.save();
  const again = await new PushAlerts({ dataDir: push.dataDir, subject: 'x' }).init();
  assert.deepEqual([...again.subs.keys()], ['https://push.example/2']);
  assert.equal(again.publicKey, push.publicKey, 'VAPID keys are kept');
  await cleanup();
});
