// بيبني ملفات الخريطة: data/contours.json (خطوط الأعماق) و data/reefs.json (الشعاب والنقط).
// المصادر:
//   1) شبكة أعماق GMRT بصيغة ESRI ASCII:
//      https://www.gmrt.org/services/GridServer?minlongitude=32.9&maxlongitude=36.0&minlatitude=24.5&maxlatitude=28.3&format=esriascii&mresolution=200&layer=topo
//   2) شعاب ونقط OpenStreetMap من Overpass (out tags geom) لنفس المنطقة.
// التشغيل:  npm i d3-contour  ثم  node tools/build-map-data.mjs <grid.asc> <osm.json>
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { contours } from 'd3-contour';
let gridMeta = null;

const [gridFile, osmFile] = process.argv.slice(2);
const outDir = path.resolve(process.argv[4] || 'data');
fs.mkdirSync(outDir, { recursive: true });

/* ---------- أدوات ---------- */
// Douglas-Peucker على نقط [x,y]
function simplify(pts, tol) {
  if (pts.length < 3) return pts;
  const keep = new Uint8Array(pts.length); keep[0] = keep[pts.length - 1] = 1;
  const st = [[0, pts.length - 1]], t2 = tol * tol;
  while (st.length) {
    const [a, b] = st.pop(); let mx = 0, mi = -1;
    const ax = pts[a][0], ay = pts[a][1], dx = pts[b][0] - ax, dy = pts[b][1] - ay, len = dx * dx + dy * dy;
    for (let i = a + 1; i < b; i++) {
      let px = pts[i][0] - ax, py = pts[i][1] - ay, d;
      if (len === 0) d = px * px + py * py;
      else { const u = Math.max(0, Math.min(1, (px * dx + py * dy) / len)); px -= u * dx; py -= u * dy; d = px * px + py * py; }
      if (d > mx) { mx = d; mi = i; }
    }
    if (mx > t2) { keep[mi] = 1; st.push([a, mi], [mi, b]); }
  }
  return pts.filter((_, i) => keep[i]);
}
// نقط -> أرقام صحيحة متتالية بالفرق (lon,lat مضروبين في q)
function pack(pts, q) {
  const out = []; let px = 0, py = 0;
  for (const [x, y] of pts) { const ix = Math.round(x * q), iy = Math.round(y * q); if (out.length && ix === px && iy === py) continue; out.push(ix - px, iy - py); px = ix; py = iy; }
  return out;
}
const span = pts => { let a = 1e9, b = -1e9, c = 1e9, d = -1e9; for (const [x, y] of pts) { if (x < a) a = x; if (x > b) b = x; if (y < c) c = y; if (y > d) d = y; } return Math.hypot(b - a, d - c); };

