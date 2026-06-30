-- Driven through a pg_temp SECURITY DEFINER helper (SP1 pattern). Asserts that a
-- member's record_track_points emits a 'position' row into realtime.messages, and a
-- non-member is rejected. The daily realtime.messages partition is created in setup,
-- since realtime.send drops (warns) rather than errors when no partition exists.
begin;
select plan(4);

-- Ensure today's realtime.messages partition exists. In a pure pgTAP run no WebSocket
-- client ever connects, so Realtime never creates the daily partition; without it
-- realtime.send silently warns and drops the row (the test would then see 0 with no
-- diagnostic). Bounds use ::timestamp because realtime.messages partitions by
-- inserted_at (timestamp without time zone). Guard + assert so a partition problem
-- fails loudly here, not as a phantom 0 at the broadcast assertion.
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

create function pg_temp.broadcast_flow(out position_rows int, out newest_motion text, out nonmember_rejected boolean)
language plpgsql security definer set search_path = '' as $$
declare rid uuid;
begin
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id into rid from public.create_ride('{}'::jsonb);
  perform public.record_track_points(rid, jsonb_build_array(
    jsonb_build_object('recorded_at', now()::text, 'lat', 37.0, 'lon', -122.0,
                       'progress_meters', 10.0, 'motion_state', 'moving')));
  select count(*)::int into position_rows from realtime.messages
    where topic = 'ride:'||rid::text and event = 'position';
  -- prove the payload shape, not just that some row landed
  select payload->>'motionState' into newest_motion from realtime.messages
    where topic = 'ride:'||rid::text and event = 'position'
    order by inserted_at desc limit 1;
  -- user 2 is not a member -> rejected
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  begin
    perform public.record_track_points(rid, jsonb_build_array(
      jsonb_build_object('recorded_at', now()::text, 'lat', 1.0, 'lon', 1.0, 'progress_meters', 0.0)));
    nonmember_rejected := false;
  exception when others then nonmember_rejected := true; end;
end; $$;

create temp table bf as select * from pg_temp.broadcast_flow();
select cmp_ok((select position_rows from bf), '>=', 1, 'member record broadcasts a position');
select is((select newest_motion from bf), 'moving', 'broadcast payload carries motionState');
select is((select nonmember_rejected from bf), true, 'non-member record is rejected');
select * from finish();
rollback;
