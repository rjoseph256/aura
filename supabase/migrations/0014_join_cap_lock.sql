-- Close the join-cap TOCTOU: `where count < 8` does not serialize under READ COMMITTED
-- (two joiners each see 7, both insert -> 9). Take a per-ride transaction advisory lock
-- before the count, so concurrent joins to the same ride are serialized and the hard cap
-- of 8 holds. Generic 'join failed' oracle, rate limit, and idempotent re-join unchanged.
create or replace function public.join_ride(p_code text)
returns public.rides
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_ride public.rides;
  v_recent int;
  v_count int;
begin
  if v_uid is null then raise exception 'join failed'; end if;

  insert into public.join_attempts (user_id) values (v_uid);
  select count(*) into v_recent from public.join_attempts
    where user_id = v_uid and attempted_at > now() - interval '1 minute';
  if v_recent > 10 then raise exception 'join failed'; end if;

  select * into v_ride from public.rides
    where join_code = p_code and status = 'active';
  if v_ride.id is null then raise exception 'join failed'; end if;

  if exists (select 1 from public.ride_members
             where ride_id = v_ride.id and user_id = v_uid) then
    return v_ride;
  end if;

  -- Serialize concurrent joins to this ride so the count-then-insert is race-free.
  perform pg_advisory_xact_lock(hashtextextended(v_ride.id::text, 0));

  select count(*) into v_count from public.ride_members where ride_id = v_ride.id;
  if v_count >= 8 then raise exception 'join failed'; end if;

  insert into public.ride_members (ride_id, user_id, role)
  values (v_ride.id, v_uid, 'member');
  return v_ride;
end;
$$;
revoke execute on function public.join_ride(text) from public;
grant execute on function public.join_ride(text) to authenticated;
