-- فيش بوك: ياسر بالإجابات الجاهزة. بيتشغّل مرة واحدة من SQL Editor.
-- الأسئلة والأجوبة الأساسية جوه التطبيق نفسه (ملف yasser-faq.js)، والجدولين دول للزيادة:
--
-- 1) yasser_faq: أسئلة وأجوبة زيادة الأدمن بيضيفها من Table Editor من غير ما نعدّل التطبيق.
--    q: السؤال، a: الإجابة (سطر جديد = سطر جديد، و**كلمة** = خط تقيل)،
--    alt: طرق تانية للسؤال، kw: كلمات مهمة، active: لو false السؤال بيستخبى.
--    أي حد يقدر يقرا، والتعديل للأدمن بس.
--
-- 2) yasser_missing: الأسئلة اللي ياسر ملقاش لها إجابة. أي حد يقدر يضيف سؤال (300 حرف بالكتير)،
--    والأدمن بس اللي بيقرا ويمسح. من هنا تعرف الناس بتسأل عن إيه وتضيف إجابته في yasser_faq.

create table if not exists yasser_faq (
  id         bigserial primary key,
  q          text not null check (length(q) between 3 and 200),
  a          text not null check (length(a) between 1 and 3000),
  alt        text[] not null default '{}',
  kw         text[] not null default '{}',
  active     boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table yasser_faq enable row level security;
drop policy if exists yasser_faq_read on yasser_faq;
create policy yasser_faq_read on yasser_faq for select using (true);
drop policy if exists yasser_faq_admin on yasser_faq;
create policy yasser_faq_admin on yasser_faq for all using (is_admin()) with check (is_admin());

create table if not exists yasser_missing (
  id         bigserial primary key,
  question   text not null check (length(question) between 1 and 300),
  user_id    uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table yasser_missing enable row level security;
-- الإضافة: أي حد، بس لو كاتب user_id لازم يكون هو نفسه
drop policy if exists yasser_missing_insert on yasser_missing;
create policy yasser_missing_insert on yasser_missing for insert
  with check (user_id is null or user_id = auth.uid());
drop policy if exists yasser_missing_admin_read on yasser_missing;
create policy yasser_missing_admin_read on yasser_missing for select using (is_admin());
drop policy if exists yasser_missing_admin_delete on yasser_missing;
create policy yasser_missing_admin_delete on yasser_missing for delete using (is_admin());

grant select on yasser_faq to anon, authenticated;
grant insert on yasser_missing to anon, authenticated;
grant usage on sequence yasser_missing_id_seq to anon, authenticated;
-- الأدمن (من التطبيق): الصلاحيات دي، والقواعد اللي فوق بتقصرها على الأدمن بس
grant insert, update, delete on yasser_faq to authenticated;
grant usage on sequence yasser_faq_id_seq to authenticated;
grant select, delete on yasser_missing to authenticated;
