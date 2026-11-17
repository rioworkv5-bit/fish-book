-- فيش بوك: تنبيه "يوم كويس وفيه أماكن". بيتشغّل مرة واحدة من SQL Editor بعد 004.
-- كل يوم دالة push (action: goodday) بتحسب مؤشر الصيد لكل رحلة مفتوحة في الأيام السبعة الجاية،
-- ولو 80% أو أكتر وفيها أماكن، بتبعت تنبيه للمشتركين في نفس المنطقة. كل رحلة بتتبعت لكل واحد مرة واحدة.

alter table push_subs add column good_days boolean not null default true;   -- تنبيه الأيام الكويسة

create table good_day_sent (
  user_id uuid   not null references profiles on delete cascade,
  trip_id bigint not null references trips on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (user_id, trip_id)
);
alter table good_day_sent enable row level security;   -- من غير policy: السيرفر بس

-- كل يوم 15:00 UTC (5 العصر شتوي في مصر، 6 صيفي)
select cron.schedule('fishbook-goodday', '0 15 * * *', $$
  select net.http_post(
    url := 'https://gcsgdfcufktrjsuhfqlf.supabase.co/functions/v1/push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', 'sb_publishable_4zpRHgNL9r20bpUxnOrFXg_zwg1_VY-',
      'x-cron-secret', (select v from public.app_private where k = 'cron_secret')),
    body := '{"action":"goodday"}'::jsonb,
    timeout_milliseconds := 60000)
$$);
