begin;
select plan(4);
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','u1@test.dev'),
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-0000-0000-000000000002','authenticated','authenticated','u2@test.dev');
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';
create temp table t as select (public.create_ride('{"steps":[]}'::jsonb)).*;

-- Host records two points.
select lives_ok($$
  select public.record_track_points((select id from t),
    '[{"recorded_at":"2026-06-29T12:00:00Z","lat":40.44,"lon":-79.99,"progress_meters":0},
      {"recorded_at":"2026-06-29T12:00:05Z","lat":40.45,"lon":-79.98,"progress_meters":120}]'::jsonb)
$$, 'member records a batch');
select is((select count(*)::int from public.ride_track_points where ride_id=(select id from t)),
  2, 'two points stored');
-- Idempotent replay: same recorded_at -> no duplicates.
select public.record_track_points((select id from t),
  '[{"recorded_at":"2026-06-29T12:00:00Z","lat":40.44,"lon":-79.99,"progress_meters":0}]'::jsonb);
select is((select count(*)::int from public.ride_track_points where ride_id=(select id from t)),
  2, 'replay does not duplicate');

-- Non-member cannot SELECT the points.
set local request.jwt.claims = '{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}';
select is((select count(*)::int from public.ride_track_points), 0,
  'non-member sees no track points');
select * from finish();
rollback;
