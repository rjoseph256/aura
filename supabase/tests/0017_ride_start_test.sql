-- start_ride / ride_status (ROH-71 durable ride-start state) validated through a
-- single SECURITY DEFINER helper driving the flow with set_config, then asserted by
-- pgTAP. Partition guard mirrors 0015: realtime.send drops silently when today's
-- realtime.messages partition is absent, which a pure pgTAP run never creates.
begin;
select plan(9);

do $$
begin
  execute format(
    'create table if not exists realtime.messages_%s partition of realtime.messages for values from (%L) to (%L)',
    to_char(current_date, 'YYYY_MM_DD'), current_date::timestamp, (current_date + 1)::timestamp);
exception when others then
  raise notice 'partition setup failed: %', sqlerrm;
end $$;
select ok(
  exists(select 1 from pg_catalog.pg_inherits i
         join pg_catalog.pg_class c on c.oid = i.inhrelid
         where c.relname = 'messages_'||to_char(current_date, 'YYYY_MM_DD')),
  'today''s realtime.messages partition exists');

insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','u1@test.dev'),
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-0000-0000-000000000002','authenticated','authenticated','u2@test.dev'),
  ('00000000-0000-0000-0000-000000000000','cccccccc-0000-0000-0000-000000000003','authenticated','authenticated','u3@test.dev');

create function pg_temp.start_flow(
  out nonhost_rejected boolean,
  out started_at_set boolean,
  out idempotent_ok boolean,
  out ended_started_at_null boolean,
  out broadcast_count int,
  out status_member_host_id uuid,
  out status_nonmember_rejected boolean,
  out status_after_transfer_host_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  rid_a uuid; code_a text;
  rid_b uuid; code_b text;
  rid_c uuid; code_c text;
  v_started1 timestamptz;
  v_started2 timestamptz;
begin
  -- Ride A: user1 hosts, user2 joins.
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id, join_code into rid_a, code_a from public.create_ride('{}'::jsonb);
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  perform public.join_ride(code_a);

  -- non-host (user2) cannot start
  begin
    perform public.start_ride(rid_a);
    nonhost_rejected := false;
  exception when others then
    nonhost_rejected := true;
  end;

  -- host (user1) starts the ride
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  perform public.start_ride(rid_a);
  select started_at into v_started1 from public.rides where id = rid_a;
  started_at_set := v_started1 is not null;

  -- idempotent: a second call must not move the timestamp, nor broadcast again
  perform public.start_ride(rid_a);
  select started_at into v_started2 from public.rides where id = rid_a;
  idempotent_ok := (v_started1 = v_started2);

  select count(*)::int into broadcast_count from realtime.messages
    where topic = 'ride:'||rid_a::text and event = 'ride_started';

  -- ride_status: member (user2) can read; host_id reflects the current host
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  select host_id into status_member_host_id from public.ride_status(rid_a);

  -- ride_status: non-member (user3) is rejected
  perform set_config('request.jwt.claims','{"sub":"cccccccc-0000-0000-0000-000000000003"}', true);
  begin
    perform public.ride_status(rid_a);
    status_nonmember_rejected := false;
  exception when others then
    status_nonmember_rejected := true;
  end;

  -- Ride B: ended before start_ride is attempted -> must stay unstarted.
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id, join_code into rid_b, code_b from public.create_ride('{}'::jsonb);
  perform public.end_ride(rid_b);
  perform public.start_ride(rid_b);
  select (started_at is null) into ended_started_at_null from public.rides where id = rid_b;

  -- Ride C: host transfer via leave_ride; ride_status must reflect the new host.
  select id, join_code into rid_c, code_c from public.create_ride('{}'::jsonb);
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  perform public.join_ride(code_c);
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  perform public.leave_ride(rid_c);
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  select host_id into status_after_transfer_host_id from public.ride_status(rid_c);
end;
$$;

create temp table sf as select * from pg_temp.start_flow();
select is((select nonhost_rejected from sf), true, 'non-host cannot start');
select is((select started_at_set from sf), true, 'host start sets started_at');
select is((select idempotent_ok from sf), true, 'second start_ride does not move started_at');
select is((select ended_started_at_null from sf), true, 'start_ride does not start an ended ride');
select is((select broadcast_count from sf), 1, 'exactly one ride_started broadcast emitted (none on no-op repeat)');
select is((select status_member_host_id from sf), 'aaaaaaaa-0000-0000-0000-000000000001'::uuid, 'ride_status returns the row for a member');
select is((select status_nonmember_rejected from sf), true, 'ride_status rejects a non-member');
select is((select status_after_transfer_host_id from sf), 'bbbbbbbb-0000-0000-0000-000000000002'::uuid, 'ride_status host_id reflects a host transfer');
select * from finish();
rollback;
