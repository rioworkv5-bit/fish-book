-- فيش بوك: صورة الحساب. بيتشغّل مرة واحدة من SQL Editor بعد 007.
-- كل عضو يحط صورة لحسابه، وبتظهر جنب اسمه على بوستاته وتعليقاته في المجتمع.
-- الصورة ملف في نفس bucket المجتمع (community) جوه فولدر العضو، والعمود ده فيه مسارها.

alter table profiles add column avatar text not null default ''
  check (avatar = '' or avatar ~ '^[0-9a-f-]{36}/[A-Za-z0-9-]{8,60}\.jpg$');

-- الصورة لازم تكون ملف في فولدر صاحب الحساب نفسه
create function profiles_avatar_guard() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null and new.avatar <> '' and new.avatar not like auth.uid()::text || '/%' then
    raise exception 'bad_photo';
  end if;
  return new;
end $$;
create trigger profiles_avatar_guard before update on profiles
  for each row execute function profiles_avatar_guard();

-- نفس الـ views بتاعة 007 ومعاها صورة الناشر في الآخر
create or replace view posts_public as
select p.id, p.user_id, p.kind, p.area, p.body, p.photos, p.video_url, p.created_at,
       f.name as author_name, f.role as author_role, f.verified as author_verified,
       (select count(*) from post_likes l where l.post_id = p.id) as like_count,
       (select count(*) from comments c where c.post_id = p.id) as comment_count,
       exists (select 1 from post_likes l where l.post_id = p.id and l.user_id = auth.uid()) as liked,
       f.avatar as author_avatar
from posts p
join profiles f on f.id = p.user_id;

create or replace view comments_public as
select c.id, c.post_id, c.user_id, c.body, c.created_at,
       f.name as author_name, f.role as author_role, f.verified as author_verified,
       f.avatar as author_avatar
from comments c
join profiles f on f.id = c.user_id;
