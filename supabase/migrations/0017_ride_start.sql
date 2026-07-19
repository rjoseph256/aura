-- ROH-71: durable "ride has started" state + an authoritative status read.
alter table public.rides add column started_at timestamptz;

create function public.start_ride(p_ride_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_host uuid;
  v_started timestamptz;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select host_id into v_host from public.rides where id = p_ride_id;
  if v_host is null or v_host <> v_uid then raise exception 'not host'; end if;
  update public.rides
    set started_at = now(),
        expires_at = greatest(expires_at, now() + interval '48 hours')
    where id = p_ride_id and started_at is null and ended_at is null
    returning started_at into v_started;
  if found then
    perform realtime.send(jsonb_build_object('startedAt', v_started),
                          'ride_started', 'ride:' || p_ride_id::text, true);
  end if;
end;
$$;
revoke execute on function public.start_ride(uuid) from public;
grant execute on function public.start_ride(uuid) to authenticated;

create function public.ride_status(p_ride_id uuid)
returns table (host_id uuid, status text, started_at timestamptz, ended_at timestamptz)
language plpgsql security definer set search_path = '' stable as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if not (select public.is_ride_member(p_ride_id)) then raise exception 'unauthorized'; end if;
  return query select r.host_id, r.status, r.started_at, r.ended_at
               from public.rides r where r.id = p_ride_id;
end;
$$;
revoke execute on function public.ride_status(uuid) from public;
grant execute on function public.ride_status(uuid) to authenticated;
