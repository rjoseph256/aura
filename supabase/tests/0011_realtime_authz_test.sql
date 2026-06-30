begin;
select plan(3);
select isnt(
  (select count(*) from pg_policies
     where schemaname = 'realtime' and tablename = 'messages'
       and policyname = 'ride members read broadcast'), 0::bigint,
  'broadcast read policy exists');
select ok(
  (select qual from pg_policies
     where policyname = 'ride members read broadcast') like '%is_ride_member%',
  'policy gates on is_ride_member');
select ok(
  (select qual from pg_policies
     where policyname = 'ride members read broadcast') like '%broadcast%',
  'policy is scoped to the broadcast extension');
select * from finish();
rollback;
