// فيش بوك: التطبيق يفتح من غير نت بعد أول زيارة.
// ملفات التطبيق: النت الأول، ولو مفيش نت يتفتح المحفوظ.
// بيانات الجو (Open-Meteo) مش بتتحفظ هنا، التطبيق بيحفظها بنفسه في localStorage.
const CACHE = 'fishbook-v1';
const FILES = ['./', './index.html', './logo.svg', './manifest.webmanifest'];

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
