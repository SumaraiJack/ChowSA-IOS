-- WS6: weekly specials overlay surfaced as a "🔥 on special at {store}"
-- badge on shopping list items. Refresh runs server-side on a Supabase
-- Edge Function cron (see supabase/functions/specials-refresh) — the
-- app only ever READS this table.
--
-- normalized_name follows the same shape as price_cache.normalized_name
-- (lower-case, alpha-numeric + spaces collapsed) so the shopping-list
-- match is a straight equality check on the same key the cache already
-- uses — no extra normalisation table or fuzzy match needed.

create table if not exists public.specials (
  id              uuid primary key default gen_random_uuid(),
  item_name       text not null check (length(item_name) between 1 and 200),
  normalized_name text not null check (length(normalized_name) between 1 and 200),
  store           text not null check (length(store) between 1 and 80),
  price_zar       numeric(10,2) not null check (price_zar between 0.5 and 5000),
  valid_from      date not null,
  valid_to        date not null,
  source          text not null,
  created_at      timestamptz not null default now(),
  check (valid_to >= valid_from)
);

create index if not exists specials_normalized_active_idx
  on public.specials (normalized_name, valid_to desc);

create index if not exists specials_valid_to_idx
  on public.specials (valid_to);

alter table public.specials enable row level security;

-- Reads are open to everyone (anon + authenticated) so a logged-out
-- preview build still sees badges. Writes go through the edge function
-- with the service role — no client write policy at all.
drop policy if exists "specials read all" on public.specials;
create policy "specials read all"
  on public.specials for select
  to authenticated, anon
  using (true);
