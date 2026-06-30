begin;
select plan(3);
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','u1@test.dev');
-- A ride already past expires_at -> reaped, cascades.
insert into public.rides (id, host_id, join_code, route, status, expires_at)
  values ('99999999-9999-9999-9999-999999999999',
          'aaaaaaaa-0000-0000-0000-000000000001', 'EXPIRED1', '{}'::jsonb,
          'ended', now() - interval '1 hour');
insert into public.ride_members (ride_id, user_id, role)
  values ('99999999-9999-9999-9999-999999999999',
          'aaaaaaaa-0000-0000-0000-000000000001', 'host');
select public.reap_expired_rides();
select is((select count(*)::int from public.rides where id='99999999-9999-9999-9999-999999999999'),
  0, 'expired ride reaped');
select is((select count(*)::int from public.ride_members
           where ride_id='99999999-9999-9999-9999-999999999999'),
  0, 'members cascaded on reap');

-- A stale active ride (no points, created 4h ago) -> swept to ended.
insert into public.rides (id, host_id, join_code, route, status, created_at, expires_at)
  values ('88888888-8888-8888-8888-888888888888',
          'aaaaaaaa-0000-0000-0000-000000000001', 'STALE111', '{}'::jsonb,
          'active', now() - interval '4 hours', now() + interval '32 hours');
select public.sweep_stale_rides();
select is((select status from public.rides where id='88888888-8888-8888-8888-888888888888'),
  'ended', 'stale active ride swept to ended');
select * from finish();
rollback;
