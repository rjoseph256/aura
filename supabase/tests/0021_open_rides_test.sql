-- ROH-114: open rides through the RPCs, plus 0022's kind/route invariant.
--
-- Pattern follows 0003 and 0014: seed auth.users as the owner, drive the whole multi-identity
-- flow through ONE pg_temp SECURITY DEFINER helper using set_config, and materialise the
-- result into a temp table so the flow runs exactly once. This is not stylistic. Switching to
-- `set local role authenticated` and reading `public.rides` directly does not work here:
-- rides_select is members-only (0002_membership_rls.sql:63-64), so a guest reading join_code
-- back out gets NULL, and every join assertion would then be testing the ride-not-found guard
-- instead of the thing it names. 0003's header records the same reasoning.
--
-- The constraint assertions use plpgsql exception blocks rather than pgTAP's throws_ok. There
-- is no throws_ok anywhere in this suite to copy, and its 3-argument form treats a five-byte
-- second argument as a SQLSTATE and the THIRD as the expected error message, not a
-- description — an easy way to write an assertion that fails on message text while looking
-- like it tests behaviour. `when check_violation` says what it means.

begin;
select plan(7);

insert into auth.users (instance_id, id, aud, role, email)
select '00000000-0000-0000-0000-000000000000',
       ('bbbbbbbb-0000-0000-0000-00000000000'||g)::uuid,
       'authenticated','authenticated','o'||g||'@test.dev'
from generate_series(1,2) g;

create function pg_temp.open_ride_flow(
  out open_kind text,
  out open_route_is_null boolean,
  out route_kind text,
  out old_client_rejected boolean,
  out new_client_joined boolean,
  out losing_route_rejected boolean,
  out jsonb_null_route_rejected boolean)
language plpgsql security definer set search_path = '' as $$
declare
  v_open public.rides;
  v_route public.rides;
begin
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000001"}', true);

  -- p_route OMITTED, not passed as null. Omission is what produces a real SQL NULL; a jsonb
  -- 'null' scalar satisfies `is not null` and would come back as four bytes to the next joiner.
  select * into v_open from public.create_ride();
  open_kind := v_open.kind;
  open_route_is_null := v_open.route is null;

  -- Identified by the returned row, NOT by `order by created_at desc limit 1`: now() is
  -- transaction_timestamp() and is identical for both rides inside this test transaction, so
  -- ordering by it is a coin flip.
  select * into v_route from public.create_ride('{"distanceMeters": 8000}'::jsonb);
  route_kind := v_route.kind;

  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);

  -- A build predating 0021 sends no capability flag, so the default false applies.
  begin
    perform public.join_ride(v_open.join_code, false);
    old_client_rejected := false;
  exception when others then old_client_rejected := true; end;

  begin
    perform public.join_ride(v_open.join_code, true);
    new_client_joined := true;
  exception when others then new_client_joined := false; end;

  -- 0022, both ways a route ride can silently lose its route. Either would decode client-side
  -- as kind='route' with no route bytes, which is the D4.1 error screen.
  begin
    update public.rides set route = null where id = v_route.id;
    losing_route_rejected := false;
  exception when check_violation then losing_route_rejected := true; end;

  begin
    update public.rides set route = 'null'::jsonb where id = v_route.id;
    jsonb_null_route_rejected := false;
  exception when check_violation then jsonb_null_route_rejected := true; end;
end; $$;

create temp table orf as select * from pg_temp.open_ride_flow();

select is((select open_kind from orf), 'open',
          'a create with p_route omitted is stored as kind = open');
select is((select open_route_is_null from orf), true,
          'an open ride holds SQL NULL, not a jsonb null scalar');
select is((select route_kind from orf), 'route',
          'a create WITH a route derives kind = route');
select is((select old_client_rejected from orf), true,
          'a client that does not declare open-ride support is refused, with the generic oracle');
select is((select new_client_joined from orf), true,
          'a client that does declare it joins the open ride');
select is((select losing_route_rejected from orf), true,
          'a route ride cannot drop its route to NULL and keep kind = route');
select is((select jsonb_null_route_rejected from orf), true,
          'a route ride cannot drop its route to a jsonb null scalar either');

select * from finish();
rollback;
