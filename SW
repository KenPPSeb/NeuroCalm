/**
 * NeuroCalm — Service Worker
 * ─────────────────────────────────────────────────────────────
 * Strategy:
 *   • App shell (HTML, manifest, icons) → Cache-First
 *   • Firebase SDK CDN scripts          → Cache-First (long-lived)
 *   • Google Fonts                      → Cache-First (stale-while-revalidate)
 *   • Firestore/Auth API calls          → Network-Only (always fresh)
 *   • Everything else                   → Network-First with cache fallback
 *
 * To force an update: bump CACHE_VERSION below, then redeploy.
 */

const CACHE_VERSION  = 'neurocalm-v1.0.0';
const SHELL_CACHE    = `${CACHE_VERSION}-shell`;
const CDN_CACHE      = `${CACHE_VERSION}-cdn`;
const FONT_CACHE     = `${CACHE_VERSION}-fonts`;
const RUNTIME_CACHE  = `${CACHE_VERSION}-runtime`;

const ALL_CACHES = [SHELL_CACHE, CDN_CACHE, FONT_CACHE, RUNTIME_CACHE];

// ─── App Shell — pre-cached on install ───────────────────────
const SHELL_URLS = [
  './neurocalm-app.html',
  './manifest.json',
  './icons/icon-72x72.png',
  './icons/icon-96x96.png',
  './icons/icon-128x128.png',
  './icons/icon-144x144.png',
  './icons/icon-152x152.png',
  './icons/icon-192x192.png',
  './icons/icon-384x384.png',
  './icons/icon-512x512.png',
  './icons/icon-512x512-maskable.png',
  './icons/apple-touch-icon.png',
  './icons/favicon-32x32.png',
];

// ─── CDN assets — cache on first use ─────────────────────────
const CDN_ORIGINS = [
  'https://www.gstatic.com',          // Firebase SDKs
  'https://fonts.gstatic.com',        // Font files
];

const FONT_ORIGINS = [
  'https://fonts.googleapis.com',     // Font CSS
];

// ─── Never cache these (Firestore/Auth network calls) ────────
const NETWORK_ONLY_PATTERNS = [
  /firestore\.googleapis\.com/,
  /identitytoolkit\.googleapis\.com/,
  /securetoken\.googleapis\.com/,
  /firebase\.googleapis\.com/,
];

// ═══════════════════════════════════════════════════════════════
// INSTALL — Pre-cache app shell
// ═══════════════════════════════════════════════════════════════
self.addEventListener('install', event => {
  console.log('[NeuroCalm SW] Installing…', CACHE_VERSION);

  event.waitUntil(
    caches.open(SHELL_CACHE)
      .then(cache => {
        console.log('[NeuroCalm SW] Pre-caching app shell');
        // Use individual adds so one failure doesn't block all
        return Promise.allSettled(
          SHELL_URLS.map(url =>
            cache.add(url).catch(err =>
              console.warn(`[NeuroCalm SW] Failed to cache ${url}:`, err)
            )
          )
        );
      })
      .then(() => {
        console.log('[NeuroCalm SW] Install complete');
        return self.skipWaiting(); // Activate immediately
      })
  );
});

// ═══════════════════════════════════════════════════════════════
// ACTIVATE — Clean up old caches
// ═══════════════════════════════════════════════════════════════
self.addEventListener('activate', event => {
  console.log('[NeuroCalm SW] Activating…', CACHE_VERSION);

  event.waitUntil(
    caches.keys()
      .then(cacheNames => {
        return Promise.all(
          cacheNames
            .filter(name => !ALL_CACHES.includes(name))
            .map(name => {
              console.log('[NeuroCalm SW] Deleting old cache:', name);
              return caches.delete(name);
            })
        );
      })
      .then(() => {
        console.log('[NeuroCalm SW] Activated, claiming clients');
        return self.clients.claim();
      })
  );
});

// ═══════════════════════════════════════════════════════════════
// FETCH — Routing logic
// ═══════════════════════════════════════════════════════════════
self.addEventListener('fetch', event => {
  const { request } = event;
  const url = new URL(request.url);

  // Skip non-GET requests
  if (request.method !== 'GET') return;

  // Skip chrome-extension and non-http(s)
  if (!url.protocol.startsWith('http')) return;

  // 1. Network-Only: Firebase backend APIs
  if (NETWORK_ONLY_PATTERNS.some(p => p.test(request.url))) {
    event.respondWith(fetch(request));
    return;
  }

  // 2. Cache-First: App shell
  if (SHELL_URLS.some(u => request.url.endsWith(u.replace('./', '')))) {
    event.respondWith(cacheFirst(request, SHELL_CACHE));
    return;
  }

  // 3. Cache-First: Firebase & Google CDN assets (JS bundles)
  if (CDN_ORIGINS.some(o => request.url.startsWith(o))) {
    event.respondWith(cacheFirst(request, CDN_CACHE));
    return;
  }

  // 4. Stale-While-Revalidate: Google Fonts CSS
  if (FONT_ORIGINS.some(o => request.url.startsWith(o))) {
    event.respondWith(staleWhileRevalidate(request, FONT_CACHE));
    return;
  }

  // 5. Network-First with cache fallback: everything else
  event.respondWith(networkFirst(request, RUNTIME_CACHE));
});

