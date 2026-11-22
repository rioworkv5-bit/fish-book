-- فيش بوك: حساب الشريك المؤسس. بيتشغّل مرة واحدة من SQL Editor بعد 009 (ومفيش مشكلة لو اتشغّل تاني).
--
-- 1) profiles.is_partner: شارة "شريك مؤسس". الإدارة بس اللي تحطها أو تشيلها (من لوحة المالك في التطبيق).
-- 2) partner_tasks: المهام والأسئلة اللي بتظهر للشركاء. الإدارة بتضيف وتعدّل من Table Editor من غير ما نعدّل التطبيق.
--      title: عنوان المهمة، hint: سطر شرح، active: لو false المهمة بتستخبى، sort: الترتيب.
--      fields: الخانات، كل خانة {"k":"اسم داخلي","label":"اللي يظهر","type":"text|long|num|select|area|date","opts":["..."],"req":true}
-- 3) partner_answers: إجابات الشركاء. الشريك يضيف ويشوف إجاباته هو بس، والإدارة تشوف الكل.
-- 4) admin_set_partner / admin_partners / admin_partner_answers: للإدارة بس.
--    النقط: كل مهمة ليها points (10 لو متكتبش). نقط الشريك = مجموع نقط إجاباته.
--    partner_board(): ترتيب الشركاء بالنقط، بيشوفه الشركاء والإدارة بس.
--    الشريك يبعت 30 إجابة في اليوم بالكتير.
-- 5) posts_public و comments_public: زاد عليهم author_partner في الآخر عشان الشارة تظهر في المجتمع.
-- 6) مراقبة المجتمع: الشريك المؤسس مراقب. يقدر يخفي بوست أو تعليق مخالف (mod_hide) ويشوف البلاغات ويقفلها.
--    الإخفاء مش مسح: المحتوى بيختفي من المجتمع وبيفضل محفوظ، والإدارة بس تشوفه (admin_hidden) وترجّعه أو تمسحه.
--    الشريك ميقدرش يخفي محتوى الإدارة ولا يرجّع حاجة مخفية.
-- 7) الرسائل الصوتية: الشريك اللي مبيكتبش يجاوب على المهمة بتسجيل صوتي. الملف في bucket خاص (partner-voice)
--    جوه فولدر الشريك، ومحدش يسمعه غير صاحبه والإدارة. مساره بيتحفظ في partner_answers.answers.voice.

alter table profiles add column if not exists is_partner boolean not null default false;

-- المستخدم ميقدرش يخلّي نفسه شريك
create or replace function keep_partner() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null and not is_admin() then new.is_partner := old.is_partner; end if;
  return new;
end $$;
drop trigger if exists profiles_keep_partner on profiles;
create trigger profiles_keep_partner before update on profiles
  for each row execute function keep_partner();

create or replace function is_partner() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_partner from profiles where id = auth.uid()), false)
$$;

create table if not exists partner_tasks (
  id         bigserial primary key,
  title      text not null check (length(title) between 3 and 80),
  hint       text not null default '' check (length(hint) <= 300),
  fields     jsonb not null check (jsonb_typeof(fields) = 'array'),
  active     boolean not null default true,
  sort       int not null default 100,
  created_at timestamptz not null default now()
);
alter table partner_tasks add column if not exists points int not null default 10 check (points between 0 and 100);
alter table partner_tasks enable row level security;
drop policy if exists partner_tasks_read on partner_tasks;
create policy partner_tasks_read on partner_tasks for select using (is_partner() or is_admin());
drop policy if exists partner_tasks_admin on partner_tasks;
create policy partner_tasks_admin on partner_tasks for all using (is_admin()) with check (is_admin());

create table if not exists partner_answers (
  id         bigserial primary key,
  task_id    bigint not null references partner_tasks on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  answers    jsonb not null check (jsonb_typeof(answers) = 'object' and pg_column_size(answers) < 4000),
  created_at timestamptz not null default now()
);
create index if not exists partner_answers_user on partner_answers (user_id, id desc);
alter table partner_answers enable row level security;
drop policy if exists partner_answers_insert on partner_answers;
create policy partner_answers_insert on partner_answers for insert
  with check (user_id = auth.uid() and (is_partner() or is_admin())
    and (select count(*) from partner_answers a
         where a.user_id = auth.uid() and a.created_at > now() - interval '1 day') < 30);
