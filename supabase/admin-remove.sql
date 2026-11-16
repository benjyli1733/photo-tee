-- Photo Tee: let the organiser remove a reservation (and its photo file)
-- Run once in Supabase → SQL Editor → New query → paste → Run. Safe to re-run.
-- Needs admin-and-email.sql to have been run first (it uses is_admin()).

-- Deletes the reservation and frees its squares. Returns the photo's file path
-- so the page can then delete the file from storage.
create or replace function public.admin_delete(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_path text;
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  select photo_path into v_path from reservations where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  delete from reserved_cells where reservation_id = p_id;
  delete from reservations where id = p_id;
  return v_path;
end $$;
revoke all on function public.admin_delete(uuid) from public, anon;
grant execute on function public.admin_delete(uuid) to authenticated;

-- Allow the organiser (only) to delete files from the photos bucket
drop policy if exists "organiser can delete photos" on storage.objects;
create policy "organiser can delete photos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'photos' and public.is_admin());
