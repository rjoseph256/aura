begin;
select plan(6);
-- Seed 9 users as superuser up front (full column set); the trigger makes profiles.
insert into auth.users (instance_id, id, aud, role, email)
select '00000000-0000-0000-0000-000000000000',
       ('aaaaaaaa-0000-0000-0000-00000000000'||g)::uuid,
       'authenticated','authenticated','u'||g||'@test.dev'
from generate_series(1,9) g;

set local role authenticated;
-- User 1 hosts.
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';
create temp table t as select (public.create_ride('{"steps":[]}'::jsonb)).*;

-- User 2 joins, twice (idempotent).
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000002"}';
select lives_ok($$ select public.join_ride((select join_code from t)) $$, 'valid join succeeds');
select lives_ok($$ select public.join_ride((select join_code from t)) $$, 'double join is idempotent');
select is((select count(*)::int from public.ride_members where ride_id=(select id from t)),
  2, 'no duplicate membership row');
select throws_ok($$ select public.join_ride('ZZZZZZZZ') $$, null, 'bad code fails generically');

-- Fill to 8 (users 3..8 join); user 9 is rejected. No user creation in the loop —
-- all users already seeded; identity switches via the claims GUC (allowed for
-- authenticated with set_config local), and join_ride is SECURITY DEFINER.
do $$
declare g int;
begin
  for g in 3..8 loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', ('aaaaaaaa-0000-0000-0000-00000000000'||g)::uuid)::text, true);
    perform public.join_ride((select join_code from t));
  end loop;
end $$;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000009"}';
select throws_ok($$ select public.join_ride((select join_code from t)) $$, null, '9th join rejected (cap 8)');
select is((select count(*)::int from public.ride_members where ride_id=(select id from t)),
  8, 'exactly 8 members');
select * from finish();
rollback;
