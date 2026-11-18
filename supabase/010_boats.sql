-- فيش بوك: مواصفات وصور المراكب + أيام محجوزة من بره التطبيق. بيتشغّل مرة واحدة من SQL Editor بعد 007.
--   boats.specs   مواصفات المركب (الطول، العرض، عدد الكراسي، الدرجة، المميزات...) كـ JSON، فإضافة مواصفة جديدة مبتحتاجش ملف جديد
--   boats.about   وصف حر
--   boats.photos  مسارات الصور في bucket community (في فولدر اللي رفعها)
--   boat_blocks   أيام صاحب المركب معلّم إنها محجوزة من عنده (حجز بالتليفون مثلا). الملاحظة خاصة بيه.
--   boat_busy     نفس الأيام من غير الملاحظة، لأي حد عايز يعرف المركب مشغولة إمتى

alter table boats
  add column specs  jsonb  not null default '{}' check (jsonb_typeof(specs) = 'object' and length(specs::text) <= 2000),
  add column about  text   not null default ''   check (length(about) <= 800),
  add column photos text[] not null default '{}' check (cardinality(photos) <= 8);

-- الصورة لازم تكون ملف في فولدر اللي بيحفظ
create function boats_guard() returns trigger
language plpgsql as $$
declare p text;
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'UPDATE' and new.photos is not distinct from old.photos then return new; end if;
  foreach p in array new.photos loop
    if not (tg_op = 'UPDATE' and p = any (old.photos))
       and p !~ ('^' || auth.uid()::text || '/[A-Za-z0-9_-]{8,60}\.jpg$') then
      raise exception 'bad_photo';
    end if;
  end loop;
  return new;
end $$;
create trigger boats_guard before insert or update on boats
  for each row execute function boats_guard();

-- ============ أيام محجوزة من بره التطبيق ============
create table boat_blocks (
  id         bigint generated always as identity primary key,
  boat_id    bigint not null references boats on delete cascade,
  start_date date   not null,
  days       int    not null default 1 check (days between 1 and 60),
  note       text   not null default '' check (length(note) <= 80),
  created_by uuid   not null references profiles default auth.uid(),
  created_at timestamptz not null default now()
);
create index boat_blocks_boat on boat_blocks (boat_id, start_date);

-- مين بيدير المركب: صاحبها، ولو ملهاش صاحب يبقى اللي ضافها
create function manages_boat(p_boat bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from boats b where b.id = p_boat and coalesce(b.owner_id, b.created_by) = auth.uid())
$$;

-- اليوم ميتحجزش مرتين: لا حجز خارجي فوق رحلة منشورة، ولا فوق حجز خارجي تاني
create function boat_blocks_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.start_date < current_date - 1 then raise exception 'date_in_past'; end if;
  if exists (select 1 from trips t where t.boat_id = new.boat_id and t.status = 'open'
             and t.start_date <= new.start_date + new.days - 1
             and t.start_date + t.days - 1 >= new.start_date) then
    raise exception 'day_has_trip';
  end if;
  if exists (select 1 from boat_blocks k where k.boat_id = new.boat_id and k.id is distinct from new.id
             and k.start_date <= new.start_date + new.days - 1
             and k.start_date + k.days - 1 >= new.start_date) then
    raise exception 'day_already_blocked';
  end if;
  return new;
end $$;
create trigger boat_blocks_guard before insert or update on boat_blocks
  for each row execute function boat_blocks_guard();

-- ورحلة جديدة متتنشرش على يوم المركب محجوزة فيه
create function trips_block_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status <> 'open' then return new; end if;
  if tg_op = 'UPDATE' and new.boat_id = old.boat_id and new.start_date = old.start_date
     and new.days = old.days and old.status = 'open' then return new; end if;
  if exists (select 1 from boat_blocks k where k.boat_id = new.boat_id
             and k.start_date <= new.start_date + new.days - 1
             and k.start_date + k.days - 1 >= new.start_date) then
    raise exception 'boat_blocked';
  end if;
  return new;
end $$;
create trigger trips_block_guard before insert or update on trips
  for each row execute function trips_block_guard();

alter table boat_blocks enable row level security;
create policy boat_blocks_read   on boat_blocks for select using (manages_boat(boat_id));
create policy boat_blocks_insert on boat_blocks for insert with check (created_by = auth.uid() and manages_boat(boat_id));
create policy boat_blocks_delete on boat_blocks for delete using (manages_boat(boat_id));

create view boat_busy as
select id, boat_id, start_date, days from boat_blocks;

grant select, insert, delete on boat_blocks to authenticated;
grant select on boat_busy to anon, authenticated;
