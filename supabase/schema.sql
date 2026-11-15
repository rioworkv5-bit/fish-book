-- فيش بوك: قاعدة البيانات (Supabase / Postgres)
-- التشغيل: Supabase > SQL Editor > الصق الملف كله > Run. بيتشغل مرة واحدة على مشروع جديد.
-- القاعدة العامة: كل الجداول عليها RLS. أي حد يقرا الرحلات والمراكب والتقييمات،
-- والكتابة للي داخل بحسابه بس وعلى بياناته هو.

-- ============ الحسابات ============
create type user_role as enum ('angler', 'organizer', 'owner');   -- صياد، منظم رحلات، صاحب مركب

create table profiles (
  id         uuid primary key references auth.users on delete cascade,
  name       text not null default '',
  phone      text not null default '',
  role       user_role not null default 'angler',
  verified   boolean not null default false,        -- شارة منظم/صاحب مركب موثّق (بتتحط من الإدارة بس)
  created_at timestamptz not null default now()
);

-- صف لكل حساب جديد تلقائي
create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, name) values (new.id, coalesce(new.raw_user_meta_data->>'name', ''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

create function my_role() returns user_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid()
$$;

-- المستخدم ميقدرش يوثّق نفسه
create function keep_verified() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null then new.verified := old.verified; end if;
  return new;
end $$;
create trigger profiles_keep_verified before update on profiles
  for each row execute function keep_verified();

-- ============ المراكب ============
create table boats (
  id         bigint generated always as identity primary key,
  name       text not null check (length(trim(name)) between 2 and 60),
  capacity   int  not null check (capacity between 1 and 60),
  area       text not null default 'hurghada',       -- نفس id المناطق في AREAS
  owner_id   uuid references profiles,               -- فاضي لو المركب ضافها منظم
  created_by uuid not null references profiles default auth.uid(),
  created_at timestamptz not null default now()
);

-- ============ الرحلات ============
create table trips (
  id           bigint generated always as identity primary key,
  boat_id      bigint not null references boats,
  publisher_id uuid   not null references profiles default auth.uid(),
  start_date   date   not null,
  days         int    not null default 1 check (days between 1 and 60),
  seats_total  int    not null check (seats_total between 1 and 60),
  price_seat   int    not null check (price_seat >= 0),      -- جنيه للفرد
  price_whole  int    not null default 0 check (price_whole >= 0),  -- المركب كاملة، 0 = مش متاح
  area         text   not null default 'hurghada',
  status       text   not null default 'open' check (status in ('open', 'cancelled')),
  created_at   timestamptz not null default now()
);
create index trips_start_date on trips (start_date);

-- ============ الحجوزات ============
create table bookings (
  id         bigint generated always as identity primary key,
  trip_id    bigint not null references trips,
  user_id    uuid   not null references profiles,
  name       text   not null,
  phone      text   not null,
  seats      int    not null check (seats >= 1),
  whole      boolean not null default false,
  status     text   not null default 'booked' check (status in ('booked', 'cancelled')),
  created_at timestamptz not null default now()
);
create index bookings_trip on bookings (trip_id);
create index bookings_user on bookings (user_id);

-- الحجز بيتم من الدالة دي بس، عشان مكانين ميتحجزوش لاتنين في نفس اللحظة
create function book_trip(p_trip bigint, p_seats int, p_whole boolean, p_name text, p_phone text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare t trips; taken int; bid bigint;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select * into t from trips where id = p_trip for update;
  if not found or t.status <> 'open' or t.start_date < current_date then
    raise exception 'trip_not_available';
  end if;
  select coalesce(sum(seats), 0) into taken from bookings where trip_id = p_trip and status = 'booked';
  if p_whole then
    if taken > 0 or t.price_whole = 0 then raise exception 'whole_boat_not_available'; end if;
    p_seats := t.seats_total;
  elsif p_seats is null or p_seats < 1 or taken + p_seats > t.seats_total then
    raise exception 'not_enough_seats';
  end if;
  insert into bookings (trip_id, user_id, name, phone, seats, whole)
  values (p_trip, auth.uid(), trim(p_name), trim(p_phone), p_seats, p_whole)
  returning id into bid;
  return bid;
end $$;

-- الإلغاء: صاحب الحجز قبل يوم الرحلة (سياسة الإلغاء والعربون لسه هتتحدد)
create function cancel_booking(p_booking bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update bookings b set status = 'cancelled'
  from trips t
  where b.id = p_booking and t.id = b.trip_id
    and b.user_id = auth.uid() and b.status = 'booked' and t.start_date > current_date;
  if not found then raise exception 'cannot_cancel'; end if;
end $$;

-- الرحلات ومعاها الأماكن الفاضية واسم المركب والناشر (للقراءة من التطبيق)
create view trips_public as
select t.*, b.name as boat_name, b.capacity as boat_capacity, b.owner_id as boat_owner_id,
       p.name as publisher_name, p.role as publisher_role, p.verified as publisher_verified,
       t.seats_total - coalesce((select sum(k.seats) from bookings k
                                 where k.trip_id = t.id and k.status = 'booked'), 0) as seats_left
from trips t
join boats b on b.id = t.boat_id
join profiles p on p.id = t.publisher_id;

-- ============ التقييمات ============
-- تقييم واحد للمركب وواحد للناشر عن كل حجز، وبعد ما الرحلة تخلص
create table ratings (
  id         bigint generated always as identity primary key,
  booking_id bigint not null references bookings,
  target     text   not null check (target in ('boat', 'publisher')),
  stars      int    not null check (stars between 1 and 5),
  body       text   not null default '' check (length(body) <= 600),
  created_at timestamptz not null default now(),
  unique (booking_id, target)
);

create view ratings_public as
select r.id, r.target, r.stars, r.body, r.created_at,
       t.boat_id, t.publisher_id, p.name as reviewer_name
from ratings r
join bookings k on k.id = r.booking_id
join trips t on t.id = k.trip_id
join profiles p on p.id = k.user_id;

-- ============ سجل الصيد (خاص بصاحبه) ============
create table catches (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references profiles default auth.uid(),
  caught_on  date not null,
  caught_at  time,
  species    text not null,
  kg         numeric(6,1) not null check (kg > 0 and kg < 1000),
  bait       text not null default '',
  spot       text not null default '',        -- المكان: خاص، مبيتعرضش لحد
  trip_id    bigint references trips,
  area       text not null default 'hurghada',
  created_at timestamptz not null default now()
);
create index catches_user on catches (user_id, caught_on);

-- ============ الصلاحيات (RLS) ============
alter table profiles enable row level security;
alter table boats    enable row level security;
alter table trips    enable row level security;
alter table bookings enable row level security;
alter table ratings  enable row level security;
alter table catches  enable row level security;

-- الحساب: كل واحد يشوف ويعدل صفه بس (الاسم بيظهر للناس من الـ views)
create policy profiles_own_select on profiles for select using (id = auth.uid());
create policy profiles_own_update on profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- المراكب: الكل يقرا. المنظم وصاحب المركب يضيفوا. التعديل لصاحبها أو اللي ضافها.
create policy boats_read   on boats for select using (true);
create policy boats_insert on boats for insert with check (
  created_by = auth.uid() and my_role() in ('organizer', 'owner')
  and (owner_id is null or (owner_id = auth.uid() and my_role() = 'owner')));
create policy boats_update on boats for update
  using (coalesce(owner_id, created_by) = auth.uid())
  with check (coalesce(owner_id, created_by) = auth.uid());

-- الرحلات: الكل يقرا. صاحب المركب ينشر على مراكبه، والمنظم على أي مركب
-- (موافقة صاحب المركب على رحلات المنظمين لسه هتتضاف).
create policy trips_read   on trips for select using (true);
create policy trips_insert on trips for insert with check (
  publisher_id = auth.uid() and (
    my_role() = 'organizer'
    or (my_role() = 'owner' and exists (select 1 from boats b where b.id = boat_id and b.owner_id = auth.uid()))));
create policy trips_update on trips for update
  using (publisher_id = auth.uid()) with check (publisher_id = auth.uid());

-- الحجوزات: يشوفها صاحب الحجز، وناشر الرحلة، وصاحب المركب. الإضافة والإلغاء من الدوال بس.
create policy bookings_read on bookings for select using (
  user_id = auth.uid()
  or exists (select 1 from trips t join boats b on b.id = t.boat_id
             where t.id = trip_id and (t.publisher_id = auth.uid() or b.owner_id = auth.uid())));

-- التقييمات: الكل يقرا. يكتب اللي حجز وطلع الرحلة فعلًا، وبعد ما تخلص.
create policy ratings_read   on ratings for select using (true);
create policy ratings_insert on ratings for insert with check (
  exists (select 1 from bookings k join trips t on t.id = k.trip_id
          where k.id = booking_id and k.user_id = auth.uid() and k.status = 'booked'
            and t.start_date + t.days <= current_date));

-- سجل الصيد: صاحبه بس
create policy catches_own on catches for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- صلاحيات الدوال والـ views
revoke execute on function book_trip(bigint, int, boolean, text, text) from public, anon;
revoke execute on function cancel_booking(bigint) from public, anon;
grant  execute on function book_trip(bigint, int, boolean, text, text) to authenticated;
grant  execute on function cancel_booking(bigint) to authenticated;
grant  select on trips_public, ratings_public to anon, authenticated;
