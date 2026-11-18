-- فيش بوك: مسح البيانات التجريبية من السيرفر الحقيقي. بيتشغّل مرة واحدة من SQL Editor، ومالوش رجوع.
-- الحسابات التجريبية هي اللي إيميلها آخره @fishbook-demo.com.
-- بيمسح: رحلات الحسابات دي، والحجوزات والتقييمات اللي عليها (حتى لو من حساب حقيقي)،
--        حجوزات الحسابات التجريبية على أي رحلة، صيداتها، ومراكبها اللي مبقاش عليها رحلات.
-- وبيمسح الحساب التجريبي نفسه (ومعاه بوستاته وتعليقاته) لو مبقاش مربوط بحاجة.
-- مبيلمسش: أي رحلة أو مركب أو حساب حقيقي.
-- في الآخر بيطلع جدول بعدد اللي اتمسح.
create temp table demo_users on commit drop as
  select id from auth.users where email like '%@fishbook-demo.com';
create temp table demo_trips on commit drop as
  select id from trips where publisher_id in (select id from demo_users);
create temp table demo_bookings on commit drop as
  select id from bookings where trip_id in (select id from demo_trips) or user_id in (select id from demo_users);
create temp table demo_done (what text, n bigint) on commit drop;

with d as (delete from ratings where booking_id in (select id from demo_bookings) returning 1)
  insert into demo_done select 'تقييمات', count(*) from d;
with d as (delete from bookings where id in (select id from demo_bookings) returning 1)
  insert into demo_done select 'حجوزات', count(*) from d;
update catches set trip_id = null where trip_id in (select id from demo_trips);
with d as (delete from catches where user_id in (select id from demo_users) returning 1)
  insert into demo_done select 'صيدات', count(*) from d;
with d as (delete from trips where id in (select id from demo_trips) returning 1)
  insert into demo_done select 'رحلات', count(*) from d;
with d as (delete from boats b
           where coalesce(b.owner_id, b.created_by) in (select id from demo_users)
             and not exists (select 1 from trips t where t.boat_id = b.id) returning 1)
  insert into demo_done select 'مراكب', count(*) from d;
with d as (delete from auth.users u
           where u.id in (select id from demo_users)
             and not exists (select 1 from boats b where b.created_by = u.id or b.owner_id = u.id)
             and not exists (select 1 from trips t where t.publisher_id = u.id)
             and not exists (select 1 from bookings k where k.user_id = u.id) returning 1)
  insert into demo_done select 'حسابات تجريبية', count(*) from d;

select * from demo_done;
