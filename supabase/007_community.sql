-- فيش بوك: المجتمع (منتدى المشتركين). بيتشغّل مرة واحدة من SQL Editor بعد الملفات اللي قبله.
-- بوستات بنص وصور (لحد 4) ولينك فيديو، تعليقات، إعجابات، وبلاغات.
-- القاعدة: الكل يقرا. الكتابة للي داخل بحسابه وعلى بياناته هو. المسح لصاحب المحتوى أو الإدارة.
-- الصور في Storage (bucket اسمه community)، والملف ده بيعمله وبيحط صلاحياته.
--
-- بعد التشغيل، عشان تخلّي حسابك إدارة (تشوف البلاغات وتمسح أي محتوى) شغّل السطر ده بإيميلك:
--   update profiles set is_admin = true where id = (select id from auth.users where email = 'YOUR_EMAIL');

-- ============ الإدارة ============
alter table profiles add column is_admin boolean not null default false;

-- المستخدم ميقدرش يخلّي نفسه إدارة (زي شارة التوثيق): بتتحط من SQL Editor بس
create function keep_admin() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null then new.is_admin := old.is_admin; end if;
  return new;
end $$;
create trigger profiles_keep_admin before update on profiles
  for each row execute function keep_admin();

create function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false)
$$;

-- ============ البوستات ============
create table posts (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references profiles on delete cascade default auth.uid(),
  kind       text not null default 'general' check (kind in ('catch', 'boat', 'question', 'general')),
  area       text not null default 'hurghada',          -- نفس id المناطق في AREAS
  body       text not null default '' check (char_length(body) <= 2000),
  photos     text[] not null default '{}' check (cardinality(photos) <= 4),   -- مسارات الملفات في bucket community
  video_url  text not null default '' check (
    video_url = '' or (char_length(video_url) <= 300 and video_url ~
      '^https://((www|m|vm|vt|web)\.)?(youtube\.com|youtu\.be|facebook\.com|fb\.watch|tiktok\.com|instagram\.com)/')),
  created_at timestamptz not null default now(),
  check (char_length(trim(body)) > 0 or cardinality(photos) > 0 or video_url <> '')
);
create index posts_feed on posts (id desc);
create index posts_user on posts (user_id, created_at);

-- الصور لازم تكون ملفات صاحب البوست نفسه، وحد أقصى 10 بوستات في 24 ساعة للحساب
create function posts_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare ph text;
begin
  if auth.uid() is null then return new; end if;        -- من SQL Editor: من غير قيود
  new.created_at := now();
  foreach ph in array new.photos loop
    if ph !~ ('^' || new.user_id::text || '/[A-Za-z0-9-]{8,60}\.jpg$') then raise exception 'bad_photo'; end if;
  end loop;
  if (select count(*) from posts where user_id = new.user_id and created_at > now() - interval '24 hours') >= 10 then
    raise exception 'post_limit';
  end if;
  return new;
end $$;
create trigger posts_guard before insert on posts
  for each row execute function posts_guard();

-- ============ التعليقات ============
create table comments (
  id         bigint generated always as identity primary key,
  post_id    bigint not null references posts on delete cascade,
  user_id    uuid not null references profiles on delete cascade default auth.uid(),
  body       text not null check (char_length(trim(body)) between 1 and 600),
  created_at timestamptz not null default now()
);
create index comments_post on comments (post_id, id);
create index comments_user on comments (user_id, created_at);

-- حد أقصى 100 تعليق في 24 ساعة للحساب
create function comments_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  new.created_at := now();
  if (select count(*) from comments where user_id = new.user_id and created_at > now() - interval '24 hours') >= 100 then
    raise exception 'comment_limit';
  end if;
  return new;
end $$;
create trigger comments_guard before insert on comments
  for each row execute function comments_guard();

-- ============ الإعجابات ============
create table post_likes (
  post_id    bigint not null references posts on delete cascade,
  user_id    uuid not null references profiles on delete cascade default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

-- ============ البلاغات ============
-- بلاغ واحد من كل حساب على البوست أو التعليق. بتتقري للإدارة بس.
create table reports (
  id         bigint generated always as identity primary key,
  post_id    bigint references posts on delete cascade,
  comment_id bigint references comments on delete cascade,
  user_id    uuid not null references profiles on delete cascade default auth.uid(),
  reason     text not null default '' check (char_length(reason) <= 200),
  created_at timestamptz not null default now(),
  check (num_nonnulls(post_id, comment_id) = 1),
  unique (user_id, post_id),
  unique (user_id, comment_id)
);

-- ============ الصلاحيات (RLS) ============
alter table posts      enable row level security;
alter table comments   enable row level security;
alter table post_likes enable row level security;
alter table reports    enable row level security;

-- مفيش تعديل للبوست أو التعليق بعد النشر (من غير policy للـ update)
create policy posts_read   on posts for select using (true);
create policy posts_insert on posts for insert with check (user_id = auth.uid());
create policy posts_delete on posts for delete using (user_id = auth.uid() or is_admin());

create policy comments_read   on comments for select using (true);
create policy comments_insert on comments for insert with check (user_id = auth.uid());
create policy comments_delete on comments for delete using (user_id = auth.uid() or is_admin());

create policy likes_own_read on post_likes for select using (user_id = auth.uid());
create policy likes_insert   on post_likes for insert with check (user_id = auth.uid());
create policy likes_delete   on post_likes for delete using (user_id = auth.uid());

create policy reports_insert on reports for insert with check (user_id = auth.uid());
create policy reports_admin  on reports for select using (is_admin());
create policy reports_close  on reports for delete using (is_admin());

-- ============ القراءة من التطبيق ============
-- البوست ومعاه اسم الناشر ودوره وشارة التوثيق، وعدد الإعجابات والتعليقات، وهل أنا عامل إعجاب
create view posts_public as
select p.id, p.user_id, p.kind, p.area, p.body, p.photos, p.video_url, p.created_at,
       f.name as author_name, f.role as author_role, f.verified as author_verified,
       (select count(*) from post_likes l where l.post_id = p.id) as like_count,
       (select count(*) from comments c where c.post_id = p.id) as comment_count,
       exists (select 1 from post_likes l where l.post_id = p.id and l.user_id = auth.uid()) as liked
from posts p
join profiles f on f.id = p.user_id;

create view comments_public as
select c.id, c.post_id, c.user_id, c.body, c.created_at,
       f.name as author_name, f.role as author_role, f.verified as author_verified
from comments c
join profiles f on f.id = c.user_id;

grant select on posts_public, comments_public to anon, authenticated;
grant select on posts, comments to anon, authenticated;
grant insert, delete on posts, comments to authenticated;
grant select, insert, delete on post_likes, reports to authenticated;

-- ============ تخزين الصور ============
-- bucket عام للقراءة. الملف الواحد لحد 1 ميجا و JPEG بس (التطبيق بيصغّر الصورة قبل الرفع).
-- كل حساب بيرفع في فولدر باسم رقمه، وبيمسح ملفاته هو. الإدارة تمسح أي ملف.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('community', 'community', true, 1048576, array['image/jpeg'])
on conflict (id) do nothing;

create policy community_read on storage.objects for select
  using (bucket_id = 'community');
create policy community_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'community' and (storage.foldername(name))[1] = auth.uid()::text);
create policy community_delete on storage.objects for delete to authenticated
  using (bucket_id = 'community' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