/* ---------- 1) خطوط الأعماق ---------- */
{
  const txt = fs.readFileSync(gridFile, 'latin1');
  let pos = 0; const hdr = {};
  for (let i = 0; i < 6; i++) { const e = txt.indexOf('\n', pos); const [k, v] = txt.slice(pos, e).trim().split(/\s+/); hdr[k.toLowerCase()] = Number(v); pos = e + 1; }
  const W = hdr.ncols, H = hdr.nrows, cs = hdr.cellsize, nd = hdr.nodata_value;
  const src = new Float32Array(W * H); let n = 0, num = '';
  for (let i = pos; i <= txt.length; i++) { const c = txt.charCodeAt(i); if (c > 32) num += txt[i]; else if (num) { src[n++] = Number(num); num = ''; } }
  if (n !== W * H) throw new Error('grid size mismatch ' + n + ' vs ' + W * H);
  // شبكة أعماق خفيفة للقراءة اللحظية تحت علامة نص الخريطة: data/depth.png
  // تصغير ×4 (حوالي 480 متر للخلية، قريب من دقة المصدر الحقيقية). العمق بالمتر في قناتين: R = العمق÷256، G = الباقي. 0 = بر.
  {
    const G = 4, gw = Math.floor(W / G), gh = Math.floor(H / G), raw = Buffer.alloc((gw * 3 + 1) * gh);
    for (let y = 0; y < gh; y++) { const row = y * (gw * 3 + 1); raw[row] = 0;
      for (let x = 0; x < gw; x++) { let s = 0, c = 0; for (let j = 0; j < G; j++) for (let i = 0; i < G; i++) { const v = src[(y * G + j) * W + x * G + i]; if (v !== nd && isFinite(v)) { s += v; c++; } }
        const d = c ? Math.max(0, Math.min(65535, Math.round(-s / c))) : 0; raw[row + 1 + x * 3] = d >> 8; raw[row + 2 + x * 3] = d & 255; } }
    const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type, 'ascii'), data]); const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32(td) >>> 0); return Buffer.concat([len, td, crc]); };
    const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(gw, 0); ihdr.writeUInt32BE(gh, 4); ihdr[8] = 8; ihdr[9] = 2;
    fs.writeFileSync(path.join(outDir, 'depth.png'), Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]));
    gridMeta = { w: gw, h: gh, cell: cs * G, x0: hdr.xllcorner + cs * G / 2, y1: hdr.yllcorner + H * cs - cs * G / 2 };
    console.log('depth grid:', gw + 'x' + gh, (fs.statSync(path.join(outDir, 'depth.png')).size / 1024 | 0) + ' KB');
  }
  // تصغير ×2 بالمتوسط (الدقة الحقيقية للمصدر أخشن من الشبكة أصلاً) + تنعيم خفيف
  const F = 2, w = Math.floor(W / F), h = Math.floor(H / F); let g = new Float32Array(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { let s = 0, c = 0; for (let j = 0; j < F; j++) for (let i = 0; i < F; i++) { const v = src[(y * F + j) * W + x * F + i]; if (v !== nd && isFinite(v)) { s += v; c++; } } g[y * w + x] = c ? -s / c : -1; }
  const b = new Float32Array(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { let s = 0, c = 0; for (let j = -1; j <= 1; j++) for (let i = -1; i <= 1; i++) { const xx = x + i, yy = y + j; if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue; const k = (i || j) ? 1 : 2; s += g[yy * w + xx] * k; c += k; } b[y * w + x] = s / c; }
  g = b;
  const cell = cs * F, lon = x => hdr.xllcorner + x * cell, lat = y => hdr.yllcorner + (H * cs) - y * cell;
  const LEVELS = [20, 30, 50, 75, 100, 150, 200, 300, 500, 750, 1000];
  const gen = contours().size([w, h]);
  const out = { q: 1e4, src: 'GMRT', grid: gridMeta, levels: {} }; let total = 0, npts = 0;
  for (const lv of LEVELS) {
    const lines = [];
    for (const poly of gen.thresholds([lv])(g)[0].coordinates) for (const ring of poly) {
      // نقطّع الحلقة عند حدود الشبكة عشان ميترسمش خط على إطار المنطقة
      let cur = []; const parts = [];
      for (const [x, y] of ring) { if (x < 1 || y < 1 || x > w - 1 || y > h - 1) { if (cur.length > 1) parts.push(cur); cur = []; } else cur.push([lon(x), lat(y)]); }
      if (cur.length > 1) parts.push(cur);
      for (const p of parts) { if (span(p) < (lv <= 50 ? 0.02 : 0.012)) continue; const s = simplify(p, 0.0004); if (s.length > 1) { const k = pack(s, 1e4); if (k.length >= 4) { lines.push(k); npts += k.length / 2; } } }
    }
    out.levels[lv] = lines; total += lines.length;
  }
  fs.writeFileSync(path.join(outDir, 'contours.json'), JSON.stringify(out));
  console.log('contours:', total, 'lines,', npts, 'pts,', (fs.statSync(path.join(outDir, 'contours.json')).size / 1024 | 0) + ' KB');
}

/* ---------- 2) الشعاب والنقط ---------- */
{
  const els = JSON.parse(fs.readFileSync(osmFile, 'utf8')).elements;
  const nm = t => (t['name:ar'] || t.name || t['name:en'] || '').trim();
  const Q = 1e5, reefs = [], pts = [];
  const centroid = p => { let x = 0, y = 0; for (const a of p) { x += a[0]; y += a[1]; } return [x / p.length, y / p.length]; };
  const addReef = (ring, name) => { if (ring.length < 3) return; const s = simplify(ring, 0.00004); if (s.length < 3) return; const r = { p: pack(s, Q) }; if (name) { const c = centroid(s); r.n = name; r.c = [Math.round(c[0] * Q), Math.round(c[1] * Q)]; } reefs.push(r); };
  // لمّ طرق العلاقة في حلقات مقفولة
  function stitch(ways) {
    const rings = [], pool = ways.map(w => w.slice());
    while (pool.length) {
      let cur = pool.pop(), grew = true;
      const same = (a, b) => a[0] === b[0] && a[1] === b[1];
      while (grew && !same(cur[0], cur[cur.length - 1])) {
        grew = false;
        for (let i = 0; i < pool.length; i++) { const w = pool[i], end = cur[cur.length - 1];
          if (same(w[0], end)) { cur = cur.concat(w.slice(1)); } else if (same(w[w.length - 1], end)) { cur = cur.concat(w.slice(0, -1).reverse()); } else continue;
          pool.splice(i, 1); grew = true; break; }
      }
      rings.push(cur);
    }
    return rings;
  }
  const BIZ = /divers?\b|diving|resort|cent(er|re)|club|college|hotel|school|tauch|scuba|safari|shop|base\b/i;
  for (const e of els) {
    const t = e.tags || {}, name = nm(t);
    if (e.type === 'way' && /^(reef|shoal)$/.test(t.natural || '')) addReef(e.geometry.map(p => [p.lon, p.lat]), name);
    else if (e.type === 'relation' && /^(reef|shoal)$/.test(t.natural || '')) {
      const outers = (e.members || []).filter(m => m.type === 'way' && m.geometry && m.role !== 'inner').map(m => m.geometry.map(p => [p.lon, p.lat]));
      stitch(outers).forEach((r, i) => addReef(r, i === 0 ? name : ''));
    } else if (e.type === 'node') {
      const P = (k, n) => pts.push({ t: k, n: n || undefined, x: Math.round(e.lon * Q), y: Math.round(e.lat * Q) });
      if (t['seamark:type'] === 'wreck' || t.historic === 'wreck') P('wreck', name);
      else if (t['seamark:type'] === 'rock' || t['seamark:type'] === 'obstruction') P('rock', name);
      else if (/^(reef|shoal)$/.test(t.natural || '')) { if (name) P('reef', name); }
      else if (t.sport === 'scuba_diving') { if (name && !BIZ.test(name) && !t.shop && !t.amenity && !t.tourism && !t.office) P('site', name); }
      else if (t.place === 'island' || t.place === 'islet') { if (name) P('isl', name); }
      else if (/^(bay|cape|strait)$/.test(t.natural || '')) { if (name) P('cape', name); }
    }
  }
  // 3) أسماء الخرائط الرسمية من GeoNames (ملف EG.txt من https://download.geonames.org/export/dump/EG.zip) - اختياري، رابع باراميتر
  const gnFile = process.argv[5];
  if (gnFile) {
    const KIND = { RF: 'reef', RFC: 'reef', SHOL: 'reef', BNK: 'reef', RK: 'rock', RKS: 'rock', ISL: 'isl', ISLS: 'isl', ISLET: 'isl', ANCH: 'anch',
      PT: 'cape', CAPE: 'cape', BAY: 'cape', COVE: 'cape', INLT: 'cape', STRT: 'cape', CHN: 'cape', CHNM: 'cape', HBR: 'cape' };
    const coarse = v => Math.abs(v * 60 - Math.round(v * 60)) < 0.002; // إحداثي متقرّب لأقرب دقيقة = مكان مش مضبوط
    let add = 0;
    for (const ln of fs.readFileSync(gnFile, 'utf8').split('\n')) {
      const f = ln.split('\t'); if (f.length < 8) continue;
      const la = +f[4], lo = +f[5], k = KIND[f[7]];
      if (!k || la < 24.5 || la > 28.3 || lo < 32.9 || lo > 36.0) continue;
      if ((k === 'reef' || k === 'rock' || k === 'anch') && coarse(la) && coarse(lo)) continue;
      const ar = f[3].split(',').find(s => /[؀-ۿ]/.test(s)), name = (ar || f[1]).trim();
      const x = Math.round(lo * Q), y = Math.round(la * Q);
      // متكررش نقطة OSM قريبة (أقل من ~500 متر) من نفس النوع
      if (pts.some(p => p.t === k && p.n && Math.abs(p.x - x) < 500 && Math.abs(p.y - y) < 500)) continue;
      pts.push({ t: k, n: name, x, y, g: 1 }); add++;
    }
    console.log('geonames added:', add);
  }
  fs.writeFileSync(path.join(outDir, 'reefs.json'), JSON.stringify({ q: Q, src: 'OpenStreetMap, GeoNames', reefs, pts }));
  const by = {}; pts.forEach(p => by[p.t] = (by[p.t] || 0) + 1);
  console.log('reefs:', reefs.length, 'named', reefs.filter(r => r.n).length, 'points', by, (fs.statSync(path.join(outDir, 'reefs.json')).size / 1024 | 0) + ' KB');
}
