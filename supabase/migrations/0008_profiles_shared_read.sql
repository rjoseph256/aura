-- Spec §5: a member may read the profile (display name) of anyone they currently
-- share a ride with — needed for the live roster in SP2/SP3. SECURITY DEFINER +
-- derives auth.uid() itself, so it bypasses RLS internally (no recursion with the
-- profiles/ride_members policies), same safe pattern as is_ride_member.
create function public.shares_ride_with(p_other uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.ride_members me
    join public.ride_members them on them.ride_id = me.ride_id
    where me.user_id = (select auth.uid()) and them.user_id = p_other
  );
$$;
revoke execute on function public.shares_ride_with(uuid) from public;
grant execute on function public.shares_ride_with(uuid) to authenticated;

-- Additive permissive policy: ORs with profiles_select_self, so a user can read
-- their own profile plus those of current co-riders.
create policy profiles_select_shared on public.profiles
  for select to authenticated using ((select public.shares_ride_with(id)));
