begin;
select plan(3);
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','host@test.dev'),
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-0000-0000-000000000002','authenticated','authenticated','member@test.dev'),
  ('00000000-0000-0000-0000-000000000000','cccccccc-0000-0000-0000-000000000003','authenticated','authenticated','outsider@test.dev');
update public.profiles set display_name = 'Mike'   where id = 'aaaaaaaa-0000-0000-0000-000000000001';
update public.profiles set display_name = 'Sara'   where id = 'bbbbbbbb-0000-0000-0000-000000000002';

create function pg_temp.roster_flow(out member_rows int, out has_names boolean, out outsider_rejected boolean)
language plpgsql security definer set search_path = '' as $$
declare rid uuid; code text;
begin
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  -- Capture the join_code UNDER HOST CLAIMS: rides RLS (is_ride_member) hides the row from
  -- the not-yet-member, so reading join_code after switching claims would return nothing.
  select id, join_code into rid, code from public.create_ride('{}'::jsonb);
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  perform public.join_ride(code);
  -- host reads the roster: 2 rows, names present
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select count(*)::int into member_rows from public.ride_roster(rid);
  select bool_and(display_name in ('Mike','Sara')) into has_names from public.ride_roster(rid);
  -- outsider reads: members-only guard -> 0 rows (is_ride_member false)
  perform set_config('request.jwt.claims','{"sub":"cccccccc-0000-0000-0000-000000000003"}', true);
  outsider_rejected := (select count(*) from public.ride_roster(rid)) = 0;
end; $$;

create temp table rf as select * from pg_temp.roster_flow();
select is((select member_rows from rf), 2, 'roster returns one row per member');
select is((select has_names from rf), true, 'roster returns display names');
select is((select outsider_rejected from rf), true, 'non-member gets no rows (members-only)');
select * from finish();
rollback;
