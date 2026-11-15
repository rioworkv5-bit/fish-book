-- فيش بوك: حماية الرحلات اللي عليها حجوزات عند التعديل.
-- بيتشغّل مرة واحدة من SQL Editor بعد schema.sql.
-- القاعدة: المركب والناشر مبيتغيروش. الأماكن متقلش عن المحجوز.
-- ولو الرحلة عليها حجوزات: التاريخ والمدة والأسعار مبيتغيروش (الإلغاء مسموح).
create function trips_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare taken int;
begin
  if new.boat_id <> old.boat_id or new.publisher_id <> old.publisher_id then
    raise exception 'trip_fixed_fields';
  end if;
  select coalesce(sum(seats), 0) into taken from bookings where trip_id = old.id and status = 'booked';
  if new.seats_total < taken then raise exception 'seats_below_booked'; end if;
  if taken > 0 and (new.start_date <> old.start_date or new.days <> old.days
                    or new.price_seat <> old.price_seat or new.price_whole <> old.price_whole) then
    raise exception 'trip_has_bookings';
  end if;
  return new;
end $$;

create trigger trips_guard before update on trips
  for each row execute function trips_guard();
