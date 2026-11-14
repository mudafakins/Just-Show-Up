-- Just Show Up! database schema (name + team code, no email).
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Safe to re-run. Also requires: Authentication -> Sign In / Providers ->
-- "Allow anonymous sign-ins" switched on.

-- ---------------------------------------------------------------- clean up the earlier email-based design

drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user();
drop function if exists public.invite_teammate(text);
drop function if exists public.cancel_invite(text);
drop table if exists public.invites;

-- ---------------------------------------------------------------- tables

create table if not exists public.teams (
  id         uuid primary key default gen_random_uuid(),
  code       text unique,
  created_at timestamptz not null default now()
);
alter table public.teams add column if not exists code text unique;
alter table public.teams drop column if exists name;
alter table public.teams drop column if exists created_by;

create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  name        text not null default '',
  color_index int  not null default 0,
  -- One team per person in v1.
  team_id     uuid references public.teams (id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.profiles drop column if exists email;

-- ---------------------------------------------------------------- helpers

-- The caller's team. SECURITY DEFINER so row-level policies can use it
-- without recursing into the profiles policy.
create or replace function public.my_team_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select team_id from public.profiles where id = auth.uid()
$$;

-- A code that is easy to read aloud, e.g. MANGO-482913.
create or replace function public.new_team_code()
returns text
language plpgsql security definer set search_path = public
as $$
declare
  words text[] := array[
    'MANGO','TIGER','PIXEL','COMET','MAPLE','OTTER','LEMON','ROBIN','CEDAR','NOVA',
    'PANDA','RIVER','EMBER','LOTUS','FALCON','CORAL','BISON','HAZEL','ORBIT','QUARTZ',
    'WILLOW','KOALA','SUNNY','BREEZE','GINGER','MARBLE','PEPPER','ROCKET','SALSA','TULIP'];
  v_code text;
begin
  loop
    v_code := words[1 + floor(random() * array_length(words, 1))::int]
              || '-' || lpad(floor(random() * 1000000)::int::text, 6, '0');
    exit when not exists (select 1 from public.teams where code = v_code);
  end loop;
  return v_code;
end;
$$;

create or replace function public.clean_name(raw text)
returns text
language sql immutable
as $$
  select left(trim(regexp_replace(coalesce(raw, ''), '\s+', ' ', 'g')), 40)
$$;

-- ---------------------------------------------------------------- row-level security
-- Reads are limited to your own team. All writes go through the functions below.

alter table public.teams    enable row level security;
alter table public.profiles enable row level security;

drop policy if exists "read own team" on public.teams;
create policy "read own team" on public.teams
  for select to authenticated
  using (id = public.my_team_id());

drop policy if exists "read self and teammates" on public.profiles;
create policy "read self and teammates" on public.profiles
  for select to authenticated
  using (id = auth.uid() or team_id = public.my_team_id());

-- ---------------------------------------------------------------- actions the app calls

-- Start a new team. Returns its code.
create or replace function public.create_team(my_name text)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_name text := public.clean_name(my_name);
  v_team uuid;
  v_code text := public.new_team_code();
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  if v_name = '' then raise exception 'Please enter your name.'; end if;

  insert into public.teams (code) values (v_code) returning id into v_team;

  insert into public.profiles (id, name, color_index, team_id)
    values (auth.uid(), v_name, floor(random() * 8)::int, v_team)
    on conflict (id) do update set name = excluded.name, team_id = excluded.team_id;

  return v_code;
end;
$$;

-- Join an existing team with its code.
create or replace function public.join_team(my_name text, team_code text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_name text := public.clean_name(my_name);
  v_code text := upper(regexp_replace(coalesce(team_code, ''), '\s', '', 'g'));
  v_team uuid;
  v_size int;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  if v_name = '' then raise exception 'Please enter your name.'; end if;

  -- Slow down guessing of team codes.
  perform pg_sleep(0.5);

  select id into v_team from public.teams where code = v_code;
  if v_team is null then
    raise exception 'No team has that code. Check it and try again.';
  end if;

  select count(*) into v_size from public.profiles where team_id = v_team;
  if v_size >= 25 then
    raise exception 'That team is full.';
  end if;

  insert into public.profiles (id, name, color_index, team_id)
    values (auth.uid(), v_name, v_size % 8, v_team)
    on conflict (id) do update set name = excluded.name, team_id = excluded.team_id;
end;
$$;

create or replace function public.set_my_name(new_name text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if public.clean_name(new_name) = '' then raise exception 'Please enter your name.'; end if;
  update public.profiles set name = public.clean_name(new_name) where id = auth.uid();
end;
$$;

-- Remove a teammate (or yourself, to leave). An emptied team is deleted.
create or replace function public.remove_from_team(member uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_team uuid := public.my_team_id();
begin
  if v_team is null then return; end if;
  update public.profiles set team_id = null where id = member and team_id = v_team;
  if not exists (select 1 from public.profiles where team_id = v_team) then
    delete from public.teams where id = v_team;
  end if;
end;
$$;

-- Replace the team code so the old one stops working. Returns the new code.
create or replace function public.regenerate_team_code()
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_team uuid := public.my_team_id();
  v_code text := public.new_team_code();
begin
  if v_team is null then raise exception 'You are not on a team.'; end if;
  update public.teams set code = v_code where id = v_team;
  return v_code;
end;
$$;

revoke all on function public.my_team_id()               from public, anon;
revoke all on function public.new_team_code()            from public, anon, authenticated;
revoke all on function public.create_team(text)          from public, anon;
revoke all on function public.join_team(text, text)      from public, anon;
revoke all on function public.set_my_name(text)          from public, anon;
revoke all on function public.remove_from_team(uuid)     from public, anon;
revoke all on function public.regenerate_team_code()     from public, anon;
grant execute on function public.my_team_id()            to authenticated;
grant execute on function public.create_team(text)       to authenticated;
grant execute on function public.join_team(text, text)   to authenticated;
grant execute on function public.set_my_name(text)       to authenticated;
grant execute on function public.remove_from_team(uuid)  to authenticated;
grant execute on function public.regenerate_team_code()  to authenticated;

-- Make the API notice the new tables and functions straight away.
notify pgrst, 'reload schema';
