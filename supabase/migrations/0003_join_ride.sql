create function public.join_ride(p_code text)
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

  -- Rate limit: record the attempt, then count this user's attempts in the last minute.
  insert into public.join_attempts (user_id) values (v_uid);
  select count(*) into v_recent from public.join_attempts
    where user_id = v_uid and attempted_at > now() - interval '1 minute';
  if v_recent > 10 then raise exception 'join failed'; end if;  -- generic: hides the reason

  -- Resolve an ACTIVE ride only. Generic failure for wrong/expired code.
  select * into v_ride from public.rides
    where join_code = p_code and status = 'active';
  if v_ride.id is null then raise exception 'join failed'; end if;

  -- Idempotent: already a member -> return the ride.
  if exists (select 1 from public.ride_members
             where ride_id = v_ride.id and user_id = v_uid) then
    return v_ride;
  end if;

  -- Hard cap of 8.
  select count(*) into v_count from public.ride_members where ride_id = v_ride.id;
  if v_count >= 8 then raise exception 'join failed'; end if;

  insert into public.ride_members (ride_id, user_id, role)
  values (v_ride.id, v_uid, 'member');
  return v_ride;
end;
$$;
revoke execute on function public.join_ride(text) from public;
grant execute on function public.join_ride(text) to authenticated;
