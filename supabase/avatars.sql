-- Profile pictures. Run once in the Supabase dashboard: SQL Editor -> New query -> Run.
-- Safe to re-run.
--
-- Photos live in the public "avatars" storage bucket, each in a folder named after
-- its owner's user id (e.g. "<user id>/1731900000.jpg"). Only you can add, replace
-- or delete files in your own folder. The app shrinks photos to 256x256 JPEG first.

alter table public.profiles add column if not exists avatar_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg', 'image/png'])
on conflict (id) do update
  set public = true, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg', 'image/png'];

drop policy if exists "upload own avatar" on storage.objects;
create policy "upload own avatar" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "replace own avatar" on storage.objects;
create policy "replace own avatar" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "delete own avatar" on storage.objects;
create policy "delete own avatar" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- Uploading with "upsert" also needs to read your own files.
drop policy if exists "read own avatar" on storage.objects;
create policy "read own avatar" on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- Sets (or, with null, removes) my photo. Only paths in my own folder are accepted.
create or replace function public.set_my_avatar(path text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  if path is not null and (path not like auth.uid()::text || '/%' or length(path) > 200) then
    raise exception 'That photo is not yours.';
  end if;
  update public.profiles set avatar_path = path where id = auth.uid();
end;
$$;

revoke all on function public.set_my_avatar(text) from public, anon;
grant execute on function public.set_my_avatar(text) to authenticated;

notify pgrst, 'reload schema';
