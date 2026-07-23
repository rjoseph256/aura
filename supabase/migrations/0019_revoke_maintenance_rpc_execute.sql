-- Security fix: lock down the cron-only maintenance RPCs.
-- sweep_stale_rides / reap_expired_rides are SECURITY DEFINER functions in the
-- API-exposed `public` schema. Postgres grants EXECUTE to PUBLIC by default, and
-- PUBLIC includes the anon + authenticated roles, so any client bearing the
-- shipped publishable key could invoke these RLS-bypassing cleanup routines via
-- PostgREST (POST /rest/v1/rpc/...). 0006 documented the intent ("cron-only")
-- in a comment but never revoked the default grant. Only the pg_cron scheduler
-- (a superuser, which ignores these grants) needs to run them, so revoke from
-- PUBLIC with no re-grant — matching every other function in this schema.
revoke execute on function public.sweep_stale_rides() from public;
revoke execute on function public.reap_expired_rides() from public;
