-- Gate subscription to a private ride channel on ride membership. Realtime evaluates
-- this SELECT policy on realtime.messages at channel-join time (with the user's JWT).
-- The topic guard + safe parser (0010) make a bad/foreign topic deny cleanly.
create policy "ride members read broadcast" on realtime.messages
  for select
  to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and realtime.topic() like 'ride:%'
    and (select public.is_ride_member(public.ride_id_from_topic(realtime.topic())))
  );
