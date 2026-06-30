begin;
select plan(2);
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','u1@test.dev'),
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-0000-0000-000000000002','authenticated','authenticated','u2@test.dev'),
  ('00000000-0000-0000-0000-000000000000','cccccccc-0000-0000-0000-000000000003','authenticated','authenticated','u3@test.dev');
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';
create temp table t as select (public.create_ride('{"steps":[]}'::jsonb)).*;
set local request.jwt.claims = '{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}';
select public.join_ride((select join_code from t));

-- Co-rider (user 2) can read the host's (user 1) profile.
select is((select count(*)::int from public.profiles where id='aaaaaaaa-0000-0000-0000-000000000001'),
  1, 'co-rider can read fellow member profile');

-- A non-member (user 3) cannot read the host's profile.
set local request.jwt.claims = '{"sub":"cccccccc-0000-0000-0000-000000000003"}';
select is((select count(*)::int from public.profiles where id='aaaaaaaa-0000-0000-0000-000000000001'),
  0, 'non-member cannot read a member profile');
select * from finish();
rollback;
