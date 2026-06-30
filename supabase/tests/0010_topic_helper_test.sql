begin;
select plan(4);
select is(public.ride_id_from_topic('ride:aaaaaaaa-0000-0000-0000-000000000001'),
          'aaaaaaaa-0000-0000-0000-000000000001'::uuid, 'parses a ride topic');
select is(public.ride_id_from_topic('lobby:123'), null, 'non-ride topic -> null');
select is(public.ride_id_from_topic('ride:not-a-uuid'), null, 'malformed uuid -> null');
select is(public.ride_id_from_topic(null), null, 'null topic -> null');
select * from finish();
rollback;
