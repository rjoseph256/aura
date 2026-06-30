-- join_ride behaviour is validated through a single SECURITY DEFINER helper that
-- drives the whole multi-user flow with set_config (identity), then pgTAP asserts
-- on the captured result. This is robust under pg_prove; the members-only RLS read
-- paths are covered by 0002/0004/0008. The function enforces its own authz in-body
-- (SECURITY DEFINER), so it does not depend on the caller's role here.
begin;
select plan(4);
insert into auth.users (instance_id, id, aud, role, email)
select '00000000-0000-0000-0000-000000000000',
       ('aaaaaaaa-0000-0000-0000-00000000000'||g)::uuid,
       'authenticated','authenticated','u'||g||'@test.dev'
from generate_series(1,9) g;

create function pg_temp.join_flow(
  out double_join_members int, out bad_rejected boolean,
  out final_members int, out ninth_rejected boolean)
language plpgsql security definer set search_path = '' as $$
declare rid uuid; code text; g int;
begin
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id, join_code into rid, code from public.create_ride('{}'::jsonb);
  -- user 2 joins twice (idempotent)
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000002"}', true);
  perform public.join_ride(code);
  perform public.join_ride(code);
  select count(*)::int into double_join_members from public.ride_members where ride_id = rid;
  -- bad code rejected
  begin perform public.join_ride('ZZZZZZZZ'); bad_rejected := false;
  exception when others then bad_rejected := true; end;
  -- fill to 8 (users 3..8)
  for g in 3..8 loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', ('aaaaaaaa-0000-0000-0000-00000000000'||g)::uuid)::text, true);
    perform public.join_ride(code);
  end loop;
  -- 9th join rejected by the cap
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000009"}', true);
  begin perform public.join_ride(code); ninth_rejected := false;
  exception when others then ninth_rejected := true; end;
  select count(*)::int into final_members from public.ride_members where ride_id = rid;
end; $$;

create temp table jr as select * from pg_temp.join_flow();
select is((select double_join_members from jr), 2, 'double join is idempotent (2 members)');
select is((select bad_rejected from jr), true, 'bad code fails generically');
select is((select ninth_rejected from jr), true, '9th join rejected (cap 8)');
select is((select final_members from jr), 8, 'exactly 8 members');
select * from finish();
rollback;
