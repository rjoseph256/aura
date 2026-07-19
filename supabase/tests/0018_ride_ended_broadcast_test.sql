-- 0018 idempotent end + dedicated ride_ended broadcast (ROH-71/ROH-68), validated
-- through a single SECURITY DEFINER helper driving the flow with set_config, then
-- asserted by pgTAP. Partition guard mirrors 0015/0017: realtime.send drops silently
-- when today's realtime.messages partition is absent, which a pure pgTAP run never creates.
begin;
select plan(7);

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
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-0000-0000-000000000002','authenticated','authenticated','u2@test.dev');

create function pg_temp.end_flow(
  out ended_set boolean,
  out ended_idempotent boolean,
  out ride_ended_count int,
  out host_member_left_count int,
  out member_leave_count int,
  out host_empty_ride_ended int)
language plpgsql security definer set search_path = '' as $$
declare
  rid_a uuid; code_a text;
  rid_b uuid; code_b text;
  v_ended1 timestamptz;
  v_ended2 timestamptz;
begin
  -- Ride A: user1 hosts, user2 joins, user2 (plain member) leaves, user1 (host) ends.
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id, join_code into rid_a, code_a from public.create_ride('{}'::jsonb);
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  perform public.join_ride(code_a);
  perform public.leave_ride(rid_a);   -- plain member departs -> member_left
  select count(*)::int into member_leave_count from realtime.messages
    where topic = 'ride:'||rid_a::text and event = 'member_left'
      and payload->>'userID' = 'bbbbbbbb-0000-0000-0000-000000000002';

  -- host (user1, now alone) ends the ride
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  perform public.end_ride(rid_a);
  select (status = 'ended' and ended_at is not null) into ended_set
    from public.rides where id = rid_a;
  select ended_at into v_ended1 from public.rides where id = rid_a;

  -- idempotent: a second end_ride must not move ended_at
  perform public.end_ride(rid_a);
  select ended_at into v_ended2 from public.rides where id = rid_a;
  ended_idempotent := (v_ended1 = v_ended2);

  select count(*)::int into ride_ended_count from realtime.messages
    where topic = 'ride:'||rid_a::text and event = 'ride_ended';
  select count(*)::int into host_member_left_count from realtime.messages
    where topic = 'ride:'||rid_a::text and event = 'member_left'
      and payload->>'userID' = 'aaaaaaaa-0000-0000-0000-000000000001';

  -- Ride B: host leaves an empty ride -> ride_ended emitted (dissolves any straggler).
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id, join_code into rid_b, code_b from public.create_ride('{}'::jsonb);
  perform public.leave_ride(rid_b);
  select count(*)::int into host_empty_ride_ended from realtime.messages
    where topic = 'ride:'||rid_b::text and event = 'ride_ended';
end;
$$;

create temp table ef as select * from pg_temp.end_flow();
select is((select ended_set from ef), true, 'end_ride sets status=ended and ended_at');
select is((select ended_idempotent from ef), true, 'second end_ride does not move ended_at');
select cmp_ok((select ride_ended_count from ef), '>=', 1, 'end_ride emits ride_ended');
select is((select host_member_left_count from ef), 0, 'end_ride does NOT emit member_left for the host');
select cmp_ok((select member_leave_count from ef), '>=', 1, 'leave_ride by a plain member still emits member_left');
select cmp_ok((select host_empty_ride_ended from ef), '>=', 1, 'host leaving an empty ride emits ride_ended');
select * from finish();
rollback;
