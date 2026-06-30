-- WS1: editable price baselines + per-item estimate cache.
-- See PLAN.md §WS1. Both tables RLS-enabled; baselines read-only to clients,
-- cache writeable by any authenticated user via upsert (PK uniqueness + a
-- sane price-range check keep it bounded).

create table if not exists public.price_baselines (
  keyword       text primary key,
  avg_price_zar numeric(10,2) not null check (avg_price_zar >= 0),
  category      text,
  -- Higher specificity matches first, so "tomato sauce" beats "tomato".
  specificity   int  not null default 1,
  updated_at    timestamptz not null default now()
);

create index if not exists price_baselines_specificity_idx
  on public.price_baselines (specificity desc, keyword);

alter table public.price_baselines enable row level security;

drop policy if exists "price_baselines read all" on public.price_baselines;
create policy "price_baselines read all"
  on public.price_baselines for select
  to authenticated, anon
  using (true);
-- No insert/update/delete policy => writes blocked for client roles.
-- Service role bypasses RLS for admin edits.

create table if not exists public.price_cache (
  normalized_name text primary key,
  avg_price_zar   numeric(10,2) not null check (avg_price_zar between 2 and 5000),
  source          text not null check (source in ('baseline','ai','crowd')),
  updated_at      timestamptz not null default now()
);

create index if not exists price_cache_updated_at_idx
  on public.price_cache (updated_at desc);

alter table public.price_cache enable row level security;

drop policy if exists "price_cache read all" on public.price_cache;
create policy "price_cache read all"
  on public.price_cache for select
  to authenticated, anon
  using (true);

drop policy if exists "price_cache upsert by authenticated" on public.price_cache;
create policy "price_cache upsert by authenticated"
  on public.price_cache for insert
  to authenticated
  with check (source in ('ai','baseline'));

drop policy if exists "price_cache update by authenticated" on public.price_cache;
create policy "price_cache update by authenticated"
  on public.price_cache for update
  to authenticated
  using (true)
  with check (source in ('ai','baseline'));