// ═══════════════════════════════════════════════════════════════
// CACHE STRATEGIES
// ═══════════════════════════════════════════════════════════════

/** Cache-First: serve from cache, fetch & update if missing */
async function cacheFirst(request, cacheName) {
  const cache    = await caches.open(cacheName);
  const cached   = await cache.match(request);
  if (cached) return cached;

  try {
    const response = await fetch(request);
    if (response.ok) {
      cache.put(request, response.clone());
    }
    return response;
  } catch (err) {
    return offlineFallback(request);
  }
}

/** Network-First: try network, fall back to cache */
async function networkFirst(request, cacheName) {
  const cache = await caches.open(cacheName);
  try {
    const response = await fetch(request);
    if (response.ok) {
      cache.put(request, response.clone());
    }
    return response;
  } catch (err) {
    const cached = await cache.match(request);
    return cached || offlineFallback(request);
  }
}

/** Stale-While-Revalidate: serve cache immediately, update in background */
async function staleWhileRevalidate(request, cacheName) {
  const cache  = await caches.open(cacheName);
  const cached = await cache.match(request);

  // Kick off network request in background
  const networkPromise = fetch(request).then(response => {
    if (response.ok) cache.put(request, response.clone());
    return response;
  }).catch(() => null);

  return cached || await networkPromise || offlineFallback(request);
}

/** Offline fallback response */
function offlineFallback(request) {
  const url = new URL(request.url);

  // Return offline HTML for navigation requests
  if (request.mode === 'navigate') {
    return caches.match('./neurocalm-app.html');
  }

  // Return transparent 1×1 PNG for image requests
  if (request.destination === 'image') {
    return new Response(
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      { headers: { 'Content-Type': 'image/png' } }
    );
  }

  return new Response('Offline — NeuroCalm', {
    status: 503,
    headers: { 'Content-Type': 'text/plain' }
  });
}

// ═══════════════════════════════════════════════════════════════
// BACKGROUND SYNC — queue Firestore writes when offline
// ═══════════════════════════════════════════════════════════════
self.addEventListener('sync', event => {
  if (event.tag === 'neurocalm-sync') {
    console.log('[NeuroCalm SW] Background sync triggered');
    event.waitUntil(doBackgroundSync());
  }
});

async function doBackgroundSync() {
  // Notify all open clients to retry Firestore saves
  const clients = await self.clients.matchAll({ type: 'window' });
  clients.forEach(client => {
    client.postMessage({ type: 'BACKGROUND_SYNC', action: 'retry-saves' });
  });
}

// ═══════════════════════════════════════════════════════════════
// PUSH NOTIFICATIONS (future-ready)
// ═══════════════════════════════════════════════════════════════
self.addEventListener('push', event => {
  if (!event.data) return;

  let data;
  try { data = event.data.json(); }
  catch (e) { data = { title: 'NeuroCalm', body: event.data.text() }; }

  const options = {
    body:    data.body    || 'Time for a calm moment 🌿',
    icon:    './icons/icon-192x192.png',
    badge:   './icons/icon-96x96.png',
    vibrate: [200, 100, 200, 100, 200],
    data:    { url: data.url || './neurocalm-app.html' },
    actions: [
      { action: 'calm',    title: '🌬️ Breathe Now' },
      { action: 'dismiss', title: '✕ Dismiss'       },
    ],
    tag:              'neurocalm-reminder',
    renotify:         true,
    requireInteraction: false,
  };

  event.waitUntil(
    self.registration.showNotification(data.title || 'NeuroCalm', options)
  );
});

self.addEventListener('notificationclick', event => {
  event.notification.close();

  const targetUrl = event.action === 'calm'
    ? './neurocalm-app.html#calm'
    : event.notification.data?.url || './neurocalm-app.html';

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true })
      .then(clientList => {
        for (const client of clientList) {
          if (client.url.includes('neurocalm') && 'focus' in client) {
            return client.focus();
          }
        }
        return clients.openWindow(targetUrl);
      })
  );
});

// ═══════════════════════════════════════════════════════════════
// MESSAGE HANDLER — communicate with main app
// ═══════════════════════════════════════════════════════════════
self.addEventListener('message', event => {
  if (event.data?.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
  if (event.data?.type === 'GET_VERSION') {
    event.ports[0]?.postMessage({ version: CACHE_VERSION });
  }
});
