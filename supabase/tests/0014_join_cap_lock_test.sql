begin;
select plan(3);
insert into auth.users (instance_id, id, aud, role, email)
select '00000000-0000-0000-0000-000000000000',
       ('aaaaaaaa-0000-0000-0000-00000000000'||g)::uuid,
       'authenticated','authenticated','u'||g||'@test.dev'
from generate_series(1,9) g;

create function pg_temp.cap_flow(out final_members int, out ninth_rejected boolean, out advisory_held boolean)
language plpgsql security definer set search_path = '' as $$
declare rid uuid; code text; g int;
begin
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id, join_code into rid, code from public.create_ride('{}'::jsonb);
  for g in 2..8 loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', ('aaaaaaaa-0000-0000-0000-00000000000'||g)::uuid)::text, true);
    perform public.join_ride(code);
  end loop;
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000009"}', true);
  begin perform public.join_ride(code); ninth_rejected := false;
  exception when others then ninth_rejected := true; end;
  select count(*)::int into final_members from public.ride_members where ride_id = rid;
  -- The per-ride advisory lock taken inside join_ride is xact-scoped (a SECURITY DEFINER
  -- call is not a transaction boundary), so it is still held in this uncommitted test
  -- transaction. Pin to THIS backend AND the exact key so the assertion proves the
  -- per-ride lock, not just "some advisory lock somewhere is held".
  select exists(
    select 1 from pg_locks
    where locktype = 'advisory'
      and pid = pg_backend_pid()
      and ((classid::bigint << 32) | (objid::bigint & 4294967295))
          = hashtextextended(rid::text, 0)
  ) into advisory_held;
end; $$;

create temp table cf as select * from pg_temp.cap_flow();
select is((select final_members from cf), 8, 'exactly 8 members after a 9th attempt');
select is((select ninth_rejected from cf), true, '9th join rejected by the cap');
select is((select advisory_held from cf), true, 'join_ride takes a per-ride advisory lock');
select * from finish();
rollback;
