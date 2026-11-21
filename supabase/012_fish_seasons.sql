-- فيش بوك: مواسم السمك في قاعدة البيانات. بيتشغّل مرة واحدة من SQL Editor.
-- التطبيق بيقرا الجدول ده عشان يعرف سمك الموسم في كل يوم. لو الجدول مش موجود بيستخدم النسخة اللي جواه.
-- أي حد يقدر يقرا، والتعديل للأدمن بس (من Table Editor في Supabase).
-- months: شهور الموسم (1 = يناير). peak: أحسن شهور.
-- from_month/from_day: الموسم بيبدأ من اليوم ده في أول شهر. to_month/to_day: بيخلص في اليوم ده في آخر شهر.
-- kind = 'breed': مش نوع سمك، ده موسم التكاثر اللي بيظهر كعلامة على الأيام.
-- المصادر في docs/fish-seasons.md.

create table if not exists fish_seasons (
  name       text primary key,
  kind       text not null default 'fish' check (kind in ('fish', 'breed')),
  months     int[] not null default '{}',
  peak       int[] not null default '{}',
  from_month int, from_day int,
  to_month   int, to_day   int,
  note       text not null default '',
  sort       int not null default 0,
  updated_at timestamptz not null default now()
);

alter table fish_seasons enable row level security;
drop policy if exists fish_seasons_read on fish_seasons;
create policy fish_seasons_read on fish_seasons for select using (true);
drop policy if exists fish_seasons_admin on fish_seasons;
create policy fish_seasons_admin on fish_seasons for all using (is_admin()) with check (is_admin());

insert into fish_seasons (name, kind, months, peak, from_month, from_day, to_month, to_day, note, sort) values
  ('مرجان',   'fish', '{11,12,1,2}',               '{1,2}',      null, null, null, null, 'سمك الشتاء. أحسن شهرين يناير وفبراير.', 1),
  ('شعور',    'fish', '{5,6,7,8}',                 '{}',         5, 15, 8, 15, 'فرشة الشعور: من نص مايو لحوالي 3 شهور. أحسن صيد بعد الغروب في الليالي القمرية (13 لـ 22 هجري).', 2),
  ('ناجل',    'fish', '{5,6,7,8,9,10}',            '{6,7}',      null, null, null, null, 'من الأعماق. أحسن شهرين يونيو ويوليو، وبيقل جدًا في الشتاء.', 3),
  ('كشر',     'fish', '{9,10,11,12,1,2}',          '{12,1}',     null, null, null, null, 'موجود طول السنة، وأحسن صيده في الشتاء بالجيجينج العميق.', 4),
  ('بهار',    'fish', '{11,12,1,2,7,8}',           '{}',         null, null, null, null, 'مصادره قليلة، محتاج تأكيد من الصيادين.', 5),
  ('بياض',    'fish', '{1,2,3,4,5,6,7,8,9,10,11,12}', '{7,12,1}', null, null, null, null, 'موجود طول السنة. الجرم الكبير أنشط في مارس وأبريل وسبتمبر وأكتوبر.', 6),
  ('عنبرة',   'fish', '{1,2,4,5,6,7,8,9,10,11,12}', '{11,12,1,2}', null, null, null, null, 'كل الشهور ما عدا مارس، وأحسنها الشتاء.', 7),
  ('توين',    'fish', '{1,2,4,5,6,7,10}',          '{4,5,6}',    null, null, null, null, 'التونة. أحسن وقت من أبريل لحد يونيو.', 8),
  ('دراك',    'fish', '{10,11,12,1,2,3,4}',        '{1,2}',      null, null, null, null, 'أحسن شهرين يناير وفبراير.', 9),
  ('بركودة',  'fish', '{7,8,9,10,12,1}',           '{9,10}',     null, null, null, null, 'أحسن شهرين سبتمبر وأكتوبر.', 10),
  ('أبو شراع','fish', '{5,6,7,8,9}',               '{7}',        null, null, null, null, 'أحسن شهر يوليو.', 11),
  ('بلاميطة', 'fish', '{6,7,8,11,12,1,2}',         '{}',         null, null, null, null, '', 12),
  ('خرمي',    'fish', '{7,8}',                     '{}',         null, null, null, null, 'بيطلع مع موسم الشعور.', 13),
  ('موسم تكاثر', 'breed', '{4,5,6}',              '{}',         null, null, null, null, 'الكشر والشعور بيبيضوا أكتر في أبريل ومايو، وأنواع كشر تانية لحد يونيو.', 100)
on conflict (name) do nothing;