drop policy if exists partner_answers_read on partner_answers;
create policy partner_answers_read on partner_answers for select using (user_id = auth.uid() or is_admin());
drop policy if exists partner_answers_admin_del on partner_answers;
create policy partner_answers_admin_del on partner_answers for delete using (is_admin());

grant select on partner_tasks to authenticated;
grant select, insert, delete on partner_answers to authenticated;
grant usage, select on sequence partner_answers_id_seq to authenticated;

create or replace function admin_set_partner(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  update profiles set is_partner = p_on where id = p_user;
  if not found then raise exception 'no_such_user'; end if;
end $$;

-- الشركاء وعدد مساهمات ونقط كل واحد
drop function if exists admin_partners();
create function admin_partners()
returns table (id uuid, answers bigint, points bigint)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
  select p.id, (select count(*) from partner_answers a where a.user_id = p.id),
         (select coalesce(sum(t.points), 0) from partner_answers a join partner_tasks t on t.id = a.task_id where a.user_id = p.id)
  from profiles p where p.is_partner;
end $$;

-- ترتيب الشركاء بالنقط (للشركاء والإدارة بس)
create or replace function partner_board()
returns table (name text, points bigint, answers bigint, me boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (is_partner() or is_admin()) then raise exception 'not_partner'; end if;
  return query
  select p.name,
         (select coalesce(sum(t.points), 0) from partner_answers a join partner_tasks t on t.id = a.task_id where a.user_id = p.id) as pts,
         (select count(*) from partner_answers a where a.user_id = p.id),
         p.id = auth.uid()
  from profiles p where p.is_partner
  order by pts desc, p.created_at
  limit 50;
end $$;
revoke execute on function partner_board() from public, anon;
grant  execute on function partner_board() to authenticated;

-- آخر إجابات الشركاء باسم الشريك وعنوان المهمة
create or replace function admin_partner_answers(p_limit int default 100)
returns table (id bigint, created_at timestamptz, user_name text, user_phone text, task_title text, fields jsonb, answers jsonb)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
  select a.id, a.created_at, p.name, p.phone, t.title, t.fields, a.answers
  from partner_answers a
  join profiles p on p.id = a.user_id
  join partner_tasks t on t.id = a.task_id
  order by a.id desc
  limit least(greatest(p_limit, 1), 500);
end $$;

revoke execute on function admin_set_partner(uuid, boolean), admin_partners(), admin_partner_answers(int) from public, anon;
grant  execute on function admin_set_partner(uuid, boolean), admin_partners(), admin_partner_answers(int) to authenticated;

-- ============ مراقبة المجتمع ============
alter table posts    add column if not exists hidden_at timestamptz;
alter table posts    add column if not exists hidden_by uuid references profiles on delete set null;
alter table comments add column if not exists hidden_at timestamptz;
alter table comments add column if not exists hidden_by uuid references profiles on delete set null;

create or replace function is_mod() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin or is_partner from profiles where id = auth.uid()), false)
$$;

