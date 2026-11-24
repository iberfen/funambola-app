const SHELL = 'funambola-shell-v3';
const root = new URL('./', self.location.href).href;

self.addEventListener('install', event => {
  event.waitUntil(caches.open(SHELL)
    .then(cache => cache.addAll([root, './icon-192.png', './icon-512.png', './manifest.webmanifest']))
    .then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
  event.waitUntil(Promise.all(['funambola-shell-v1', 'funambola-shell-v2'].map(key => caches.delete(key)))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', event => {
  if (event.request.mode !== 'navigate' || !event.request.url.startsWith(root)) return;
  event.respondWith(fetch(event.request, {cache: 'no-cache'}).catch(async () => (await caches.match(root)) || Response.error()));
});
