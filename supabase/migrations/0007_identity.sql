-- Idempotent: handle_new_user may already exist (applied early during dev).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id) on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.upsert_display_name(p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'unauthorized'; end if;
  update public.profiles set display_name = left(p_name, 40) where id = v_uid;
end;
$$;
revoke execute on function public.upsert_display_name(text) from public;
grant execute on function public.upsert_display_name(text) to authenticated;

create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'unauthorized'; end if;
  -- Delete the profile; ON DELETE CASCADE clears all of this user's public ride
  -- data (hosted rides, memberships, track points, join attempts). The auth.users
  -- row itself is removed out-of-band via the Auth admin API (a delete-account edge
  -- function) — a postgres-owned SECURITY DEFINER function cannot delete from
  -- auth.users on the hosted project (auth.users is owned by supabase_auth_admin).
  delete from public.profiles where id = v_uid;
end;
$$;
revoke execute on function public.delete_account() from public;
grant execute on function public.delete_account() to authenticated;
