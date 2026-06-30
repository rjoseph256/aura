begin;
select plan(5);
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','u1@test.dev'),
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-0000-0000-000000000002','authenticated','authenticated','u2@test.dev');
set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';
create temp table t as select (public.create_ride('{"steps":[]}'::jsonb)).*;
set local request.jwt.claims = '{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}';
select public.join_ride((select join_code from t));

-- Non-host cannot end.
select throws_ok($$ select public.end_ride((select id from t)) $$, null, 'non-host cannot end');

-- Host leaves -> host transfers to remaining member (user 2).
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';
select lives_ok($$ select public.leave_ride((select id from t)) $$, 'host can leave');
select is((select role from public.ride_members
           where ride_id=(select id from t)
             and user_id='bbbbbbbb-0000-0000-0000-000000000002'),
  'host', 'host transferred to remaining member');
select is((select count(*)::int from public.ride_members where ride_id=(select id from t)),
  1, 'departed host removed');

-- New host ends the ride -> status ended, expires_at set.
set local request.jwt.claims = '{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}';
select public.end_ride((select id from t));
select is((select status from public.rides where id=(select id from t)),
  'ended', 'ride ended by new host');
select * from finish();
rollback;
