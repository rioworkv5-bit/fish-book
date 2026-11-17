// فيش بوك: إرسال الإشعارات (Web Push). Edge Function اسمها push، و Verify JWT مقفول عليها.
// الطلبات (POST JSON):
//   {action:"key"}     المفتاح العام اللي التطبيق بيشترك بيه (بيتولد أول مرة ويتحفظ في app_private)
//   {action:"drain"}   يبعت الإشعارات المستنية في notif_queue (المحتوى جاي من قاعدة البيانات، مش من اللي بينادي)
//   {action:"morning"} إشعار الصبح لكل المشتركين. محتاج الهيدر x-cron-secret (بينادي عليه pg_cron بس)
//   {action:"goodday"} تنبيه "يوم كويس وفيه أماكن". محتاج x-cron-secret. مع dry:true بيرجّع اللي كان هيتبعت من غير ما يبعت ومن غير الرقم السري
//   {action:"scores", area} مؤشر الصيد للعشر أيام الجاية في منطقة (للمراجعة مع التطبيق)
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEY") ?? "",
  { auth: { persistSession: false } },
);

async function kv(k: string): Promise<string | null> {
  const { data, error } = await db.from("app_private").select("v").eq("k", k).maybeSingle();
  if (error) throw new Error("app_private: " + error.message);
  return data?.v ?? null;
}

async function vapid(): Promise<string> {
  let pub = await kv("vapid_public"), priv = await kv("vapid_private");
  if (!pub || !priv) {
    const g = webpush.generateVAPIDKeys();
    await db.from("app_private").upsert(
      [{ k: "vapid_public", v: g.publicKey }, { k: "vapid_private", v: g.privateKey }],
      { onConflict: "k", ignoreDuplicates: true },
    );
    pub = await kv("vapid_public"); priv = await kv("vapid_private");
  }
  webpush.setVapidDetails("https://rioworkv5-bit.github.io/fish-book/", pub!, priv!);
  return pub!;
}

