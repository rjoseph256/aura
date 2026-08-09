-- ROH-114: make "a ride with no route is an open ride" an invariant, not a convention.
--
-- 0021 DERIVES `kind` in create_ride's body and enforces nothing. Any other writer — a
-- service-role statement, a backfill, a future RPC — can produce either mismatch, and both
-- are user-visible failures rather than tidiness problems:
--
--   kind='route' with no route  -> the client forks on kind (D4.1), routes to the navigate
--                                  container, finds no route, and shows "Couldn't load this
--                                  ride's route." That is the dead end this whole feature
--                                  exists to remove, reachable through a legal row.
--   kind='open' with a route    -> the lobby says "no destination" while a course is drawn.
--
-- The jsonb 'null' scalar is deliberately treated as absence, because that is what the client
-- does. `GroupRideRow.routeData()` folds BOTH SQL NULL and `.null` to nil
-- (SupabaseGroupRideBackend.swift), while SQL's `route is null` is false for the scalar. A
-- constraint written only against `is null` would therefore declare legal exactly the row that
-- decodes as a route ride carrying no route — the first case above. Matching the client's rule
-- is the point; a constraint that disagrees with its only reader is decoration.
--
-- Plain ADD CONSTRAINT rather than NOT VALID + VALIDATE: every row predating 0021 has a
-- non-null route and takes `kind`'s 'route' default, so the table is already conformant. If
-- this fails on a real project, a row is already broken and that is worth learning here rather
-- than from a rider stuck on an error screen.

alter table public.rides
  add constraint rides_kind_matches_route
  check ((kind = 'open') = (route is null or route = 'null'::jsonb));
