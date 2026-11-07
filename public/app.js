// Baby Monitor client. One file, two roles:
//  - Baby station: captures camera + mic, streams to every parent via WebRTC,
//    and reports the current sound level over the signaling socket.
//  - Parent station: plays the stream, raises alerts on sustained noise and
//    when the baby station stops reporting in.

const $ = (id) => document.getElementById(id);
const store = {
  get: (k, d) => { try { return JSON.parse(localStorage.getItem('bm.' + k)) ?? d; } catch { return d; } },
  set: (k, v) => localStorage.setItem('bm.' + k, JSON.stringify(v)),
  del: (k) => localStorage.removeItem('bm.' + k),
};

// ---------------------------------------------------------------------------
// Signaling socket with automatic reconnect
// ---------------------------------------------------------------------------

class Signaling {
  constructor({ role, password, name, onMessage, onState, onFatal }) {
    Object.assign(this, { role, password, name, onMessage, onState, onFatal });
    this.retry = 0;
    this.closed = false;
    this.connect();
  }

  connect() {
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    const ws = new WebSocket(`${scheme}://${location.host}/ws`);
    this.ws = ws;
    this.onState('connecting');
    ws.onopen = () => {
      ws.send(JSON.stringify({ type: 'join', role: this.role, password: this.password, name: this.name }));
    };
    ws.onmessage = (e) => {
      const msg = JSON.parse(e.data);
      if (msg.type === 'error') { this.lastError = msg.error; return; }
      if (msg.type === 'welcome') { this.retry = 0; this.id = msg.id; this.onState('online'); }
      this.onMessage(msg);
    };
    ws.onclose = (e) => {
      if (this.closed) return;
      // 4003 = bad password / rate limited, 4004 = replaced by another baby station
      if (e.code === 4003 || e.code === 4004) {
        this.closed = true;
        this.onFatal(this.lastError || 'Disconnected.');
        return;
      }
      this.onState('offline');
      const delay = Math.min(1000 * 2 ** this.retry++, 10_000);
      setTimeout(() => !this.closed && this.connect(), delay);
    };
    // Client-side keepalive so half-open sockets are noticed quickly.
    clearInterval(this.keepalive);
    this.keepalive = setInterval(() => this.send({ type: 'ping' }), 15_000);
  }

  send(msg) {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(msg));
  }

  close() {
    this.closed = true;
    clearInterval(this.keepalive);
    this.ws?.close();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function setPill(el, text, cls) {
  el.textContent = text;
  el.className = 'pill ' + (cls || '');
}

// Keep the screen on (needed so phones don't suspend the camera / audio).
let wakeLock = null;
async function keepAwake() {
  try {
    if ('wakeLock' in navigator && document.visibilityState === 'visible') {
      wakeLock = await navigator.wakeLock.request('screen');
    }
  } catch { /* not supported or denied */ }
}
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && wakeLock !== null) keepAwake();
});

// Run async operations on a peer connection strictly in order.
function enqueue(pc, fn) {
  pc._queue = (pc._queue || Promise.resolve()).then(fn).catch((err) => console.warn(err));
  return pc._queue;
}

// Convert an RMS amplitude into a friendly 0–100 level (−60 dBFS .. 0 dBFS).
function rmsToLevel(rms) {
  const db = 20 * Math.log10(Math.max(rms, 1e-6));
  return Math.round(Math.min(100, Math.max(0, ((db + 60) / 60) * 100)));
}

const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
  || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const isStandalone = matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;

// The service worker shows push notifications from the server.
const swReady = 'serviceWorker' in navigator && window.isSecureContext
  ? navigator.serviceWorker.register('/sw.js').then(() => navigator.serviceWorker.ready).catch((err) => {
    console.warn('Service worker unavailable:', err);
    return null;
  })
  : Promise.resolve(null);

function base64UrlToBytes(b64) {
  const pad = '='.repeat((4 - (b64.length % 4)) % 4);
  const raw = atob((b64 + pad).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

const timeStr = (d = new Date()) => d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });

// ---------------------------------------------------------------------------
// Setup screen
// ---------------------------------------------------------------------------

