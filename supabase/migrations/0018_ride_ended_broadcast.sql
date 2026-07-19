-- ROH-71/ROH-68: make ride-end idempotent and emit a dedicated `ride_ended` broadcast
-- so a guest offline at the end still dissolves its crew and a lost-response retry can
-- safely re-notify. Bodies are otherwise identical to 0015 (host transfer, retention
-- formula, member_left for real departures preserved). end_ride no longer emits the
-- host's member_left — the crew now learns the ride ended via ride_ended.
create or replace function public.leave_ride(p_ride_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
  v_next uuid;
  v_last timestamptz;
begin
  select role into v_role from public.ride_members
    where ride_id = p_ride_id and user_id = v_uid;
  if v_role is null then raise exception 'not a member'; end if;

  delete from public.ride_members where ride_id = p_ride_id and user_id = v_uid;

  if v_role = 'host' then
    select user_id into v_next from public.ride_members
      where ride_id = p_ride_id order by joined_at asc limit 1;
    if v_next is null then
      select max(recorded_at) into v_last from public.ride_track_points where ride_id = p_ride_id;
      update public.rides set status = 'ended', ended_at = now(),
        expires_at = least(now() + interval '48 hours',
                           coalesce(v_last, now()) + interval '48 hours')
        where id = p_ride_id and ended_at is null;
      -- Host leaving an empty ride ends it for any straggler, exactly like end_ride.
      perform realtime.send(jsonb_build_object('endedAt', now()),
                            'ride_ended', 'ride:' || p_ride_id::text, true);
    else
      update public.ride_members set role = 'host'
        where ride_id = p_ride_id and user_id = v_next;
      update public.rides set host_id = v_next where id = p_ride_id;
    end if;
  end if;

  perform realtime.send(jsonb_build_object('userID', v_uid),
                        'member_left', 'ride:' || p_ride_id::text, true);
end;
$$;
revoke execute on function public.leave_ride(uuid) from public;
grant execute on function public.leave_ride(uuid) to authenticated;

create or replace function public.end_ride(p_ride_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_host uuid;
  v_last timestamptz;
  v_ended timestamptz;
begin
  select host_id into v_host from public.rides where id = p_ride_id;
  if v_host is null or v_host <> v_uid then raise exception 'not host'; end if;
  select max(recorded_at) into v_last from public.ride_track_points where ride_id = p_ride_id;
  update public.rides
    set status = 'ended', ended_at = now(),
        expires_at = least(now() + interval '48 hours',
                           coalesce(v_last, now()) + interval '48 hours')
    where id = p_ride_id and ended_at is null;
  select ended_at into v_ended from public.rides where id = p_ride_id;
  -- Unconditional (unlike start_ride's guarded broadcast): a retry after a lost response
  -- must re-notify, and the client's optimistic phase is forward-only so a duplicate
  -- ride_ended is a safe no-op.
  perform realtime.send(jsonb_build_object('endedAt', v_ended),
                        'ride_ended', 'ride:' || p_ride_id::text, true);
end;
$$;
revoke execute on function public.end_ride(uuid) from public;
grant execute on function public.end_ride(uuid) to authenticated;
