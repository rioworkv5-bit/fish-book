-- فيش بوك: لوحة مالك التطبيق. بيتشغّل مرة واحدة من SQL Editor بعد 007.
-- بيانات الأعضاء مقفولة: كل واحد بيشوف حسابه بس. الدوال دي بتفتحها للحساب اللي is_admin بتاعه true بس،
-- وأي حد تاني يناديها بياخد not_admin.
--   admin_stats()         أرقام التطبيق
--   admin_users()         قايمة المشتركين (الاسم، الموبايل، الإيميل، النوع، وعدد رحلاته وحجوزاته وبوستاته)
--   admin_trips()         كل الرحلات من آخر 30 يوم ولقدام، بناشرها وعدد المحجوز
--   admin_set_verified()  يحط أو يشيل شارة "موثّق" عن حساب

-- شارة التوثيق: المستخدم العادي ميقدرش يغيّرها، والإدارة تقدر
create or replace function keep_verified() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null and not is_admin() then new.verified := old.verified; end if;
  return new;
end $$;

create function admin_stats() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return json_build_object(
    'users',          (select count(*) from profiles),
    'anglers',        (select count(*) from profiles where role = 'angler'),
    'organizers',     (select count(*) from profiles where role = 'organizer'),
    'owners',         (select count(*) from profiles where role = 'owner'),
    'verified',       (select count(*) from profiles where verified),
    'new_today',      (select count(*) from profiles
                       where (created_at at time zone 'Africa/Cairo')::date = (now() at time zone 'Africa/Cairo')::date),
    'new_week',       (select count(*) from profiles where created_at > now() - interval '7 days'),
    'boats',          (select count(*) from boats),
    'trips_upcoming', (select count(*) from trips where status = 'open' and start_date >= current_date),
    'trips_total',    (select count(*) from trips),
    'bookings',       (select count(*) from bookings where status = 'booked'),
    'seats',          (select coalesce(sum(seats), 0) from bookings where status = 'booked'),
    'bookings_week',  (select count(*) from bookings where status = 'booked' and created_at > now() - interval '7 days'),
    'posts',          (select count(*) from posts),
    'comments',       (select count(*) from comments),
    'catches',        (select count(*) from catches),
    'reports',        (select count(*) from reports));
end $$;

create function admin_users(p_limit int default 500, p_offset int default 0)
returns table (id uuid, name text, phone text, email text, role user_role, verified boolean, is_admin boolean,
               created_at timestamptz, last_seen timestamptz, trips bigint, bookings bigint, posts bigint)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
  select p.id, p.name, p.phone, u.email::text, p.role, p.verified, p.is_admin, p.created_at, u.last_sign_in_at,
         (select count(*) from trips t where t.publisher_id = p.id),
         (select count(*) from bookings k where k.user_id = p.id and k.status = 'booked'),
         (select count(*) from posts o where o.user_id = p.id)
  from profiles p
  join auth.users u on u.id = p.id
  order by p.created_at desc
  limit least(greatest(p_limit, 1), 1000) offset greatest(p_offset, 0);
end $$;

create function admin_trips()
returns table (id bigint, start_date date, days int, status text, boat_name text,
               publisher_name text, publisher_phone text, publisher_role user_role,
               seats_total int, seats_booked bigint, price_seat int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
  select t.id, t.start_date, t.days, t.status, b.name, p.name, p.phone, p.role, t.seats_total,
         (select coalesce(sum(k.seats), 0) from bookings k where k.trip_id = t.id and k.status = 'booked'),
         t.price_seat
  from trips t
  join boats b on b.id = t.boat_id
  join profiles p on p.id = t.publisher_id
  where t.start_date >= current_date - 30
  order by t.start_date
  limit 300;
end $$;

create function admin_set_verified(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  update profiles set verified = p_on where id = p_user;
  if not found then raise exception 'no_such_user'; end if;
end $$;

revoke execute on function admin_stats(), admin_users(int, int), admin_trips(), admin_set_verified(uuid, boolean) from public, anon;
grant  execute on function admin_stats(), admin_users(int, int), admin_trips(), admin_set_verified(uuid, boolean) to authenticated;
