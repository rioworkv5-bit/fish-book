-- فيش بوك: مواعيد الإشعارات. بيتشغّل مرة واحدة من SQL Editor بعد 003 وبعد نشر دالة push.
-- إشعار الصبح كل يوم 04:00 بتوقيت UTC (6 الصبح شتوي في مصر، 7 صيفي).
-- وتفريغ قائمة الإشعارات كل 10 دقايق كاحتياطي (التطبيق بيفرّغها فورًا بعد الحجز والإلغاء).
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

select cron.schedule('fishbook-morning', '0 4 * * *', $$
  select net.http_post(
    url := 'https://gcsgdfcufktrjsuhfqlf.supabase.co/functions/v1/push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', 'sb_publishable_4zpRHgNL9r20bpUxnOrFXg_zwg1_VY-',
      'x-cron-secret', (select v from public.app_private where k = 'cron_secret')),
    body := '{"action":"morning"}'::jsonb)
$$);

select cron.schedule('fishbook-drain', '*/10 * * * *', $$
  select net.http_post(
    url := 'https://gcsgdfcufktrjsuhfqlf.supabase.co/functions/v1/push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', 'sb_publishable_4zpRHgNL9r20bpUxnOrFXg_zwg1_VY-'),
    body := '{"action":"drain"}'::jsonb)
$$);
