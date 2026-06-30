-- Latest track point per member, joined to display_name, members-only. Seeds the live
-- map on join and re-seeds on every reconnect (the live view's source of truth; live
-- broadcast deltas are best-effort). Deterministic latest-per-member via distinct on +
-- ctid tiebreaker. motion_state is not stored, so it is not returned; the client seeds
-- peers as moving and lets the next delta refine.
create function public.ride_live_snapshot(p_ride_id uuid)
returns table (
  user_id uuid,
  display_name text,
  lat double precision,
  lon double precision,
  progress_meters double precision,
  recorded_at timestamptz)
language plpgsql
security definer
set search_path = ''
stable
as $$
begin
  if not (select public.is_ride_member(p_ride_id)) then raise exception 'unauthorized'; end if;
  return query
    select distinct on (tp.user_id)
           tp.user_id, pr.display_name, tp.lat, tp.lon, tp.progress_meters, tp.recorded_at
    from public.ride_track_points tp
    join public.profiles pr on pr.id = tp.user_id
    where tp.ride_id = p_ride_id
    order by tp.user_id, tp.recorded_at desc, tp.ctid desc;
end;
$$;
revoke execute on function public.ride_live_snapshot(uuid) from public;
grant execute on function public.ride_live_snapshot(uuid) to authenticated;
