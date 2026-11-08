// TradePad service worker: makes the app installable and shows an offline page.
// It never caches the app itself, so every launch loads the newest version (no Ctrl+F5 needed).
const V = "tp-offline-1";
const OFFLINE = "/offline.html";
self.addEventListener("install", (e) => { e.waitUntil(caches.open(V).then((c) => c.addAll([OFFLINE, "/icons/icon-192.png"]))); self.skipWaiting(); });
self.addEventListener("activate", (e) => { e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== V).map((k) => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener("fetch", (e) => {
  if (e.request.mode !== "navigate") return;            // data, RPC and wallet calls go straight to the network
  e.respondWith(fetch(e.request).catch(() => caches.match(OFFLINE)));
});
