begin;
select plan(7);
select has_table('public', 'profiles', 'profiles exists');
select has_table('public', 'rides', 'rides exists');
select has_table('public', 'ride_members', 'ride_members exists');
select has_table('public', 'ride_track_points', 'ride_track_points exists');
select has_table('public', 'join_attempts', 'join_attempts exists');
select col_is_pk('public', 'ride_members', array['ride_id','user_id'], 'members composite PK');
select index_is_unique('public', 'ride_track_points', 'ride_track_points_dedup_key',
  'track point idempotency unique index');
select * from finish();
rollback;
