-- Membership primitive. Derives auth.uid() itself; no caller-supplied uid.
create function public.is_ride_member(p_ride_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.ride_members m
    where m.ride_id = p_ride_id and m.user_id = (select auth.uid())
  );
$$;
revoke execute on function public.is_ride_member(uuid) from public;
grant execute on function public.is_ride_member(uuid) to authenticated;

-- Private join-code generator: 8 chars, charset excludes O 0 I 1 L.
create function public.gen_join_code()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  code text;
begin
  loop
    code := '';
    for i in 1..8 loop
      code := code || substr(alphabet, 1 + floor(random()*length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.rides r where r.join_code = code);
  end loop;
  return code;
end;
$$;
revoke execute on function public.gen_join_code() from public;

create function public.create_ride(p_route jsonb)
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
  insert into public.rides (host_id, join_code, route, expires_at)
  values (v_uid, public.gen_join_code(), p_route, now() + interval '36 hours')
  returning * into v_ride;
  insert into public.ride_members (ride_id, user_id, role)
  values (v_ride.id, v_uid, 'host');
  return v_ride;
end;
$$;
revoke execute on function public.create_ride(jsonb) from public;
grant execute on function public.create_ride(jsonb) to authenticated;

-- RLS: members-only reads, writes only through functions.
create policy rides_select on public.rides
  for select to authenticated using ((select public.is_ride_member(id)));

create policy members_select on public.ride_members
  for select to authenticated using ((select public.is_ride_member(ride_id)));

create policy profiles_select_self on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy profiles_update_self on public.profiles
  for update to authenticated using (id = (select auth.uid()));
