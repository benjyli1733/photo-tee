-- Photo Tee: contact emails + admin tools
-- Run once in Supabase → SQL Editor → New query → paste → Run.
-- Safe to re-run. It does not change reserve_spaces or get_spaces.

-- 1. Contact email for each reservation (never returned by get_spaces, so it stays private)
alter table public.reservations add column if not exists email text;

-- Called by the page straight after reserve_spaces succeeds. Only works on a reservation
-- made in the last 15 minutes that has no email yet, identified by its random photo path.
create or replace function public.set_reservation_email(p_photo_path text, p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare n int;
begin
  p_email := lower(trim(p_email));
  if p_email is null or length(p_email) > 254 or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'bad_email';
  end if;
  update reservations set email = p_email
   where photo_path = p_photo_path and email is null
     and created_at > now() - interval '15 minutes';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'not_found'; end if;
end $$;
revoke all on function public.set_reservation_email(text, text) from public;
grant execute on function public.set_reservation_email(text, text) to anon, authenticated;

-- 2. Admins: Supabase Auth users listed here can see contact details and move photos
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.admins enable row level security;   -- no policies: not readable from the browser
revoke all on public.admins from anon, authenticated;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

-- Every reservation with all its details (name, email, position, created time)
create or replace function public.admin_list()
returns setof jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query select to_jsonb(r) from reservations r order by r.created_at;
end $$;
revoke all on function public.admin_list() from public, anon;
grant execute on function public.admin_list() to authenticated;

-- Move a reservation to a new top-left square (and optionally the other side). Size never changes.
create or replace function public.admin_move(p_id uuid, p_side text, p_c int, p_r int)
returns void language plpgsql security definer set search_path = public as $$
declare v reservations%rowtype;
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  if p_side not in ('front', 'back') then raise exception 'bad_side'; end if;
  lock table reserved_cells in share row exclusive mode;   -- no booking can slip in mid-move
  select * into v from reservations where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if p_c < 0 or p_r < 0 or p_c + v.w > 6 or p_r + v.h > 8 then raise exception 'out_of_bounds'; end if;
  if exists (select 1 from reserved_cells
              where side = p_side and reservation_id <> p_id
                and c between p_c and p_c + v.w - 1
                and r between p_r and p_r + v.h - 1) then
    raise exception 'taken';
  end if;
  delete from reserved_cells where reservation_id = p_id;
  insert into reserved_cells (reservation_id, side, c, r)
    select p_id, p_side, p_c + gx, p_r + gy
      from generate_series(0, v.w - 1) gx, generate_series(0, v.h - 1) gy;
  update reservations set side = p_side, c = p_c, r = p_r where id = p_id;
end $$;
revoke all on function public.admin_move(uuid, text, int, int) from public, anon;
grant execute on function public.admin_move(uuid, text, int, int) to authenticated;

-- 3. Make yourself the admin. First create your login in
--    Authentication → Users → Add user → Create new user (tick "Auto confirm user"),
--    then put that email below and run this line:
-- insert into public.admins (user_id) select id from auth.users where email = 'you@example.com';
