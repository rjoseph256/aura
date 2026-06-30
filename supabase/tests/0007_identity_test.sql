begin;
select plan(3);
-- Inserting an auth user auto-creates a profile via trigger.
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','u1@test.dev');
select is((select display_name from public.profiles
           where id='aaaaaaaa-0000-0000-0000-000000000001'),
  'Rider', 'trigger created profile with placeholder name');

set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}';
select public.upsert_display_name('Rohun');
select is((select display_name from public.profiles
           where id='aaaaaaaa-0000-0000-0000-000000000001'),
  'Rohun', 'display name updated');

-- delete_account cascades through a hosted ride.
create temp table t as select (public.create_ride('{"steps":[]}'::jsonb)).*;
select public.delete_account();
select is((select count(*)::int from public.rides where id=(select id from t)),
  0, 'hosted ride cascaded on account delete');
select * from finish();
rollback;
