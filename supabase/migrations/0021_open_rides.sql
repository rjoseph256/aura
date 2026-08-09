-- ROH-114: rides with no destination ("let's just go ride around").
--
-- `route` becomes nullable and `rides.kind` records which sort of ride this is. Kind is
-- DERIVED in create_ride's body rather than taken as a parameter: a new parameter would
-- change the signature, which `create or replace` cannot do, and would drag the whole
-- drop/recreate/re-grant dance below along with it for no gain.
--
-- The existing `check (pg_column_size(route) < 262144)` needs no edit. A CHECK constraint is
-- satisfied whenever its expression is not false, and `pg_column_size` is strict, so a NULL
-- route yields NULL and the check passes.

alter table public.rides alter column route drop not null;
alter table public.rides add column kind text not null default 'route'
  check (kind in ('route', 'open'));

-- p_route gains a default so the client can OMIT it for an open ride. Omission is what
-- produces a real SQL NULL; sending a JSON null would store the jsonb scalar 'null', which
-- satisfies `is not null` and comes back as four bytes to the next joiner.
-- Signature is unchanged (a default is not part of it), so create-or-replace applies and the
-- grants from 0002 still hold.
create or replace function public.create_ride(p_route jsonb default null)
returns public.rides
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_ride public.rides;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  insert into public.rides (host_id, join_code, route, kind, expires_at)
  values (v_uid, public.gen_join_code(), p_route,
          case when p_route is null then 'open' else 'route' end,
          now() + interval '36 hours')
  returning * into v_ride;
  insert into public.ride_members (ride_id, user_id, role)
  values (v_ride.id, v_uid, 'host');
  return v_ride;
end;
$$;

-- join_ride gains a client-capability argument so a build that predates this migration cannot
-- land in an open ride. Without it, an old client joining one decodes SQL NULL to AnyJSON.null,
-- fails its Route decode, and calls leave_ride — removed from the ride server-side, with each
-- retry burning a join_attempts row toward the rate limit. It now gets the same generic
-- 'join failed' as any other rejection, which is wrong but harmless.
--
-- This one DOES change the signature, so create-or-replace would leave two overloads and a
-- positional single-argument call would raise "function is not unique" — which every existing
-- pgTAP file calling `join_ride(code)` would hit immediately. Drop, recreate, re-grant.
-- Body is otherwise identical to 0014 (advisory lock, rate limit, cap of 8, idempotent re-join).
drop function if exists public.join_ride(text);

create function public.join_ride(p_code text, p_supports_open boolean default false)
returns public.rides
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_ride public.rides;
  v_recent int;
  v_count int;
begin
  if v_uid is null then raise exception 'join failed'; end if;

  insert into public.join_attempts (user_id) values (v_uid);
  select count(*) into v_recent from public.join_attempts
    where user_id = v_uid and attempted_at > now() - interval '1 minute';
  if v_recent > 10 then raise exception 'join failed'; end if;

  select * into v_ride from public.rides
    where join_code = p_code and status = 'active';
  if v_ride.id is null then raise exception 'join failed'; end if;

  -- Same generic oracle as every other rejection: an old client learns nothing about why.
  if v_ride.kind = 'open' and not p_supports_open then raise exception 'join failed'; end if;

  if exists (select 1 from public.ride_members
             where ride_id = v_ride.id and user_id = v_uid) then
    return v_ride;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_ride.id::text, 0));

  select count(*) into v_count from public.ride_members where ride_id = v_ride.id;
  if v_count >= 8 then raise exception 'join failed'; end if;

  insert into public.ride_members (ride_id, user_id, role)
  values (v_ride.id, v_uid, 'member');

  return v_ride;
end;
$$;

revoke execute on function public.join_ride(text, boolean) from public;
grant execute on function public.join_ride(text, boolean) to authenticated;