function initSetup() {
  const saved = store.get('login', null);
  if (saved) {
    $('password').value = saved.password || '';
    $('device-name').value = saved.name || '';
    document.querySelector(`input[name=role][value=${saved.role}]`)?.click();
  }
  if (!window.isSecureContext) {
    $('setup-error').textContent = 'This page must be opened over https:// for camera, microphone and alerts to work.';
  }
  $('setup-form').addEventListener('submit', (e) => {
    e.preventDefault();
    const login = {
      password: $('password').value,
      name: $('device-name').value.trim(),
      role: document.querySelector('input[name=role]:checked').value,
    };
    if ($('remember').checked) store.set('login', login); else store.del('login');
    $('setup').hidden = true;
    if (login.role === 'baby') startBaby(login); else startParent(login);
  });
}

function showFatal(message) {
  document.querySelectorAll('.screen').forEach((s) => { s.hidden = s.id !== 'setup'; });
  $('setup-error').textContent = message;
}

// ---------------------------------------------------------------------------
// Baby station
// ---------------------------------------------------------------------------

async function startBaby(login) {
  $('baby').hidden = false;
  const preview = $('baby-preview');
  /** @type {Map<string, RTCPeerConnection>} */
  const peers = new Map();
  let stream;
  let iceServers = [];
  let cameraOn = true;
  let sig;

  const audioConstraints = {
    // Hear the room as it is: no processing that could hide quiet sounds.
    echoCancellation: false,
    noiseSuppression: false,
    autoGainControl: false,
  };
  const videoConstraints = (deviceId) => ({
    ...(deviceId ? { deviceId: { exact: deviceId } } : { facingMode: 'user' }),
    width: { ideal: 1280 },
    height: { ideal: 720 },
    frameRate: { ideal: 24, max: 30 },
  });

  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: audioConstraints,
      video: videoConstraints(store.get('camera', null)),
    });
  } catch (err) {
    try {
      // Saved camera might be gone; retry with any camera, then audio only.
      stream = await navigator.mediaDevices.getUserMedia({ audio: audioConstraints, video: videoConstraints() })
        .catch(() => navigator.mediaDevices.getUserMedia({ audio: audioConstraints }));
    } catch {
      showFatal(`Could not access the camera/microphone: ${err.message}`);
      return;
    }
  }
  preview.srcObject = stream;
  keepAwake();

  // Camera picker
  async function fillCameras() {
    const devices = await navigator.mediaDevices.enumerateDevices();
    const cams = devices.filter((d) => d.kind === 'videoinput');
    const current = stream.getVideoTracks()[0]?.getSettings().deviceId;
    $('camera-select').innerHTML = '';
    cams.forEach((c, i) => {
      const opt = new Option(c.label || `Camera ${i + 1}`, c.deviceId, false, c.deviceId === current);
      $('camera-select').add(opt);
    });
    $('camera-select').hidden = cams.length < 2;
  }
  fillCameras();

  $('camera-select').addEventListener('change', async (e) => {
    const deviceId = e.target.value;
    try {
      const camStream = await navigator.mediaDevices.getUserMedia({ video: videoConstraints(deviceId) });
      const newTrack = camStream.getVideoTracks()[0];
      newTrack.enabled = cameraOn;
      const oldTrack = stream.getVideoTracks()[0];
      if (oldTrack) { stream.removeTrack(oldTrack); oldTrack.stop(); }
      stream.addTrack(newTrack);
      for (const pc of peers.values()) {
        if (pc._videoSender) await pc._videoSender.replaceTrack(newTrack);
      }
      preview.srcObject = stream;
      store.set('camera', deviceId);
    } catch (err) {
      alert(`Could not switch camera: ${err.message}`);
    }
  });

  $('baby-video-toggle').addEventListener('click', () => {
    cameraOn = !cameraOn;
    stream.getVideoTracks().forEach((t) => { t.enabled = cameraOn; });
    $('baby-video-toggle').textContent = cameraOn ? '📷 Camera on' : '🚫 Camera off';
  });

  $('night-btn').addEventListener('click', () => { $('night-overlay').hidden = false; });
  $('night-overlay').addEventListener('click', () => { $('night-overlay').hidden = true; });

  // Sound level meter
  const audioCtx = new AudioContext();
  document.addEventListener('pointerdown', () => audioCtx.resume(), { once: true });
  audioCtx.resume().catch(() => {});
  let analyser;
  if (stream.getAudioTracks().length) {
    const source = audioCtx.createMediaStreamSource(stream);
    analyser = audioCtx.createAnalyser();
    analyser.fftSize = 2048;
    source.connect(analyser);
  }
  const buf = new Float32Array(2048);
  const meterTimer = setInterval(() => {
    let level = 0;
    if (analyser) {
      analyser.getFloatTimeDomainData(buf);
      let sum = 0;
      for (let i = 0; i < buf.length; i++) sum += buf[i] * buf[i];
      level = rmsToLevel(Math.sqrt(sum / buf.length));
    }
    $('baby-meter-fill').style.width = level + '%';
    sig?.send({ type: 'status', level, camera: cameraOn && stream.getVideoTracks().length > 0 });
  }, 250);

  // WebRTC: one connection per parent, baby is always the offerer.
  function closePeer(id) {
    peers.get(id)?.close();
    peers.delete(id);
  }

  function createPeer(parentId) {
    closePeer(parentId);
    const pc = new RTCPeerConnection({ iceServers });
    peers.set(parentId, pc);
    for (const track of stream.getTracks()) {
      const sender = pc.addTrack(track, stream);
      if (track.kind === 'video') pc._videoSender = sender;
    }
    pc.onicecandidate = (e) => {
      if (e.candidate) sig.send({ type: 'signal', to: parentId, data: { candidate: e.candidate } });
    };
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'failed' && peers.get(parentId) === pc) closePeer(parentId);
    };
    enqueue(pc, async () => {
      await pc.setLocalDescription(await pc.createOffer());
      sig.send({ type: 'signal', to: parentId, data: { description: pc.localDescription } });
    });
  }

  sig = new Signaling({
    role: 'baby',
    password: login.password,
    name: login.name || 'Baby station',
    onState: (s) => {
      setPill($('baby-conn'), s === 'online' ? 'Online' : s === 'connecting' ? 'Connecting…' : 'Offline – retrying', s === 'online' ? 'ok' : s === 'connecting' ? 'warn' : 'bad');
      $('baby-error').hidden = s !== 'offline';
      $('baby-error').textContent = 'Lost connection to the server. Retrying…';
    },
    onFatal: (msg) => { cleanup(); showFatal(msg); },
    onMessage: (msg) => {
      switch (msg.type) {
        case 'welcome':
          iceServers = msg.iceServers;
          // After a reconnect old connections are stale; parents will ask again.
          for (const id of [...peers.keys()]) closePeer(id);
          break;
        case 'parents': {
          const n = msg.parents.length;
          setPill($('baby-viewers'), `${n} parent${n === 1 ? '' : 's'} watching`, n ? 'ok' : '');
          const live = new Set(msg.parents.map((p) => p.id));
          for (const id of [...peers.keys()]) if (!live.has(id)) closePeer(id);
          break;
        }
        case 'peer-left':
          closePeer(msg.id);
          break;
        case 'signal': {
          const { from, data } = msg;
          if (data.requestOffer) { createPeer(from); break; }
          const pc = peers.get(from);
          if (!pc) break;
          if (data.description) enqueue(pc, () => pc.setRemoteDescription(data.description));
          if (data.candidate) enqueue(pc, () => pc.addIceCandidate(data.candidate));
          break;
        }
      }
    },
  });

  function cleanup() {
    clearInterval(meterTimer);
    sig.close();
    for (const id of [...peers.keys()]) closePeer(id);
    stream.getTracks().forEach((t) => t.stop());
    audioCtx.close();
    wakeLock?.release();
    wakeLock = null;
    $('baby').hidden = true;
  }

  $('baby-leave').addEventListener('click', () => { cleanup(); location.reload(); });
}

