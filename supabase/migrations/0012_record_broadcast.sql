-- Extend record_track_points: after the durable insert, broadcast the newest point in
-- the batch to the ride's private channel. One write = durable + live (Broadcast-from-
-- Database). realtime.send swallows its own errors (warns), so a failed broadcast never
-- fails the ride; correctness of the live view rests on ride_live_snapshot, not on send.
-- Batch is always single-writer (auth.uid()), so "newest" = max recorded_at. motion_state
-- rides only on the broadcast; it is not persisted (no column). No raw speed is sent.
create or replace function public.record_track_points(p_ride_id uuid, p_points jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_newest jsonb;
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

  select e into v_newest
  from jsonb_array_elements(p_points) as e
  order by (e->>'recorded_at')::timestamptz desc
  limit 1;

  if v_newest is not null then
    perform realtime.send(
      jsonb_build_object(
        'userID', v_uid,
        'lat', (v_newest->>'lat')::double precision,
        'lon', (v_newest->>'lon')::double precision,
        'progressMeters', (v_newest->>'progress_meters')::double precision,
        'recordedAt', v_newest->>'recorded_at',
        'motionState', coalesce(v_newest->>'motion_state', 'moving')
      ),
      'position',
      'ride:' || p_ride_id::text,
      true);
  end if;
end;
$$;
revoke execute on function public.record_track_points(uuid, jsonb) from public;
grant execute on function public.record_track_points(uuid, jsonb) to authenticated;
