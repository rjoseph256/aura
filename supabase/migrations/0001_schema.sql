-- pg_cron is created (guarded) in migration 0006, not here, so a local test stack
-- without pg_cron preloaded still applies this migration cleanly.

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Rider',
  created_at timestamptz not null default now()
);

create table public.rides (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references public.profiles(id) on delete cascade,
  join_code text not null,
  route jsonb not null check (pg_column_size(route) < 262144),
  status text not null default 'active' check (status in ('active','ended')),
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  expires_at timestamptz not null
);
-- Reaping DELETEs the ride row, which frees its code, so a FULL unique index over
-- all rides already gives "unique among non-reaped rides". Do NOT make this a
-- partial `WHERE status='active'` index — that would let an ended-but-not-reaped
-- ride's code be reused while it is still reserved.
create unique index rides_join_code_key on public.rides (join_code);

create table public.ride_members (
  ride_id uuid not null references public.rides(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check (role in ('host','member')),
  joined_at timestamptz not null default now(),
  last_seen_at timestamptz,
  primary key (ride_id, user_id)
);
create index ride_members_user on public.ride_members (user_id);

create table public.ride_track_points (
  id bigint generated always as identity primary key,
  ride_id uuid not null references public.rides(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  recorded_at timestamptz not null,
  lat double precision not null,
  lon double precision not null,
  progress_meters double precision not null
);
create unique index ride_track_points_dedup_key
  on public.ride_track_points (ride_id, user_id, recorded_at);
create index ride_track_points_ride_user on public.ride_track_points (ride_id, user_id);
create index ride_track_points_ride_time on public.ride_track_points (ride_id, recorded_at);

create table public.join_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  attempted_at timestamptz not null default now()
);
create index join_attempts_user_time on public.join_attempts (user_id, attempted_at);

-- RLS on by default; deny-all until policies land in later migrations.
alter table public.profiles enable row level security;
alter table public.rides enable row level security;
alter table public.ride_members enable row level security;
alter table public.ride_track_points enable row level security;
alter table public.join_attempts enable row level security;
