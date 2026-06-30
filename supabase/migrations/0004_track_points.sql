create function public.record_track_points(p_ride_id uuid, p_points jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'unauthorized'; end if;
  if not (select public.is_ride_member(p_ride_id)) then raise exception 'unauthorized'; end if;
  if jsonb_array_length(p_points) > 200 then raise exception 'batch too large'; end if;

  insert into public.ride_track_points (ride_id, user_id, recorded_at, lat, lon, progress_meters)
  select p_ride_id, v_uid,
         (e->>'recorded_at')::timestamptz, (e->>'lat')::double precision,
         (e->>'lon')::double precision, (e->>'progress_meters')::double precision
  from jsonb_array_elements(p_points) as e
  on conflict (ride_id, user_id, recorded_at) do nothing;

  update public.ride_members
    set last_seen_at = now()
    where ride_id = p_ride_id and user_id = v_uid;
end;
$$;
revoke execute on function public.record_track_points(uuid, jsonb) from public;
grant execute on function public.record_track_points(uuid, jsonb) to authenticated;

create policy track_points_select on public.ride_track_points
  for select to authenticated using ((select public.is_ride_member(ride_id)));
