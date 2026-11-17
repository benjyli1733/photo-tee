-- Photo Tee: right-sleeve auction (one photo, highest bid wins)
-- Run once in Supabase → SQL Editor → New query → paste → Run. Safe to re-run.
-- Needs admin-and-email.sql to have been run first (it uses is_admin()).

-- Every bid ever placed. Bidders' names and emails are never returned to the public.
create table if not exists public.sleeve_bids (
  id          uuid primary key default gen_random_uuid(),
  amount_gbp  integer not null check (amount_gbp > 0),
  full_name   text not null,
  email       text not null,
  photo_path  text not null,
  terms       text,
  agreed      boolean not null default false,
  created_at  timestamptz not null default now()
);
alter table public.sleeve_bids enable row level security;   -- no policies: not readable from the browser
revoke all on public.sleeve_bids from anon, authenticated;

-- What the public page needs: the current highest bid, its photo and how many bids there are.
-- The opening bid must be at least min_bid (change the 1 here and in place_sleeve_bid to set a different opening price).
create or replace function public.get_sleeve()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'min_bid', 1,
    'bids',    (select count(*) from sleeve_bids),
    'amount',  top.amount_gbp,
    'photo_path', top.photo_path)
  from (select 1) one
  left join lateral (select amount_gbp, photo_path from sleeve_bids
                      order by amount_gbp desc, created_at asc limit 1) top on true;
$$;
revoke all on function public.get_sleeve() from public;
grant execute on function public.get_sleeve() to anon, authenticated;

-- Place a bid. Only accepted if it is higher than the current highest bid
-- (and at least the opening price when there are no bids yet).
create or replace function public.place_sleeve_bid(
  p_amount int, p_name text, p_email text, p_photo_path text, p_terms text, p_agreed boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_top int; v_min int := 1;
begin
  p_name  := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  p_email := lower(trim(coalesce(p_email, '')));
  if p_agreed is not true then raise exception 'not_agreed'; end if;
  if p_name !~ '\S+\s+\S+' or length(p_name) > 80 then raise exception 'bad_name'; end if;
  if length(p_email) > 254 or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'bad_email'; end if;
  if p_photo_path !~ '^[0-9a-f-]{36}\.jpg$' then raise exception 'bad_photo'; end if;
  if p_amount is null or p_amount > 100000 then raise exception 'bad_amount'; end if;
  lock table sleeve_bids in share row exclusive mode;     -- two bids can't both "win" at once
  select max(amount_gbp) into v_top from sleeve_bids;
  if p_amount < coalesce(v_top + 1, v_min) then
    raise exception 'too_low:%', coalesce(v_top + 1, v_min);
  end if;
  insert into sleeve_bids (amount_gbp, full_name, email, photo_path, terms, agreed)
    values (p_amount, p_name, p_email, p_photo_path, left(p_terms, 2000), true);
end $$;
revoke all on function public.place_sleeve_bid(int, text, text, text, text, boolean) from public;
grant execute on function public.place_sleeve_bid(int, text, text, text, text, boolean) to anon, authenticated;

-- Organiser: every bid with name and email, highest first
create or replace function public.admin_sleeve_list()
returns setof jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return query select to_jsonb(b) from sleeve_bids b order by b.amount_gbp desc, b.created_at asc;
end $$;
revoke all on function public.admin_sleeve_list() from public, anon;
grant execute on function public.admin_sleeve_list() to authenticated;

-- Organiser: remove a bid. The next highest bid becomes the leading one.
-- Returns the photo's file path so the page can delete the file too.
create or replace function public.admin_sleeve_delete(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_path text;
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  delete from sleeve_bids where id = p_id returning photo_path into v_path;
  if not found then raise exception 'not_found'; end if;
  return v_path;
end $$;
revoke all on function public.admin_sleeve_delete(uuid) from public, anon;
grant execute on function public.admin_sleeve_delete(uuid) to authenticated;
