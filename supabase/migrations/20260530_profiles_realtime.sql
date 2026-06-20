-- ============================================================
-- ChowSA — Profiles table: realtime + RLS + required columns
-- Run this in: Supabase Dashboard → SQL Editor → paste → Run
-- ============================================================

-- 1. Ensure the profiles table exists with the required columns
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  handle       text,
  display_name text,
  avatar_url   text,
  updated_at   timestamptz default now()
);

-- 2. Add any missing columns (safe to run even if columns exist)
alter table public.profiles
  add column if not exists handle       text,
  add column if not exists display_name text,
  add column if not exists avatar_url   text,
  add column if not exists updated_at   timestamptz default now();

-- 3. Enable Row Level Security
alter table public.profiles enable row level security;

-- 4. RLS: users can SELECT their own profile row
--    Required for the StreamBuilder subscription to be allowed
do $$
begin
  if not exists (
    select 1 from pg_policies
    where tablename = 'profiles' and policyname = 'owner_read_profile'
  ) then
    execute $p$ create policy "owner_read_profile"
      on public.profiles for select to authenticated
      using (auth.uid() = id) $p$;
  end if;
end $$;

-- 5. RLS: users can INSERT/UPDATE their own profile (needed for upsert)
do $$
begin
  if not exists (
    select 1 from pg_policies
    where tablename = 'profiles' and policyname = 'owner_write_profile'
  ) then
    execute $p$ create policy "owner_write_profile"
      on public.profiles for all to authenticated
      using (auth.uid() = id)
      with check (auth.uid() = id) $p$;
  end if;
end $$;

-- 6. Enable realtime replication on profiles
--    Allows StreamBuilder to receive live profile changes
alter publication supabase_realtime add table public.profiles;

-- 7. Auto-update updated_at on every row change
create or replace function public.handle_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at
  before update on public.profiles
  for each row execute procedure public.handle_updated_at();

-- Verify with these queries after running:
-- select * from pg_publication_tables where pubname = 'supabase_realtime';
-- select * from pg_policies where tablename = 'profiles';
