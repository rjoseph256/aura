-- Mark an active ride ended when its last activity is older than 3 hours.
-- sweep_stale_rides / reap_expired_rides are cron-only (called by the pg_cron
-- scheduler, a superuser); intentionally not granted to authenticated.
create function public.sweep_stale_rides()
returns void
language sql
security definer
set search_path = ''
as $$
  update public.rides r
    set status = 'ended', ended_at = now(),
        expires_at = least(now() + interval '48 hours',
          coalesce((select max(recorded_at) from public.ride_track_points p
                    where p.ride_id = r.id), r.created_at) + interval '48 hours')
  where r.status = 'active'
    and coalesce(
      (select max(recorded_at) from public.ride_track_points p where p.ride_id = r.id),
      r.created_at) < now() - interval '3 hours';
$$;

create function public.reap_expired_rides()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.rides where expires_at < now();
  delete from public.join_attempts where attempted_at < now() - interval '1 hour';
$$;

-- Enable pg_cron and schedule both functions every 5 minutes. Wrapped so a local
-- test stack without pg_cron preloaded still applies this migration cleanly (the
-- whole block no-ops); the real schedule lands on the remote project via db push.
-- The sweep/reap functions are tested by calling them DIRECTLY (see the test).
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('group-ride-sweep', '*/5 * * * *',
    $sql$ select public.sweep_stale_rides(); select public.reap_expired_rides(); $sql$);
exception when others then null;  -- pg_cron unavailable in local stack
end $$;
