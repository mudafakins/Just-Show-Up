-- Just Show Up! database schema.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Safe to re-run.

-- ---------------------------------------------------------------- tables

create table if not exists public.teams (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  email       text not null unique,
  name        text not null default '',
  color_index int  not null default 0,
  -- One team per person in v1.
  team_id     uuid references public.teams (id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.invites (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid not null references public.teams (id) on delete cascade,
  email      text not null,
  invited_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (team_id, email)
);

-- ---------------------------------------------------------------- helpers

-- The caller's team. SECURITY DEFINER so row-level policies can use it
-- without recursing into the profiles policy.
create or replace function public.my_team_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select team_id from public.profiles where id = auth.uid()
$$;

-- ---------------------------------------------------------------- row-level security
-- Reads are limited to your own team. All writes go through the functions below.

alter table public.teams    enable row level security;
alter table public.profiles enable row level security;
alter table public.invites  enable row level security;

drop policy if exists "read own team" on public.teams;
create policy "read own team" on public.teams
  for select to authenticated
  using (id = public.my_team_id());

drop policy if exists "read self and teammates" on public.profiles;
create policy "read self and teammates" on public.profiles
  for select to authenticated
  using (id = auth.uid() or team_id = public.my_team_id());

drop policy if exists "read team invites" on public.invites;
create policy "read team invites" on public.invites
  for select to authenticated
  using (team_id = public.my_team_id());

-- ---------------------------------------------------------------- sign-up

-- When someone signs in for the first time: create their profile and either
-- join the team that invited them or start a team of their own.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_email text := lower(new.email);
  v_team  uuid;
  v_name  text := initcap(replace(replace(split_part(new.email, '@', 1), '.', ' '), '_', ' '));
begin
  select team_id into v_team
    from public.invites where email = v_email
    order by created_at limit 1;

  if v_team is null then
    insert into public.teams (name, created_by)
      values (v_name || '''s team', new.id)
      returning id into v_team;
  end if;

  insert into public.profiles (id, email, name, color_index, team_id)
    values (new.id, v_email, v_name, floor(random() * 8)::int, v_team)
    on conflict (id) do nothing;

  delete from public.invites where email = v_email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Anyone who signed up before this schema existed has no profile yet: create one now.
do $$
declare
  u      record;
  v_team uuid;
  v_name text;
begin
  for u in
    select au.id, lower(au.email) as email
      from auth.users au
      left join public.profiles p on p.id = au.id
     where p.id is null and au.email is not null
  loop
    v_name := initcap(replace(replace(split_part(u.email, '@', 1), '.', ' '), '_', ' '));
    select team_id into v_team from public.invites where email = u.email order by created_at limit 1;
    if v_team is null then
      insert into public.teams (name, created_by) values (v_name || '''s team', u.id) returning id into v_team;
    end if;
    insert into public.profiles (id, email, name, color_index, team_id)
      values (u.id, u.email, v_name, floor(random() * 8)::int, v_team);
    delete from public.invites where email = u.email;
    v_team := null;
  end loop;
end;
$$;

-- ---------------------------------------------------------------- actions the app calls

-- Invite a teammate by email. Returns:
--   'added'   they already had an account (alone in their own team) and were moved into yours
--   'invited' they have no account yet; they join your team on first sign-in
create or replace function public.invite_teammate(invite_email text)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_email   text := lower(trim(invite_email));
  v_team    uuid := public.my_team_id();
  v_target  public.profiles%rowtype;
  v_members int;
begin
  if v_team is null then
    raise exception 'You are not on a team yet.';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'That does not look like an email address.';
  end if;

  select * into v_target from public.profiles where email = v_email;

  if not found then
    insert into public.invites (team_id, email, invited_by)
      values (v_team, v_email, auth.uid())
      on conflict (team_id, email) do nothing;
    return 'invited';
  end if;

  if v_target.team_id = v_team then
    raise exception 'They are already on your team.';
  end if;

  select count(*) into v_members from public.profiles where team_id = v_target.team_id;
  if v_members > 1 then
    raise exception 'They are already on another team.';
  end if;

  update public.profiles set team_id = v_team where id = v_target.id;
  delete from public.teams where id = v_target.team_id;
  return 'added';
end;
$$;

create or replace function public.cancel_invite(invite_email text)
returns void
language sql security definer set search_path = public
as $$
  delete from public.invites
   where team_id = public.my_team_id() and email = lower(trim(invite_email))
$$;

create or replace function public.set_my_name(new_name text)
returns void
language sql security definer set search_path = public
as $$
  update public.profiles set name = left(trim(new_name), 40) where id = auth.uid()
$$;

revoke all on function public.invite_teammate(text) from public, anon;
revoke all on function public.cancel_invite(text)   from public, anon;
revoke all on function public.set_my_name(text)     from public, anon;
revoke all on function public.my_team_id()          from public, anon;
grant execute on function public.invite_teammate(text) to authenticated;
grant execute on function public.cancel_invite(text)   to authenticated;
grant execute on function public.set_my_name(text)     to authenticated;
grant execute on function public.my_team_id()          to authenticated;
