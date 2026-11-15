// فيش بوك: إرسال الإشعارات (Web Push). Edge Function اسمها push، و Verify JWT مقفول عليها.
// الطلبات (POST JSON):
//   {action:"key"}     المفتاح العام اللي التطبيق بيشترك بيه (بيتولد أول مرة ويتحفظ في app_private)
//   {action:"drain"}   يبعت الإشعارات المستنية في notif_queue (المحتوى جاي من قاعدة البيانات، مش من اللي بينادي)
//   {action:"morning"} إشعار الصبح لكل المشتركين. محتاج الهيدر x-cron-secret (بينادي عليه pg_cron بس)
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
    return json({ error: "unknown action" }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});
