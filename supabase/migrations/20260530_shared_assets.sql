-- ============================================================
-- ChowSA — shared_assets table + RLS + realtime
-- Run this in: Supabase Dashboard → SQL Editor → paste → Run
-- ============================================================

-- 1. Create shared_assets table (safe if already exists)
create table if not exists public.shared_assets (
  id          uuid        primary key default gen_random_uuid(),
  sender_id   uuid        not null references auth.users(id) on delete cascade,
  receiver_id uuid        not null references auth.users(id) on delete cascade,
  asset_type  text        not null check (asset_type in ('shopping_list','menu')),
  payload     jsonb       not null,
  is_read     boolean     not null default false,
  created_at  timestamptz not null default now()
);

-- 2. Enable RLS
alter table public.shared_assets enable row level security;

-- 3. RLS policies (safe — skips if already exist)
do $$ begin
  if not exists (select 1 from pg_policies where tablename='shared_assets' and policyname='send') then
    execute $p$ create policy "send" on public.shared_assets for insert to authenticated
      with check (auth.uid() = sender_id) $p$;
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_policies where tablename='shared_assets' and policyname='inbox') then
    execute $p$ create policy "inbox" on public.shared_assets for select to authenticated
      using (auth.uid() = receiver_id) $p$;
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_policies where tablename='shared_assets' and policyname='markread') then
    execute $p$ create policy "markread" on public.shared_assets for update to authenticated
      using (auth.uid() = receiver_id) $p$;
  end if;
end $$;

-- 4. Add to realtime publication (safe — skips if already a member)
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'shared_assets'
  ) then
    alter publication supabase_realtime add table public.shared_assets;
  end if;
end $$;

-- 5. Verify with:
-- select tablename, policyname, cmd from pg_policies where tablename = 'shared_assets';
-- select tablename from pg_publication_tables where pubname = 'supabase_realtime';
