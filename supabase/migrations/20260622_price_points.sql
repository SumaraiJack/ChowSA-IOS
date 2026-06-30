-- WS2: crowdsourced "paid R__" capture from the shopping-list check-off flow.
-- Schema mirrors Open Food Facts' Open Prices so ChowSA can later read from /
-- contribute to that ecosystem without a schema rewrite (see PLAN.md App. A).
-- RLS: a user can insert/read their OWN rows; aggregate reads (median by
-- normalized_name + area) will be exposed via a SECURITY DEFINER RPC, NOT a
-- raw table select, so one user's prices stay invisible to others.

create table if not exists public.price_points (
  id              uuid primary key default gen_random_uuid(),
  raw_name        text not null check (length(raw_name) between 1 and 200),
  normalized_name text not null check (length(normalized_name) between 1 and 200),
  price_zar       numeric(10,2) not null check (price_zar between 0.5 and 5000),
  store           text,
  suburb          text,
  user_id         uuid not null references auth.users(id) on delete cascade,
  created_at      timestamptz not null default now()
);

create index if not exists price_points_normalized_idx
  on public.price_points (normalized_name, created_at desc);

create index if not exists price_points_user_idx
  on public.price_points (user_id, created_at desc);

alter table public.price_points enable row level security;

drop policy if exists "price_points self insert" on public.price_points;
create policy "price_points self insert"
  on public.price_points for insert
  to authenticated
  with check (user_id = auth.uid());

drop policy if exists "price_points self select" on public.price_points;
create policy "price_points self select"
  on public.price_points for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists "price_points self delete" on public.price_points;
create policy "price_points self delete"
  on public.price_points for delete
  to authenticated
  using (user_id = auth.uid());