// ---------------------------------------------------------------------------
// Parent station
// ---------------------------------------------------------------------------

async function startParent(login) {
  $('parent').hidden = false;
  const video = $('remote-video');
  let pc = null;
  let babyId = null;
  let iceServers = [];
  let sig;
  let lastStatusAt = 0;
  let everConnected = false;
  let reconnectTimer = null;

  // Settings
  const settings = { threshold: 35, sustain: 2, volume: 1, muted: false, hideVideo: false, ...store.get('parentSettings', {}) };
  const save = () => store.set('parentSettings', settings);
  $('threshold').value = settings.threshold;
  $('sustain').value = String(settings.sustain);
  $('volume').value = settings.volume;

  function applySettings() {
    $('threshold-mark').style.left = settings.threshold + '%';
    video.volume = settings.volume;
    video.muted = settings.muted;
    $('mute-btn').textContent = settings.muted ? '🔇 Unmute' : '🔈 Mute';
    video.hidden = settings.hideVideo;
    $('audio-only-msg').hidden = !settings.hideVideo || !video.srcObject;
    $('video-toggle').textContent = settings.hideVideo ? '👁 Show video' : '🙈 Hide video';
  }
  applySettings();

  // iPhones ignore volume set from a web page; use the phone's buttons.
  if (isIOS) $('volume-label').hidden = true;

  const syncPushSettings = () => sig?.send({ type: 'push-settings', threshold: settings.threshold, sustain: settings.sustain });
  $('threshold').addEventListener('input', (e) => { settings.threshold = Number(e.target.value); applySettings(); save(); });
  $('threshold').addEventListener('change', syncPushSettings);
  $('sustain').addEventListener('change', (e) => { settings.sustain = Number(e.target.value); save(); syncPushSettings(); });
  $('volume').addEventListener('input', (e) => { settings.volume = Number(e.target.value); applySettings(); save(); });
  $('mute-btn').addEventListener('click', () => { settings.muted = !settings.muted; applySettings(); save(); });
  $('video-toggle').addEventListener('click', () => { settings.hideVideo = !settings.hideVideo; applySettings(); save(); });
  $('fullscreen-btn').addEventListener('click', () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else ($('video-wrap').requestFullscreen?.() ?? video.webkitEnterFullscreen?.());
  });

  setInterval(() => { $('clock').textContent = timeStr().slice(0, 5); }, 1000);
  $('clock').textContent = timeStr().slice(0, 5);

  // We're inside the "Start" tap, so audio may be unlocked now.
  // On iPhone, 'playback' makes alert sounds play even with the silent switch on.
  if (navigator.audioSession) {
    try { navigator.audioSession.type = 'playback'; } catch { /* ignore */ }
  }
  const alertCtx = new AudioContext();
  alertCtx.resume().catch(() => {});
  keepAwake();

  // Activity log
  function log(text) {
    const li = document.createElement('li');
    li.innerHTML = `<time>${timeStr()}</time>`;
    li.append(text);
    $('log').prepend(li);
    while ($('log').children.length > 200) $('log').lastChild.remove();
  }

  // Alerts
  function beep(kind) {
    try {
      alertCtx.resume();
      const notes = kind === 'bad' ? [880, 660, 880, 660] : [660, 880];
      notes.forEach((freq, i) => {
        const osc = alertCtx.createOscillator();
        const gain = alertCtx.createGain();
        osc.frequency.value = freq;
        const t = alertCtx.currentTime + i * 0.25;
        gain.gain.setValueAtTime(0.0001, t);
        gain.gain.exponentialRampToValueAtTime(0.4, t + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.22);
        osc.connect(gain).connect(alertCtx.destination);
        osc.start(t);
        osc.stop(t + 0.25);
      });
    } catch { /* ignore */ }
  }

  let alertHideTimer = null;
  function raiseAlert(text, kind = 'warn', { sticky = false } = {}) {
    const banner = $('alert-banner');
    banner.textContent = text;
    banner.className = 'alert ' + kind;
    banner.hidden = false;
    clearTimeout(alertHideTimer);
    if (!sticky) alertHideTimer = setTimeout(() => { banner.hidden = true; }, 15_000);
    beep(kind);
    navigator.vibrate?.(kind === 'bad' ? [400, 200, 400, 200, 400] : [300, 150, 300]);
    if (document.visibilityState !== 'visible' && swReg && Notification.permission === 'granted') {
      swReg.showNotification('Baby Monitor', { body: text, tag: 'baby-monitor', renotify: true, icon: '/icon-192.png' }).catch(() => {});
    }
    log(text);
  }
  function clearAlert() { $('alert-banner').hidden = true; }
  $('alert-banner').addEventListener('click', clearAlert);

  // Noise detection
  let aboveSince = null;
  let lastNoiseAlert = 0;
  function onLevel(level) {
    $('parent-meter-fill').style.width = level + '%';
    const now = Date.now();
    if (level >= settings.threshold) {
      aboveSince ??= now;
      if (now - aboveSince >= settings.sustain * 1000 && now - lastNoiseAlert > 30_000) {
        lastNoiseAlert = now;
        raiseAlert('🔊 Sound detected in the nursery');
      }
    } else {
      aboveSince = null;
    }
  }

  // Connection watchdog: shout if the baby station goes quiet.
  let contactLost = false;
  setInterval(() => {
    if (!everConnected) return;
    const silent = Date.now() - lastStatusAt > 12_000;
    if (silent && !contactLost) {
      contactLost = true;
      $('parent-meter-fill').style.width = '0%';
      raiseAlert('⚠️ Lost contact with the baby station', 'bad', { sticky: true });
    } else if (!silent && contactLost) {
      contactLost = false;
      clearAlert();
      log('✅ Baby station is back');
    }
  }, 2000);

  // Lock-screen alerts (Web Push). The server decides when to send them, so
  // they arrive even while this page is paused on a locked phone.
  let swReg = null;
  let vapidKey = null;
  let pushSub = null;

  function renderPush(statusText) {
    const supported = !!swReg && 'PushManager' in window;
    const hint = $('push-hint');
    hint.hidden = true;
    ['push-enable', 'push-test', 'push-disable'].forEach((b) => { $(b).hidden = true; });
    if (isIOS && !isStandalone) {
      $('push-status').textContent = '– off';
      hint.textContent = 'To get alerts while your iPhone is locked: tap the Share button ⎋ in Safari, choose “Add to Home Screen”, then open Baby Monitor from the Home Screen icon.';
      hint.hidden = false;
      return;
    }
    if (!supported) {
      $('push-status').textContent = '– not available';
      hint.textContent = 'This browser can’t receive push alerts here. They need a trusted https address (see the README), and on iPhone iOS 16.4 or newer.';
      hint.hidden = false;
      return;
    }
    if (pushSub) {
      $('push-status').textContent = statusText || '– on';
      $('push-test').hidden = false;
      $('push-disable').hidden = false;
    } else {
      $('push-status').textContent = statusText || '– off';
      hint.textContent = Notification.permission === 'denied'
        ? 'Notifications are blocked for this app. Allow them in Settings → Notifications → Baby Monitor.'
        : 'Get a notification on your lock screen when the baby makes noise or the baby station goes offline.';
      hint.hidden = false;
      $('push-enable').hidden = Notification.permission === 'denied';
    }
  }

  function reportState() {
    sig?.send({ type: 'parent-state', endpoint: pushSub?.endpoint || null, visible: document.visibilityState === 'visible' });
  }
  document.addEventListener('visibilitychange', reportState);

  function registerPush() {
    if (!pushSub) return;
    sig.send({ type: 'push-subscribe', subscription: pushSub.toJSON(), threshold: settings.threshold, sustain: settings.sustain });
  }

  swReady.then(async (reg) => {
    swReg = reg;
    if (reg && 'PushManager' in window) pushSub = await reg.pushManager.getSubscription().catch(() => null);
    renderPush();
    if (pushSub && sig?.id) { registerPush(); reportState(); }
  });

  $('push-enable').addEventListener('click', async () => {
    if (!vapidKey || !swReg) return;
    $('push-status').textContent = '– turning on…';
    try {
      // Called straight from the tap: iOS requires a user gesture here.
      pushSub = await swReg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: base64UrlToBytes(vapidKey) });
      registerPush();
      reportState();
      renderPush();
      log('🔔 Lock-screen alerts turned on');
    } catch (err) {
      pushSub = null;
      renderPush(`– failed: ${err.message}`);
    }
  });
  $('push-test').addEventListener('click', () => {
    sig.send({ type: 'push-test' });
    $('push-status').textContent = '– test sent';
  });
  $('push-disable').addEventListener('click', async () => {
    const endpoint = pushSub?.endpoint;
    await pushSub?.unsubscribe().catch(() => {});
    pushSub = null;
    if (endpoint) sig.send({ type: 'push-unsubscribe', endpoint });
    reportState();
    renderPush();
    log('🔕 Lock-screen alerts turned off');
  });

  // WebRTC
  function closePc() {
    clearTimeout(reconnectTimer);
    pc?.close();
    pc = null;
  }

  function requestOffer() {
    if (!babyId) return;
    sig.send({ type: 'signal', to: babyId, data: { requestOffer: true } });
  }

  function showWaiting(text) {
    $('waiting').textContent = text;
    $('waiting').hidden = false;
  }

  async function playVideo() {
    try {
      await video.play();
      $('tap-to-listen').hidden = true;
    } catch {
      // Autoplay with sound was blocked: we need one more tap.
      $('tap-to-listen').hidden = false;
    }
  }
  $('tap-to-listen').addEventListener('click', () => { alertCtx.resume(); playVideo(); });

  function handleOffer(description) {
    closePc();
    const conn = new RTCPeerConnection({ iceServers });
    pc = conn;
    conn.ontrack = (e) => {
      if (video.srcObject !== e.streams[0]) {
        video.srcObject = e.streams[0];
        applySettings();
      }
      $('waiting').hidden = true;
      playVideo();
    };
    conn.onicecandidate = (e) => {
      if (e.candidate) sig.send({ type: 'signal', to: babyId, data: { candidate: e.candidate } });
    };
    conn.onconnectionstatechange = () => {
      if (pc !== conn) return;
      const s = conn.connectionState;
      if (s === 'connected') {
        clearTimeout(reconnectTimer);
        setPill($('parent-conn'), 'Live', 'ok');
      } else if (s === 'disconnected' || s === 'failed') {
        setPill($('parent-conn'), 'Reconnecting…', 'warn');
        clearTimeout(reconnectTimer);
        reconnectTimer = setTimeout(requestOffer, s === 'failed' ? 0 : 4000);
      }
    };
    enqueue(conn, async () => {
      await conn.setRemoteDescription(description);
      await conn.setLocalDescription(await conn.createAnswer());
      sig.send({ type: 'signal', to: babyId, data: { description: conn.localDescription } });
    });
  }

  sig = new Signaling({
    role: 'parent',
    password: login.password,
    name: login.name || 'Parent',
    onState: (s) => {
      if (s !== 'online') setPill($('parent-conn'), s === 'connecting' ? 'Connecting…' : 'Server unreachable', s === 'connecting' ? 'warn' : 'bad');
    },
    onFatal: (msg) => { cleanup(); showFatal(msg); },
    onMessage: (msg) => {
      switch (msg.type) {
        case 'push-ok':
          renderPush();
          break;
        case 'welcome':
          iceServers = msg.iceServers;
          babyId = msg.babyId;
          vapidKey = msg.vapidPublicKey;
          registerPush();
          reportState();
          if (babyId) {
            setPill($('parent-conn'), 'Connecting to baby…', 'warn');
            requestOffer();
          } else {
            setPill($('parent-conn'), 'Baby station offline', 'bad');
            showWaiting('Waiting for the baby station… Open this page on the device in the nursery and choose “Baby station”.');
          }
          break;
        case 'baby-online':
          babyId = msg.babyId;
          log('👶 Baby station connected');
          setPill($('parent-conn'), 'Connecting to baby…', 'warn');
          requestOffer();
          break;
        case 'baby-offline':
          babyId = null;
          closePc();
          setPill($('parent-conn'), 'Baby station offline', 'bad');
          showWaiting('The baby station disconnected. Waiting for it to come back…');
          break;
        case 'status':
          lastStatusAt = Date.now();
          everConnected = true;
          onLevel(msg.level);
          break;
        case 'signal': {
          if (msg.from !== babyId) break;
          const { data } = msg;
          if (data.description?.type === 'offer') handleOffer(data.description);
          else if (data.candidate && pc) enqueue(pc, () => pc.addIceCandidate(data.candidate));
          break;
        }
      }
    },
  });

  function cleanup() {
    sig.close();
    closePc();
    wakeLock?.release();
    wakeLock = null;
    $('parent').hidden = true;
  }

  $('parent-leave').addEventListener('click', () => { cleanup(); location.reload(); });
}

initSetup();
