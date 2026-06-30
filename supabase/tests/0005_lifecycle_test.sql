-- Lifecycle (end_ride host guard + leave_ride host transfer) is validated through a
-- single SECURITY DEFINER helper driving the flow with set_config, then asserted by
-- pgTAP. Robust under pg_prove; the functions enforce their own authz in-body.
begin;
select plan(4);
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','u1@test.dev'),
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-0000-0000-000000000002','authenticated','authenticated','u2@test.dev');

create function pg_temp.life_flow(
  out nonhost_rejected boolean, out new_host_role text,
  out member_count int, out final_status text)
language plpgsql security definer set search_path = '' as $$
declare rid uuid; code text;
begin
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id, join_code into rid, code from public.create_ride('{}'::jsonb);
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  perform public.join_ride(code);
  -- non-host (user 2) cannot end
  begin perform public.end_ride(rid); nonhost_rejected := false;
  exception when others then nonhost_rejected := true; end;
  -- host (user 1) leaves -> transfers to user 2
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  perform public.leave_ride(rid);
  select role into new_host_role from public.ride_members
    where ride_id = rid and user_id = 'bbbbbbbb-0000-0000-0000-000000000002';
  select count(*)::int into member_count from public.ride_members where ride_id = rid;
  -- new host (user 2) ends the ride
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  perform public.end_ride(rid);
  select status into final_status from public.rides where id = rid;
end; $$;

create temp table lf as select * from pg_temp.life_flow();
select is((select nonhost_rejected from lf), true, 'non-host cannot end');
select is((select new_host_role from lf), 'host', 'host transferred to remaining member');
select is((select member_count from lf), 1, 'departed host removed');
select is((select final_status from lf), 'ended', 'new host ended the ride');
select * from finish();
rollback;
