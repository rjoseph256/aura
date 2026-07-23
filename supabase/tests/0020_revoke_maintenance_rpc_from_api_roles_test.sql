begin;
select plan(6);

-- The cron-only maintenance RPCs must not be executable by ANY API-reachable
-- role. On hosted Supabase these roles hold explicit grants (from ALTER DEFAULT
-- PRIVILEGES), so we assert the effective privilege is gone for each, not just
-- for PUBLIC. Only the owner (postgres, which pg_cron runs as) keeps EXECUTE.
select function_privs_are(
  'public', 'sweep_stale_rides', '{}'::text[], 'anon', '{}'::text[],
  'anon cannot execute sweep_stale_rides');
select function_privs_are(
  'public', 'sweep_stale_rides', '{}'::text[], 'authenticated', '{}'::text[],
  'authenticated cannot execute sweep_stale_rides');
select function_privs_are(
  'public', 'sweep_stale_rides', '{}'::text[], 'service_role', '{}'::text[],
  'service_role cannot execute sweep_stale_rides');
select function_privs_are(
  'public', 'reap_expired_rides', '{}'::text[], 'anon', '{}'::text[],
  'anon cannot execute reap_expired_rides');
select function_privs_are(
  'public', 'reap_expired_rides', '{}'::text[], 'authenticated', '{}'::text[],
  'authenticated cannot execute reap_expired_rides');
select function_privs_are(
  'public', 'reap_expired_rides', '{}'::text[], 'service_role', '{}'::text[],
  'service_role cannot execute reap_expired_rides');

select * from finish();
rollback;