-- واحد بس من p_post و p_comment. p_on = true يخفي، false يرجّع (للإدارة بس)
create or replace function mod_hide(p_post bigint, p_comment bigint, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_owner uuid;
begin
  if not is_mod() then raise exception 'not_mod'; end if;
  if not p_on and not is_admin() then raise exception 'not_admin'; end if;
  if num_nonnulls(p_post, p_comment) <> 1 then raise exception 'bad_target'; end if;
  if p_post is not null then select user_id into v_owner from posts where id = p_post;
  else select user_id into v_owner from comments where id = p_comment; end if;
  if v_owner is null then raise exception 'no_such_item'; end if;
  if not is_admin() and exists (select 1 from profiles where id = v_owner and is_admin) then raise exception 'not_admin'; end if;
  if p_post is not null then
    update posts set hidden_at = case when p_on then now() end, hidden_by = case when p_on then auth.uid() end where id = p_post;
    if p_on then delete from reports where post_id = p_post; end if;
  else
    update comments set hidden_at = case when p_on then now() end, hidden_by = case when p_on then auth.uid() end where id = p_comment;
    if p_on then delete from reports where comment_id = p_comment; end if;
  end if;
end $$;

-- المحتوى المخفي ومين اللي خفاه (للإدارة بس)
create or replace function admin_hidden()
returns table (kind text, id bigint, body text, author_name text, hidden_by_name text, hidden_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query
  select x.kind, x.id, x.body, a.name, h.name, x.hidden_at from (
    select 'post'::text as kind, p.id, p.body, p.user_id, p.hidden_by, p.hidden_at from posts p where p.hidden_at is not null
    union all
    select 'comment'::text, c.id, c.body, c.user_id, c.hidden_by, c.hidden_at from comments c where c.hidden_at is not null
  ) x
  left join profiles a on a.id = x.user_id
  left join profiles h on h.id = x.hidden_by
  order by x.hidden_at desc
  limit 200;
end $$;

revoke execute on function mod_hide(bigint, bigint, boolean), admin_hidden() from public, anon;
grant  execute on function mod_hide(bigint, bigint, boolean), admin_hidden() to authenticated;

-- البلاغات: المراقب يشوفها ويقفلها زي الإدارة
drop policy if exists reports_admin on reports;
create policy reports_admin on reports for select using (is_mod());
drop policy if exists reports_close on reports;
create policy reports_close on reports for delete using (is_mod());

-- نفس الـ views بتاعة 008 ومعاها شارة الشريك في الآخر، ومن غير المحتوى المخفي
create or replace view posts_public as
select p.id, p.user_id, p.kind, p.area, p.body, p.photos, p.video_url, p.created_at,
       f.name as author_name, f.role as author_role, f.verified as author_verified,
       (select count(*) from post_likes l where l.post_id = p.id) as like_count,
       (select count(*) from comments c where c.post_id = p.id and c.hidden_at is null) as comment_count,
       exists (select 1 from post_likes l where l.post_id = p.id and l.user_id = auth.uid()) as liked,
       f.avatar as author_avatar,
       f.is_partner as author_partner
from posts p
join profiles f on f.id = p.user_id
where p.hidden_at is null;

create or replace view comments_public as
select c.id, c.post_id, c.user_id, c.body, c.created_at,
       f.name as author_name, f.role as author_role, f.verified as author_verified,
       f.avatar as author_avatar,
       f.is_partner as author_partner
from comments c
join profiles f on f.id = c.user_id
where c.hidden_at is null;

-- المهام الأساسية (بتتضاف مرة واحدة بس، لو الجدول فاضي)
insert into partner_tasks (title, hint, fields, sort, points)
select * from (values
  ('تقرير بعد الرحلة', 'بعد كل رحلة: دقيقة واحدة تقولنا اليوم كان عامل إزاي. ده اللي بيظبط مؤشر الصيد.',
   '[{"k":"date","label":"يوم الرحلة","type":"date","req":true},
     {"k":"area","label":"المنطقة","type":"area","req":true},
     {"k":"day","label":"الصيد كان عامل إزاي؟","type":"select","opts":["حلو جداً","كويس","متوسط","ضعيف"],"req":true},
     {"k":"sea","label":"حالة البحر","type":"select","opts":["هادي","متوسط","عالي"]},
     {"k":"fish","label":"أنواع السمك اللي طلعت","type":"text"},
     {"k":"kg","label":"الكمية بالتقريب (كجم)","type":"num"}]'::jsonb, 10, 10),
  ('مكان جديد للخريطة', 'مرسى أو شعب أو منطقة خطر الناس لازم تعرفها. متكتبش طرحاتك الخاصة، دي بتفضل سر ليك.',
   '[{"k":"name","label":"اسم المكان","type":"text","req":true},
     {"k":"kind","label":"نوع المكان","type":"select","opts":["مرسى","شعب","منطقة صيد معروفة","مكان خطر","ممنوع فيه الصيد"],"req":true},
     {"k":"area","label":"أقرب منطقة","type":"area"},
     {"k":"pos","label":"الإحداثيات أو وصف المكان","type":"text","req":true},
     {"k":"depth","label":"العمق بالمتر","type":"num"},
     {"k":"note","label":"ملاحظة","type":"long"}]'::jsonb, 20, 20),
  ('موسم سمكة', 'نوع سمك تعرف موسمه كويس: امتى بييجي وبيتصاد بإيه.',
   '[{"k":"fish","label":"اسم السمكة","type":"text","req":true},
     {"k":"months","label":"أحسن شهور","type":"text","req":true},
     {"k":"bait","label":"الطُعم أو الطريقة","type":"text"},
     {"k":"depth","label":"العمق بالمتر","type":"num"}]'::jsonb, 30, 15),
  ('أسعار الرحلات', 'سعر رحلة اتعملت قريب، عشان نعرف السوق ماشي إزاي.',
   '[{"k":"days","label":"مدة الرحلة بالأيام","type":"num","req":true},
     {"k":"seat","label":"سعر الفرد (جنيه)","type":"num"},
     {"k":"full","label":"سعر المركب كاملة (جنيه)","type":"num"},
     {"k":"note","label":"السعر شامل إيه؟","type":"text"}]'::jsonb, 40, 10),
  ('سمكة خطرة أو ممنوعة', 'سمكة سامة أو شوكها مؤذي أو ممنوع صيدها، عشان ننبّه الصيادين.',
   '[{"k":"fish","label":"اسم السمكة","type":"text","req":true},
     {"k":"why","label":"الخطر","type":"select","opts":["سامة لو اتاكلت","شوكها سام","بتعض أو بتجرح","ممنوع صيدها","حجم صغير ممنوع"],"req":true},
     {"k":"note","label":"تتصرف إزاي لو حصل؟","type":"long"}]'::jsonb, 50, 10),
  ('جهاز السونار على مركبك', 'عشان نعرف نربط التطبيق بالأجهزة الموجودة فعلاً.',
   '[{"k":"brand","label":"الماركة (Garmin, Lowrance...)","type":"text","req":true},
     {"k":"model","label":"الموديل","type":"text"},
     {"k":"wifi","label":"فيه واي فاي أو بلوتوث؟","type":"select","opts":["أيوه","لأ","مش عارف"]}]'::jsonb, 60, 15),
  ('اقتراح أو مشكلة', 'ميزة ناقصة، حاجة مش مفهومة، أو غلطة شفتها في التطبيق.',
   '[{"k":"kind","label":"النوع","type":"select","opts":["ميزة جديدة","مشكلة في التطبيق","معلومة غلط"],"req":true},
     {"k":"text","label":"اكتب بالتفصيل","type":"long","req":true}]'::jsonb, 70, 5)
) as v(title, hint, fields, sort, points)
where not exists (select 1 from partner_tasks);

-- ============ الرسائل الصوتية ============
-- bucket خاص (مش عام). الملف لحد 3 ميجا وصوت بس.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('partner-voice', 'partner-voice', false, 3145728, array['audio/webm', 'audio/mp4', 'audio/ogg', 'audio/mpeg', 'audio/aac'])
on conflict (id) do nothing;

drop policy if exists partner_voice_read on storage.objects;
create policy partner_voice_read on storage.objects for select to authenticated
  using (bucket_id = 'partner-voice' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
drop policy if exists partner_voice_upload on storage.objects;
create policy partner_voice_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'partner-voice' and (storage.foldername(name))[1] = auth.uid()::text
              and (public.is_partner() or public.is_admin()));
drop policy if exists partner_voice_delete on storage.objects;
create policy partner_voice_delete on storage.objects for delete to authenticated
  using (bucket_id = 'partner-voice' and public.is_admin());
