begin;
select plan(3);
-- Partition guard + assertion (see Task 3 test for the rationale: realtime.send drops
-- silently when today's partition is absent, which a pure pgTAP run never creates).
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

-- Drives both broadcast paths: a non-host member leaves (leave_ride), and the host
-- ends the ride (end_ride). Each must emit a member_left row for the acting user.
create function pg_temp.leave_flow(out leave_rows int, out end_rows int)
language plpgsql security definer set search_path = '' as $$
declare rid uuid; code text;
begin
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id, join_code into rid, code from public.create_ride('{}'::jsonb);
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  perform public.join_ride(code);
  perform public.leave_ride(rid);
  select count(*)::int into leave_rows from realtime.messages
    where topic = 'ride:'||rid::text and event = 'member_left'
      and payload->>'userID' = 'bbbbbbbb-0000-0000-0000-000000000002';
  -- host (user 1, still the only remaining member) ends the ride
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  perform public.end_ride(rid);
  select count(*)::int into end_rows from realtime.messages
    where topic = 'ride:'||rid::text and event = 'member_left'
      and payload->>'userID' = 'aaaaaaaa-0000-0000-0000-000000000001';
end; $$;

create temp table mlf as select * from pg_temp.leave_flow();
select cmp_ok((select leave_rows from mlf), '>=', 1, 'leave_ride broadcasts member_left for the leaver');
select cmp_ok((select end_rows from mlf), '>=', 1, 'end_ride broadcasts member_left for the host');
select * from finish();
rollback;
