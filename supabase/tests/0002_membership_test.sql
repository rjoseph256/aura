begin;
select plan(4);
-- Seed users as superuser BEFORE switching role; the handle_new_user trigger
-- (migration 0007, live in every test) creates their profiles. Never insert
-- into public.profiles directly.
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','u1@test.dev'),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','u2@test.dev');

-- Act as user 1, create a ride.
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select lives_ok($$ select public.create_ride('{"steps":[]}'::jsonb) $$, 'host can create ride');
select is(
  (select count(*)::int from public.rides where host_id = '11111111-1111-1111-1111-111111111111'),
  1, 'one ride owned by host');
select is(
  (select count(*)::int from public.rides), 1, 'host can SELECT own ride via RLS');

-- Act as user 2 (not a member): must see zero rides.
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select is((select count(*)::int from public.rides), 0, 'non-member cannot SELECT the ride');
select * from finish();
rollback;
