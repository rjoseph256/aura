begin;
select plan(4);

-- The cron-only maintenance RPCs must not be executable by the client-facing
-- roles. PUBLIC's default EXECUTE grant is revoked in 0019, so neither anon nor
-- authenticated may call these RLS-bypassing cleanup routines via PostgREST.
select function_privs_are(
  'public', 'sweep_stale_rides', '{}'::text[], 'anon', '{}'::text[],
  'anon cannot execute sweep_stale_rides');
select function_privs_are(
  'public', 'sweep_stale_rides', '{}'::text[], 'authenticated', '{}'::text[],
  'authenticated cannot execute sweep_stale_rides');
select function_privs_are(
  'public', 'reap_expired_rides', '{}'::text[], 'anon', '{}'::text[],
  'anon cannot execute reap_expired_rides');
select function_privs_are(
  'public', 'reap_expired_rides', '{}'::text[], 'authenticated', '{}'::text[],
  'authenticated cannot execute reap_expired_rides');

select * from finish();
rollback;
