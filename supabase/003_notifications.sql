-- فيش بوك: الإشعارات (Web Push). بيتشغّل مرة واحدة من SQL Editor بعد 002.
-- push_subs: اشتراك كل جهاز. notif_queue: إشعارات مستنية تتبعت. app_private: مفاتيح السيرفر.
-- الإرسال نفسه في Edge Function اسمها push (supabase/functions/push/index.ts).

-- قيم خاصة بالسيرفر. RLS شغال ومن غير أي policy، فمحدش يقراها غير السيرفر نفسه.
create table app_private (k text primary key, v text not null);
alter table app_private enable row level security;
insert into app_private values ('cron_secret', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''));

create table push_subs (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references profiles on delete cascade,
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  morning    boolean not null default true,       -- إشعار الصبح
  area       text not null default 'hurghada',
  area_name  text not null default 'الغردقة',
  lat        numeric not null default 27.26,
  lon        numeric not null default 33.83,
  created_at timestamptz not null default now()
);
create index push_subs_user on push_subs (user_id);
alter table push_subs enable row level security;
create policy push_subs_own_read on push_subs for select using (user_id = auth.uid());

-- الجهاز الواحد اشتراكه بيتنقل للحساب اللي داخل عليه دلوقتي
create function save_push_sub(p_endpoint text, p_p256dh text, p_auth text, p_area text, p_area_name text, p_lat numeric, p_lon numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  insert into push_subs (user_id, endpoint, p256dh, auth, area, area_name, lat, lon)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, p_area, p_area_name, p_lat, p_lon)
  on conflict (endpoint) do update
    set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth,
        area = excluded.area, area_name = excluded.area_name, lat = excluded.lat, lon = excluded.lon;
end $$;

-- اللي معاه عنوان الاشتراك (الجهاز نفسه) هو اللي يقدر يلغيه
create function drop_push_sub(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from push_subs where endpoint = p_endpoint
$$;

create table notif_queue (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references profiles on delete cascade,
  title      text not null,
  body       text not null,
  url        text not null default './',
  created_at timestamptz not null default now()
);
alter table notif_queue enable row level security;   -- من غير policy: السيرفر بس

-- حجز جديد أو حجز اتلغى: إشعار لناشر الرحلة
create function notify_booking() returns trigger
language plpgsql security definer set search_path = public as $$
declare t trips; bname text; what text;
begin
  select * into t from trips where id = new.trip_id;
  select name into bname from boats where id = t.boat_id;
  if tg_op = 'INSERT' then what := 'حجز جديد';
  elsif old.status = 'booked' and new.status = 'cancelled' then what := 'حجز اتلغى';
  else return new;
  end if;
  if t.publisher_id <> new.user_id then
    insert into notif_queue (user_id, title, body, url)
    values (t.publisher_id, what,
            new.name || ' · ' || case when new.whole then 'المركب كاملة' else new.seats || ' مكان' end
              || ' · ' || bname || ' يوم ' || to_char(t.start_date, 'DD/MM'),
            './#manage');
  end if;
  return new;
end $$;
create trigger bookings_notify after insert or update on bookings
  for each row execute function notify_booking();

-- رحلة اتلغت: إشعار لكل اللي حاجزين فيها
create function notify_trip_cancel() returns trigger
language plpgsql security definer set search_path = public as $$
declare bname text;
begin
  if old.status = 'open' and new.status = 'cancelled' then
    select name into bname from boats where id = new.boat_id;
    insert into notif_queue (user_id, title, body, url)
    select distinct k.user_id, 'الرحلة اتلغت',
           'رحلة ' || bname || ' يوم ' || to_char(new.start_date, 'DD/MM') || ' اتلغت من الناشر.', './#log'
    from bookings k where k.trip_id = new.id and k.status = 'booked' and k.user_id <> new.publisher_id;
  end if;
  return new;
end $$;
create trigger trips_notify after update on trips
  for each row execute function notify_trip_cancel();

revoke execute on function save_push_sub(text, text, text, text, text, numeric, numeric) from public, anon;
grant  execute on function save_push_sub(text, text, text, text, text, numeric, numeric) to authenticated;
grant  execute on function drop_push_sub(text) to anon, authenticated;