type Sub = { id: number; endpoint: string; p256dh: string; auth: string };
async function send(s: Sub, payload: unknown): Promise<boolean> {
  try {
    await webpush.sendNotification(
      { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
      JSON.stringify(payload), { TTL: 6 * 3600 },
    );
    return true;
  } catch (e) {
    const code = (e as { statusCode?: number }).statusCode;
    if (code === 404 || code === 410) await db.from("push_subs").delete().eq("id", s.id); // الاشتراك انتهى
    return false;
  }
}

async function drain() {
  await vapid();
  const { data: rows, error } = await db.from("notif_queue").delete().gt("id", 0).select();
  if (error) throw new Error("notif_queue: " + error.message);
  let sent = 0;
  for (const n of rows ?? []) {
    const { data: subs } = await db.from("push_subs").select("id,endpoint,p256dh,auth").eq("user_id", n.user_id);
    for (const s of subs ?? []) if (await send(s as Sub, { title: n.title, body: n.body, url: n.url })) sent++;
  }
  return { queued: rows?.length ?? 0, sent };
}

const HM = ["محرم", "صفر", "ربيع الأول", "ربيع الآخر", "جمادى الأولى", "جمادى الآخرة", "رجب", "شعبان", "رمضان", "شوال", "ذو القعدة", "ذو الحجة"];
async function morning() {
  await vapid();
  const p: Record<string, string> = {};
  new Intl.DateTimeFormat("en-u-ca-islamic-umalqura-nu-latn", { day: "numeric", month: "numeric", timeZone: "Africa/Cairo" })
    .formatToParts(new Date()).forEach((x) => p[x.type] = x.value);
  const day = parseInt(p.day, 10), mon = parseInt(p.month, 10);
  const fasad = (day >= 5 && day <= 11) || (day >= 19 && day <= 26);
  const { data: subs } = await db.from("push_subs").select("id,endpoint,p256dh,auth,area_name,lat,lon").eq("morning", true);
  const wind: Record<string, number | null> = {};
  let sent = 0;
  for (const s of subs ?? []) {
    const key = s.lat + "," + s.lon;
    if (!(key in wind)) {
      wind[key] = null;
      try {
        const r = await fetch(`https://api.open-meteo.com/v1/forecast?latitude=${s.lat}&longitude=${s.lon}&hourly=wind_speed_10m&wind_speed_unit=kn&timezone=Africa%2FCairo&forecast_days=1`);
        const w: number[] = (await r.json()).hourly.wind_speed_10m.slice(5, 18);
        wind[key] = Math.round(w.reduce((a, b) => a + b, 0) / w.length);
      } catch (_) { /* من غير رياح */ }
    }
    const w = wind[key];
    const body = `${day} ${HM[mon - 1]}: ${fasad ? "فساد، تيار ضعيف" : "حمل، تيار قوي"}.` +
      (w === null ? "" : ` رياح النهار في ${s.area_name} حوالي ${w} عقدة.`) + " افتح التطبيق تشوف مؤشر الصيد والتوقيفات.";
    if (await send(s as Sub, { title: "صباح الخير من فيش بوك", body, url: "./#home" })) sent++;
  }
  return { subs: subs?.length ?? 0, sent };
}

// ---------- مؤشر الصيد: نسخة من score() في index.html. أي تعديل هناك لازم يتعمل هنا كمان ----------
type Area = { name: string; lat: number; lon: number; slon?: number };
const AREAS: Record<string, Area> = {
  hurghada: { name: "الغردقة", lat: 27.26, lon: 33.83, slon: 33.90 },
  giftun: { name: "الجفتون", lat: 27.20, lon: 33.97 },
  gouna: { name: "الجونة", lat: 27.40, lon: 33.75 },
  tawila: { name: "طويلة", lat: 27.58, lon: 33.78 },
  gubal: { name: "جوبال", lat: 27.67, lon: 33.82 },
  shadwan: { name: "شدوان", lat: 27.50, lon: 34.00 },
  safaga: { name: "سفاجا", lat: 26.75, lon: 34.02 },
  quseir: { name: "القصير", lat: 26.10, lon: 34.33 },
  marsaalam: { name: "مرسى علم", lat: 25.07, lon: 34.95 },
};
const FORECAST_DAYS = 10;
const HRS = [2, 5, 8, 11, 14, 17, 20, 23];
const WT = { wind: 35, wave: 20, hijri: 20, tide: 10, pres: 10, temp: 5 };
const WD = ["الأحد", "الإثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"];
const isFasadDay = (d: number) => (d >= 5 && d <= 11) || (d >= 19 && d <= 26);
const isTurnDay = (d: number) => [3, 4, 11, 12, 17, 18, 26, 27].includes(d);
const noon = (k: string) => new Date(k + "T10:00:00Z"); // 12 الضهر بتوقيت مصر تقريبًا
const addDaysK = (k: string, n: number) => { const x = new Date(k + "T12:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const cairoToday = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Africa/Cairo", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
const hFmt = new Intl.DateTimeFormat("en-u-ca-islamic-umalqura-nu-latn", { day: "numeric", timeZone: "Africa/Cairo" });
const hijriDay = (k: string) => parseInt(hFmt.formatToParts(noon(k)).find((p) => p.type === "day")!.value, 10);
const dm = (k: string) => `${WD[new Date(k + "T12:00:00Z").getUTCDay()]} ${Number(k.slice(8))}/${Number(k.slice(5, 7))}`;

type Hourly = Record<string, Record<string, (number | null)[]>>;
async function areaData(a: Area): Promise<Hourly> {
  const wx = await (await fetch(`https://api.open-meteo.com/v1/forecast?latitude=${a.lat}&longitude=${a.lon}&hourly=wind_speed_10m,temperature_2m,pressure_msl&wind_speed_unit=kn&timezone=Africa%2FCairo&forecast_days=12`)).json();
  let mj: { hourly?: Record<string, (number | null)[] | string[]> } = {};
  try { mj = await (await fetch(`https://marine-api.open-meteo.com/v1/marine?latitude=${a.lat}&longitude=${a.slon ?? a.lon}&hourly=wave_height,sea_level_height_msl&timezone=Africa%2FCairo&forecast_days=12`)).json(); } catch (_) { /* من غير موج ومد */ }
  const days: Hourly = {};
  const put = (h: Record<string, unknown[]> | undefined, map: Record<string, string>) => {
    if (!h || !h.time) return;
    (h.time as string[]).forEach((s, i) => {
      const o = days[s.slice(0, 10)] ??= {}, hr = Number(s.slice(11, 13));
      for (const f in map) if (h[f]) (o[map[f]] ??= [])[hr] = h[f][i] as number | null;
    });
  };
  put(wx.hourly, { wind_speed_10m: "wind", temperature_2m: "temp", pressure_msl: "pres" });
  put(mj.hourly as Record<string, unknown[]>, { wave_height: "wave", sea_level_height_msl: "sea" });
  return days;
}

function dayScore(k: string, today: string, data: Hourly): { val: number; prelim: boolean } {
  const hd = hijriDay(k), fas = isFasadDay(hd), turn = isTurnDay(hd);
  const prelim = { val: fas ? (turn ? 80 : 70) : (turn ? 60 : 50), prelim: true };
  if (k < today || k > addDaysK(today, FORECAST_DAYS - 1)) return prelim;
  const d = data[k]; if (!d) return prelim;
  const pick = (a?: (number | null)[]) => HRS.map((h) => (a && typeof a[h] === "number" ? a[h] as number : null));
  const W = pick(d.wind), T = pick(d.temp), P = pick(d.pres), V = pick(d.wave);
  if ([...W, ...T, ...P].includes(null)) return prelim;
  const wind = (W as number[]).map(Math.round), temp = (T as number[]).map(Math.round), pres = (P as number[]).map(Math.round);
  const wave = V.includes(null) ? wind.map((w) => Math.max(0.2, Math.round(w * 0.045 * 10) / 10)) : (V as number[]).map((x) => Math.round(x * 10) / 10);
  const idx = [1, 2, 3, 4, 5], avg = (a: number[]) => idx.reduce((s, i) => s + a[i], 0) / idx.length;
  const lin = (x: number, good: number, bad: number) => Math.max(0, Math.min(1, (bad - x) / (bad - good)));
  const aw = avg(wind), av = avg(wave), at = avg(temp), dp = Math.abs(pres[7] - pres[0]);
  const hs = [...(d.sea ?? []).slice(0, 24), data[addDaysK(k, 1)]?.sea?.[0]];
  const rng = hs.length === 25 && hs.every((x) => typeof x === "number") ? Math.max(...hs as number[]) - Math.min(...hs as number[]) : null;
  const pts = WT.wind * lin(aw, 8, 22) + WT.wave * lin(av, 0.4, 1.5)
    + Math.min(WT.hijri, WT.hijri * (fas ? 1 : 0.5) + (turn ? WT.hijri * 0.15 : 0))
    + WT.tide * (rng === null ? (fas ? 0.8 : 0.5) : 0.4 + 0.6 * lin(rng, 0.25, 0.75))
    + WT.pres * lin(dp, 2, 6) + WT.temp * (at < 18 ? lin(at, 18, 10) : lin(at, 32, 40));
  return { val: Math.round(pts), prelim: false };
}
function tripScoreK(start: string, n: number, today: string, data: Hourly) {
  let s = 0, pre = false;
  for (let i = 0; i < n; i++) { const x = dayScore(addDaysK(start, i), today, data); s += x.val; if (x.prelim) pre = true; }
  return { val: Math.round(s / n), prelim: pre };
}

async function scores(areaId: string) {
  const a = AREAS[areaId] ?? AREAS.hurghada, today = cairoToday(), data = await areaData(a);
  return { area: areaId, today, days: Array.from({ length: FORECAST_DAYS }, (_, i) => { const k = addDaysK(today, i); return { day: k, ...dayScore(k, today, data) }; }) };
}

type GoodTrip = { id: number; boat_name: string; start_date: string; days: number; seats_left: number; area: string; publisher_id: string; score: number };
async function goodday(dry: boolean) {
  const today = cairoToday();
  const { data: trips, error } = await db.from("trips_public")
    .select("id,boat_name,start_date,days,seats_left,area,publisher_id")
    .eq("status", "open").gte("start_date", addDaysK(today, 1)).lte("start_date", addDaysK(today, 7)).gt("seats_left", 0);
  if (error) throw new Error("trips: " + error.message);
  const cache: Record<string, Hourly | null> = {}, good: GoodTrip[] = [];
  for (const t of trips ?? []) {
    const id = AREAS[t.area] ? t.area : "hurghada";
    if (!(id in cache)) { try { cache[id] = await areaData(AREAS[id]); } catch (_) { cache[id] = null; } }
    if (!cache[id]) continue;
    const s = tripScoreK(t.start_date, t.days, today, cache[id]!);
    if (!s.prelim && s.val >= 80) good.push({ ...t, area: id, score: s.val });
  }
  good.sort((a, b) => b.score - a.score);
  const goodOut = good.map((g) => ({ trip: g.id, boat: g.boat_name, day: g.start_date, area: g.area, score: g.score, left: g.seats_left }));
  if (!good.length) return { today, open: trips?.length ?? 0, good: goodOut, users: 0, sent: 0 };

  const { data: subs } = await db.from("push_subs").select("id,user_id,endpoint,p256dh,auth,area").eq("good_days", true);
  const { data: done } = await db.from("good_day_sent").select("user_id,trip_id").in("trip_id", good.map((g) => g.id));
  const sentSet = new Set((done ?? []).map((r) => r.user_id + ":" + r.trip_id));
  const byUser = new Map<string, { subs: Sub[]; trips: Map<number, GoodTrip> }>();
  for (const s of subs ?? []) {
    for (const g of good) {
      if (g.area !== (AREAS[s.area] ? s.area : "hurghada") || g.publisher_id === s.user_id || sentSet.has(s.user_id + ":" + g.id)) continue;
      const u = byUser.get(s.user_id) ?? { subs: [], trips: new Map() };
      if (!u.subs.some((x) => x.id === s.id)) u.subs.push(s as Sub);
      u.trips.set(g.id, g); byUser.set(s.user_id, u);
    }
  }
  if (dry) return { today, open: trips?.length ?? 0, good: goodOut, users: byUser.size, sent: 0, dry: true };

  await vapid();
  let sent = 0;
  for (const [user, u] of byUser) {
    const ts = [...u.trips.values()].sort((a, b) => b.score - a.score), top = ts[0];
    const left = (n: number) => n + (n > 1 && n <= 10 ? " أماكن" : " مكان");
    const payload = ts.length === 1
      ? { title: "يوم ممتاز وفيه أماكن", body: `${top.boat_name} يوم ${dm(top.start_date)}: مؤشر الصيد ${top.score}% وفاضي ${left(top.seats_left)}.`, url: `./?trip=${top.id}#trips` }
      : { title: `${ts.length} رحلات في أيام ممتازة`, body: `أحسنها ${top.boat_name} يوم ${dm(top.start_date)} بمؤشر ${top.score}% وفاضي ${left(top.seats_left)}.`, url: "./#trips" };
    let ok = false;
    for (const s of u.subs) if (await send(s, payload)) { ok = true; sent++; }
    if (ok) await db.from("good_day_sent").upsert(ts.map((t) => ({ user_id: user, trip_id: t.id })), { onConflict: "user_id,trip_id", ignoreDuplicates: true });
  }
  return { today, open: trips?.length ?? 0, good: goodOut, users: byUser.size, sent };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const b = await req.json().catch(() => ({}));
    if (b.action === "key") return json({ key: await vapid() });
    if (b.action === "drain") return json(await drain());
    if (b.action === "morning") {
      const secret = await kv("cron_secret");
      if (!secret || req.headers.get("x-cron-secret") !== secret) return json({ error: "forbidden" }, 403);
      return json(await morning());
    }
    if (b.action === "scores") return json(await scores(String(b.area ?? "hurghada")));
    if (b.action === "goodday") {
      if (b.dry === true) return json(await goodday(true));
      const secret = await kv("cron_secret");
      if (!secret || req.headers.get("x-cron-secret") !== secret) return json({ error: "forbidden" }, 403);
      return json(await goodday(false));
    }
    return json({ error: "unknown action" }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});
