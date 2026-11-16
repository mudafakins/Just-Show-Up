-- Turns off starting new teams, so strangers who download the public app can't
-- create their own team on this Supabase project (and use its LiveKit minutes).
-- Joining an existing team with its code keeps working.
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- To allow new teams again, re-run create_team from schema.sql.

create or replace function public.create_team(my_name text)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  raise exception 'New teams are turned off. Ask a teammate for the team code and choose Join a Team.';
end;
$$;

notify pgrst, 'reload schema';
