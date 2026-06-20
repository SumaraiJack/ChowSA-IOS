-- ============================================================
-- ChowSA — friendships table + profiles columns + RLS + realtime
-- Run this in: Supabase Dashboard → SQL Editor → paste → Run
-- ============================================================

-- 1. Ensure profiles has all columns the friend search relies on
alter table public.profiles
  add column if not exists handle       text,
  add column if not exists display_name text,
  add column if not exists email        text,
  add column if not exists avatar_url   text;

-- 2. Create friendships table (safe if already exists)
create table if not exists public.friendships (
  id           uuid        primary key default gen_random_uuid(),
  requester_id uuid        not null references public.profiles(id) on delete cascade,
  receiver_id  uuid        not null references public.profiles(id) on delete cascade,
  status       text        not null check (status in ('pending','accepted')),
  created_at   timestamptz not null default now(),
  unique (requester_id, receiver_id)
);

-- 3. Enable RLS
alter table public.friendships enable row level security;

-- 4. RLS policies (safe — skips if already exist)

-- Either party can read their own edges
do $$ begin
  if not exists (select 1 from pg_policies where tablename='friendships' and policyname='see_own_edges') then
    execute $p$ create policy "see_own_edges" on public.friendships for select to authenticated
      using (auth.uid() = requester_id or auth.uid() = receiver_id) $p$;
  end if;
end $$;

-- Anyone authenticated can send an invite
do $$ begin
  if not exists (select 1 from pg_policies where tablename='friendships' and policyname='send_invite') then
    execute $p$ create policy "send_invite" on public.friendships for insert to authenticated
      with check (auth.uid() = requester_id) $p$;
  end if;
end $$;

-- Only the receiver can accept (flip status to accepted)
do $$ begin
  if not exists (select 1 from pg_policies where tablename='friendships' and policyname='accept') then
    execute $p$ create policy "accept" on public.friendships for update to authenticated
      using (auth.uid() = receiver_id) $p$;
  end if;
end $$;

-- Either party can remove / cancel
do $$ begin
  if not exists (select 1 from pg_policies where tablename='friendships' and policyname='remove') then
    execute $p$ create policy "remove" on public.friendships for delete to authenticated
      using (auth.uid() = requester_id or auth.uid() = receiver_id) $p$;
  end if;
end $$;

-- 5. Add friendships to realtime (safe — skips if already a member)
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'friendships'
  ) then
    alter publication supabase_realtime add table public.friendships;
  end if;
end $$;

-- 6. Verify with:
-- select tablename, policyname, cmd from pg_policies where tablename = 'friendships';
-- select tablename from pg_publication_tables where pubname = 'supabase_realtime';
