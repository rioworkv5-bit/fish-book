-- فيش بوك: ميزات الخريطة. بيتشغّل مرة واحدة من SQL Editor بعد الملفات اللي قبله.
-- 1) موقع الصيدة (خط عرض وطول) في سجل الصيد.
-- 2) خط سير الرحلة: الناشر بيرسمه، والحاجزين بيشوفوه وبيوصلهم إشعار.

-- ============ 1) موقع الصيدة ============
-- خاص زي باقي الصيدة: catches_own بتخلّي كل واحد يشوف صيداته بس.
alter table catches
  add column lat double precision check (lat between -90 and 90),
  add column lon double precision check (lon between -180 and 180);

-- ============ 2) خط سير الرحلة ============
-- جدول لوحده مش عمود في trips، عشان trips بيقراها الكل وخط السير للحاجزين بس.
create table trip_routes (
  trip_id    bigint primary key references trips on delete cascade,
  points     jsonb not null check (jsonb_typeof(points) = 'array' and jsonb_array_length(points) between 2 and 60),  -- [[lat, lon], ...]
  note       text not null default '' check (char_length(note) <= 300),
  updated_at timestamptz not null default now()
);
alter table trip_routes enable row level security;

-- يقراه: ناشر الرحلة، صاحب المركب، وأي حد حاجز فيها.
create policy trip_routes_read on trip_routes for select using (
  exists (select 1 from trips t join boats b on b.id = t.boat_id
          where t.id = trip_routes.trip_id and (t.publisher_id = auth.uid() or b.owner_id = auth.uid()))
  or exists (select 1 from bookings k
             where k.trip_id = trip_routes.trip_id and k.user_id = auth.uid() and k.status = 'booked'));
-- يكتبه ويعدّله: ناشر الرحلة بس.
create policy trip_routes_insert on trip_routes for insert with check (
  exists (select 1 from trips t where t.id = trip_routes.trip_id and t.publisher_id = auth.uid()));
create policy trip_routes_update on trip_routes for update
  using (exists (select 1 from trips t where t.id = trip_routes.trip_id and t.publisher_id = auth.uid()))
  with check (exists (select 1 from trips t where t.id = trip_routes.trip_id and t.publisher_id = auth.uid()));
create policy trip_routes_delete on trip_routes for delete
  using (exists (select 1 from trips t where t.id = trip_routes.trip_id and t.publisher_id = auth.uid()));
grant select, insert, update, delete on trip_routes to authenticated;

-- خط السير اتحفظ أو اتعدّل: إشعار لكل اللي حاجزين في الرحلة، بيفتح الخريطة على المسار.
create function notify_trip_route() returns trigger
language plpgsql security definer set search_path = public as $$
declare t trips; bname text;
begin
  if tg_op = 'UPDATE' and new.points = old.points and new.note = old.note then return new; end if;
  select * into t from trips where id = new.trip_id;
  select name into bname from boats where id = t.boat_id;
  insert into notif_queue (user_id, title, body, url)
  select distinct k.user_id,
         case when tg_op = 'INSERT' then 'خط سير رحلتك جاهز' else 'خط سير رحلتك اتعدّل' end,
         'رحلة ' || bname || ' يوم ' || to_char(t.start_date, 'DD/MM') || ': افتح الخريطة وشوف خط السير.',
         './?route=' || new.trip_id || '#map'
  from bookings k where k.trip_id = new.trip_id and k.status = 'booked' and k.user_id <> t.publisher_id;
  return new;
end $$;
create trigger trip_routes_notify after insert or update on trip_routes
  for each row execute function notify_trip_route();
