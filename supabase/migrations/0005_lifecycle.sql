create function public.end_ride(p_ride_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_host uuid;
  v_last timestamptz;
begin
  select host_id into v_host from public.rides where id = p_ride_id;
  if v_host is null or v_host <> v_uid then raise exception 'not host'; end if;
  select max(recorded_at) into v_last from public.ride_track_points where ride_id = p_ride_id;
  update public.rides
    set status = 'ended', ended_at = now(),
        expires_at = least(now() + interval '48 hours',
                           coalesce(v_last, now()) + interval '48 hours')
    where id = p_ride_id;
end;
$$;
revoke execute on function public.end_ride(uuid) from public;
grant execute on function public.end_ride(uuid) to authenticated;

create function public.leave_ride(p_ride_id uuid)
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
      -- Same retention formula as end_ride (not a flat now()+48h).
      select max(recorded_at) into v_last from public.ride_track_points where ride_id = p_ride_id;
      update public.rides set status = 'ended', ended_at = now(),
        expires_at = least(now() + interval '48 hours',
                           coalesce(v_last, now()) + interval '48 hours')
        where id = p_ride_id;
    else
      update public.ride_members set role = 'host'
        where ride_id = p_ride_id and user_id = v_next;
      update public.rides set host_id = v_next where id = p_ride_id;
    end if;
  end if;
end;
$$;
revoke execute on function public.leave_ride(uuid) from public;
grant execute on function public.leave_ride(uuid) to authenticated;
