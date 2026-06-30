-- Safe parser for Realtime channel topics of the form 'ride:<uuid>'. Returns null
-- (never raises) on any non-ride or malformed topic, so the realtime.messages RLS
-- policy that calls it denies cleanly instead of failing the whole channel join.
create function public.ride_id_from_topic(p_topic text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_topic is null or p_topic not like 'ride:%' then
    return null;
  end if;
  return substring(p_topic from 6)::uuid;
exception
  when others then
    return null;
end;
$$;
grant execute on function public.ride_id_from_topic(text) to authenticated;
