// Service worker: shows push notifications from the server (noise, lost
// contact) even when the phone is locked or the app is closed.

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = { body: event.data?.text() }; }
  event.waitUntil(
    self.registration.showNotification(data.title || 'Baby Monitor', {
      body: data.body || '',
      tag: data.tag || 'baby-monitor',
      renotify: true,
      requireInteraction: data.tag === 'contact',
      icon: '/icon-192.png',
      badge: '/icon-192.png',
      timestamp: data.t || Date.now(),
      data: { url: '/' },
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of windows) {
      if ('focus' in w) return w.focus();
    }
    return self.clients.openWindow('/');
  })());
});
