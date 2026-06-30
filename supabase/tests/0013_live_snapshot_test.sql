begin;
select plan(3);
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','u1@test.dev'),
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-0000-0000-000000000002','authenticated','authenticated','u2@test.dev');

create function pg_temp.snap_flow(out row_count int, out latest_progress double precision, out nonmember_rejected boolean)
language plpgsql security definer set search_path = '' as $$
declare rid uuid;
begin
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id into rid from public.create_ride('{}'::jsonb);
  -- two points for the host; the later one (progress 50) must win
  perform public.record_track_points(rid, jsonb_build_array(
    jsonb_build_object('recorded_at', (now() - interval '10 s')::text, 'lat', 37.0, 'lon', -122.0, 'progress_meters', 10.0)));
  perform public.record_track_points(rid, jsonb_build_array(
    jsonb_build_object('recorded_at', now()::text, 'lat', 37.1, 'lon', -122.1, 'progress_meters', 50.0)));
  select count(*)::int, max(progress_meters) into row_count, latest_progress
    from public.ride_live_snapshot(rid);
  -- user 2 is not a member -> snapshot rejected
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  begin
    perform * from public.ride_live_snapshot(rid);
    nonmember_rejected := false;
  exception when others then nonmember_rejected := true; end;
end; $$;

create temp table sf as select * from pg_temp.snap_flow();
select is((select row_count from sf), 1, 'one row per member');
select is((select latest_progress from sf), 50.0::double precision, 'returns the latest point per member');
select is((select nonmember_rejected from sf), true, 'snapshot is members-only');
select * from finish();
rollback;
