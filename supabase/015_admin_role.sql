-- فيش بوك: نوع حساب جديد "رئيس مركب" + الإدارة تغيّر نوع حساب أي مشترك.
-- بيتشغّل مرة واحدة من SQL Editor بعد 014.
--   1) admin_set_role()     الإدارة بس تغيّر نوع أي مشترك (صياد / منظم رحلات / صاحب مركب / رئيس مركب).
--                           كل مشترك لسه يقدر يغيّر نوع حسابه هو بنفسه زي الأول.
--   2) رئيس المركب تابع لصاحب مركب: صاحب المركب بيحدده على مركبه برقم موبايله أو إيميله (owner_set_captain)،
--      والرئيس بيشوف جدول المركب دي وحجوزاتها بس. مبينشرش رحلات ومبيعدّلش في المركب.
--      لو الرئيس غيّر نوع حسابه لحاجة تانية، بيتشال من على المركب لوحده.
-- ملحوظة: القيمة الجديدة 'captain' مكتوبة كنص (role::text) في الملف ده عشان الملف كله يشتغل مرة واحدة.

alter type user_role add value if not exists 'captain';

-- ============ 1) الإدارة تغيّر النوع ============
create or replace function admin_set_role(p_user uuid, p_role user_role) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  update profiles set role = p_role where id = p_user;
  if not found then raise exception 'no_such_user'; end if;
end $$;

-- ============ 2) رئيس المركب ============
alter table boats add column if not exists captain_id uuid references profiles on delete set null;
create index if not exists boats_captain on boats (captain_id);

-- صاحب المركب يحدد الرئيس برقم الموبايل أو الإيميل (حسابه لازم يكون نوعه رئيس مركب). نص فاضي = يشيله.
create or replace function owner_set_captain(p_boat bigint, p_contact text) returns json
language plpgsql security definer set search_path = public as $$
declare
  c text := lower(trim(coalesce(p_contact, '')));
  d text := regexp_replace(coalesce(p_contact, ''), '\D', '', 'g');
  v_id uuid; v_name text; v_phone text;
begin
  if not exists (select 1 from boats where id = p_boat and owner_id = auth.uid()) then raise exception 'not_owner'; end if;
  if c = '' then update boats set captain_id = null where id = p_boat; return null; end if;
  select p.id, p.name, p.phone into v_id, v_name, v_phone
  from profiles p join auth.users u on u.id = p.id
  where p.role::text = 'captain' and p.id <> auth.uid()
    and (lower(u.email) = c
         or (length(d) >= 10 and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = right(d, 10)))
  limit 1;
  if v_id is null then raise exception 'no_captain'; end if;
  update boats set captain_id = v_id where id = p_boat;
  return json_build_object('id', v_id, 'name', v_name, 'phone', v_phone);
end $$;

-- أسماء وأرقام الرؤسا لصاحب المركب، واسم ورقم صاحب المركب للرئيس
create or replace function boat_captains()
returns table (boat_id bigint, captain_id uuid, captain_name text, captain_phone text, owner_name text, owner_phone text)
language sql stable security definer set search_path = public as $$
  select b.id, c.id, c.name, c.phone, o.name, o.phone
  from boats b
  join profiles c on c.id = b.captain_id
  left join profiles o on o.id = b.owner_id
  where b.owner_id = auth.uid() or b.captain_id = auth.uid()
$$;

-- الرئيس يشوف حجوزات رحلات مركبه (نفس السياسة القديمة + الرئيس)
drop policy if exists bookings_read on bookings;
create policy bookings_read on bookings for select using (
  user_id = auth.uid()
  or exists (select 1 from trips t join boats b on b.id = t.boat_id
             where t.id = trip_id
               and (t.publisher_id = auth.uid() or b.owner_id = auth.uid() or b.captain_id = auth.uid())));

-- والأيام اللي صاحب المركب علّمها محجوزة (قراية بس)
drop policy if exists boat_blocks_captain on boat_blocks;
create policy boat_blocks_captain on boat_blocks for select using (
  exists (select 1 from boats b where b.id = boat_id and b.captain_id = auth.uid()));

-- لو الرئيس غيّر نوع حسابه، يتشال من على المراكب
create or replace function profiles_captain_unlink() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.role::text = 'captain' and new.role::text <> 'captain' then
    update boats set captain_id = null where captain_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists profiles_captain_unlink on profiles;
create trigger profiles_captain_unlink after update of role on profiles
  for each row execute function profiles_captain_unlink();

revoke execute on function admin_set_role(uuid, user_role), owner_set_captain(bigint, text), boat_captains() from public, anon;
grant  execute on function admin_set_role(uuid, user_role), owner_set_captain(bigint, text), boat_captains() to authenticated;
