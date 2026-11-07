// Server-side alerts delivered as Web Push notifications.
//
// iPhones pause web pages as soon as the screen locks, so a parent station
// can't raise its own alarms then. Instead the server watches the baby
// station's sound level and heartbeat, and sends push notifications that
// reach a locked phone (iOS 16.4+, app added to the Home Screen).

import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import path from 'node:path';
import * as webpush from 'web-push';

const NOISE_COOLDOWN_MS = 60_000;
export const LOST_AFTER_MS = 15_000;

export class PushAlerts {
  /**
   * @param {object} opts
   * @param {string} opts.dataDir   where keys and subscriptions are stored
   * @param {string} opts.subject   VAPID contact (mailto: or https: URL)
   * @param {(sub: object, payload: string, options: object) => Promise<unknown>} [opts.send]
   */
  constructor({ dataDir, subject, send = webpush.sendNotification }) {
    this.dataDir = dataDir;
    this.subject = subject;
    this.sendImpl = send;
    /** @type {Map<string, {subscription: object, threshold: number, sustain: number, name: string, aboveSince: number|null, lastNoise: number}>} */
    this.subs = new Map();
    this.lastStatusAt = null; // null until the baby station first reports in
    this.lost = false;
  }

  get file() { return path.join(this.dataDir, 'subscriptions.json'); }

  async init() {
    await mkdir(this.dataDir, { recursive: true });
    const keyFile = path.join(this.dataDir, 'vapid.json');
    try {
      this.vapid = JSON.parse(await readFile(keyFile, 'utf8'));
    } catch {
      this.vapid = webpush.generateVAPIDKeys();
      await writeFile(keyFile, JSON.stringify(this.vapid, null, 2), { mode: 0o600 });
    }
    try {
      for (const s of JSON.parse(await readFile(this.file, 'utf8'))) {
        this.subs.set(s.subscription.endpoint, { ...s, aboveSince: null, lastNoise: -Infinity });
      }
    } catch { /* none yet */ }
    return this;
  }

  get publicKey() { return this.vapid.publicKey; }

  /** Write subscriptions to disk; saves run one at a time, each with the latest state. */
  save() {
    this.saving = (this.saving || Promise.resolve()).catch(() => {}).then(async () => {
      const list = [...this.subs.values()].map(({ subscription, threshold, sustain, name }) => ({ subscription, threshold, sustain, name }));
      const tmp = this.file + '.tmp';
      await writeFile(tmp, JSON.stringify(list, null, 2), { mode: 0o600 });
      await rename(tmp, this.file);
    });
    return this.saving;
  }

  /** Add or update a parent's subscription and alert settings. */
  upsert(subscription, settings = {}) {
    if (!subscription || typeof subscription.endpoint !== 'string' || !/^https:\/\//.test(subscription.endpoint)) return false;
    if (!subscription.keys?.p256dh || !subscription.keys?.auth) return false;
    const prev = this.subs.get(subscription.endpoint);
    this.subs.set(subscription.endpoint, {
      subscription: { endpoint: subscription.endpoint, keys: { p256dh: String(subscription.keys.p256dh), auth: String(subscription.keys.auth) } },
      threshold: clamp(Number(settings.threshold ?? prev?.threshold ?? 35), 1, 100),
      sustain: clamp(Number(settings.sustain ?? prev?.sustain ?? 2), 0, 60),
      name: String(settings.name ?? prev?.name ?? 'Parent').slice(0, 40),
      aboveSince: null,
      lastNoise: prev?.lastNoise ?? -Infinity,
    });
    this.save().catch((e) => console.error('Saving subscriptions failed:', e.message));
    return true;
  }

  remove(endpoint) {
    if (this.subs.delete(endpoint)) this.save().catch(() => {});
  }

  /**
   * Feed a sound level (0–100) from the baby station.
   * @param {(endpoint: string) => boolean} isWatching true if that parent has the app open on screen
   */
  onLevel(level, isWatching, now = Date.now()) {
    this.lastStatusAt = now;
    if (this.lost) {
      this.lost = false;
      this.broadcast({ title: '✅ Baby station is back', body: 'Contact restored.', tag: 'contact' }, isWatching, { urgency: 'normal', TTL: 300 });
    }
    for (const [endpoint, s] of this.subs) {
      if (level >= s.threshold) {
        s.aboveSince ??= now;
        if (now - s.aboveSince >= s.sustain * 1000 && now - s.lastNoise > NOISE_COOLDOWN_MS) {
          s.lastNoise = now;
          if (!isWatching(endpoint)) {
            this.sendTo(endpoint, { title: '🔊 Sound in the nursery', body: `Noise for ${s.sustain}+ seconds. Tap to listen.`, tag: 'noise' }, { urgency: 'high', TTL: 120 });
          }
        }
      } else {
        s.aboveSince = null;
      }
    }
  }

  /** Call periodically; raises the lost-contact alarm once per outage. */
  checkContact(isWatching, now = Date.now()) {
    if (this.lastStatusAt === null || this.lost) return;
    if (now - this.lastStatusAt > LOST_AFTER_MS) {
      this.lost = true;
      this.broadcast({ title: '⚠️ Lost contact with the baby station', body: 'Check the nursery device: battery, Wi-Fi or app closed.', tag: 'contact' }, isWatching, { urgency: 'high', TTL: 600 });
    }
  }

  broadcast(payload, isWatching, options) {
    for (const endpoint of this.subs.keys()) if (!isWatching(endpoint)) this.sendTo(endpoint, payload, options);
  }

  async sendTo(endpoint, payload, options = {}) {
    const s = this.subs.get(endpoint);
    if (!s) return;
    try {
      await this.sendImpl(s.subscription, JSON.stringify({ ...payload, t: Date.now() }), {
        ...options,
        vapidDetails: { subject: this.subject, publicKey: this.vapid.publicKey, privateKey: this.vapid.privateKey },
      });
    } catch (err) {
      // 404/410: the subscription is gone (app removed, permission revoked).
      if (err.statusCode === 404 || err.statusCode === 410) this.remove(endpoint);
      else console.error(`Push to ${s.name} failed: ${err.statusCode || ''} ${err.body || err.message}`);
    }
  }

  /** Send a test notification so parents can confirm alerts reach their phone. */
  test(endpoint) {
    return this.sendTo(endpoint, { title: '👶 Baby Monitor', body: 'Lock-screen alerts are working.', tag: 'test' }, { urgency: 'high', TTL: 60 });
  }
}

function clamp(n, lo, hi) {
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : lo;
}
