-- SP3: members-only roster read (user_id, display_name, role) for the live group-ride UI.
-- Names never travel on the realtime wire; the UI fetches them here and overlays them onto
-- the broadcast peers. Gated by is_ride_member (matches SP1); no new table, reads members+profiles.
create function public.ride_roster(p_ride_id uuid)
returns table(user_id uuid, display_name text, role text)
language sql
stable
security definer
set search_path = ''
as $$
  select m.user_id, p.display_name, m.role
  from public.ride_members m
  join public.profiles p on p.id = m.user_id
  where m.ride_id = p_ride_id
    and (select public.is_ride_member(p_ride_id));
$$;
revoke execute on function public.ride_roster(uuid) from public;
grant execute on function public.ride_roster(uuid) to authenticated;
