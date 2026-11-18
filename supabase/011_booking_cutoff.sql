-- فيش بوك: الحجز بيتقفل أول ما يوم الرحلة يبدأ. بيتشغّل مرة واحدة من SQL Editor.
-- قبل كده الرحلة كانت بتتحجز طول يوم بدايتها، يعني بعد ما المركب تكون طلعت.
-- اليوم بيتحسب بتوقيت القاهرة مش توقيت السيرفر.
create or replace function book_trip(p_trip bigint, p_seats int, p_whole boolean, p_name text, p_phone text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare t trips; taken int; bid bigint;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select * into t from trips where id = p_trip for update;
  if not found or t.status <> 'open' then raise exception 'trip_not_available'; end if;
  if t.start_date <= (now() at time zone 'Africa/Cairo')::date then raise exception 'booking_closed'; end if;
  select coalesce(sum(seats), 0) into taken from bookings where trip_id = p_trip and status = 'booked';
  if p_whole then
    if taken > 0 or t.price_whole = 0 then raise exception 'whole_boat_not_available'; end if;
    p_seats := t.seats_total;
  elsif p_seats is null or p_seats < 1 or taken + p_seats > t.seats_total then
    raise exception 'not_enough_seats';
  end if;
  insert into bookings (trip_id, user_id, name, phone, seats, whole)
  values (p_trip, auth.uid(), trim(p_name), trim(p_phone), p_seats, p_whole)
  returning id into bid;
  return bid;
end $$;
