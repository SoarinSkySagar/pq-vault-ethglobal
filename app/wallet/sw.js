// Service worker for the installable wallet app. It caches only the app shell so the app opens without a
// connection and can say the wallet computer is unreachable. API responses (balances, jobs) are never cached:
// every /api/ request goes to the wallet process, and every signature is made there, never on the phone.
"use strict";
const CACHE = "pq-wallet-shell-v1";
const SHELL = ["/", "/manifest.webmanifest", "/icons/icon-192.png", "/icons/icon-512.png", "/icons/apple-touch-icon.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== self.location.origin || url.pathname.startsWith("/api/")) return;
  const key = e.request.mode === "navigate" ? "/" : url.pathname;
  if (!SHELL.includes(key)) return;
  // network first, so a new version of the app shows up at once; the cached copy is the offline fallback
  e.respondWith(fetch(e.request).then((r) => {
    if (r.ok) { const copy = r.clone(); caches.open(CACHE).then((c) => c.put(key, copy)); }
    return r;
  }).catch(() => caches.match(key)));
});
