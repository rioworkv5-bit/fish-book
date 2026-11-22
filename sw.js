// فيش بوك: التطبيق يفتح من غير نت بعد أول زيارة.
// ملفات التطبيق: النت الأول، ولو مفيش نت يتفتح المحفوظ.
// بيانات الجو (Open-Meteo) مش بتتحفظ هنا، التطبيق بيحفظها بنفسه في localStorage.
const CACHE = 'fishbook-v28';
const FILES = ['./', './index.html', './yasser-faq.js', './manifest.webmanifest', './icons/icon-192.png', './icons/badge-96.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// الإشعارات: السيرفر بيبعت {title, body, url}
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data.json(); } catch (x) {}
  e.waitUntil(self.registration.showNotification(d.title || 'فيش بوك', {
    body: d.body || '', icon: 'icons/icon-192.png', badge: 'icons/badge-96.png', dir: 'rtl', lang: 'ar', data: { url: d.url || './' }
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const u = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => {
    for (const c of cs) if (c.url.indexOf(self.registration.scope) === 0) { c.navigate(u); return c.focus(); }
    return self.clients.openWindow(u);
  }));
});

self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin) return;
  e.respondWith(
    fetch(e.request)
      .then(r => {
        if (r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
        return r;
      })
      .catch(() => caches.match(e.request, { ignoreSearch: true }).then(r => r || caches.match('./index.html')))
  );
});
