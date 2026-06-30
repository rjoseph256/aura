-- The `authenticated` role needs base table privileges to reach the tables at
-- all; RLS then restricts WHICH rows. All writes go through SECURITY DEFINER
-- functions (run as the owner), so authenticated needs only SELECT here.
-- (join_attempts is touched only inside join_ride, so no direct grant.)
grant select on public.profiles to authenticated;
grant select on public.rides to authenticated;
grant select on public.ride_members to authenticated;
grant select on public.ride_track_points to authenticated;
