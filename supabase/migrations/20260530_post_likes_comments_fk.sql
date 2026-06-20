-- ============================================================
-- ChowSA — post_likes + comments with proper foreign keys
-- Fixed: safely adds to realtime publication only if not already there
-- Run this in: Supabase Dashboard → SQL Editor → paste → Run
-- ============================================================

-- 1. post_likes
create table if not exists public.post_likes (
  id         uuid        primary key default gen_random_uuid(),
  post_id    uuid        not null references public.community_posts(id) on delete cascade,
  user_id    uuid        not null references auth.users(id)             on delete cascade,
  created_at timestamptz default now(),
  unique (post_id, user_id)
);

alter table public.post_likes enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where tablename='post_likes' and policyname='auth_can_like') then
    execute $p$ create policy "auth_can_like" on public.post_likes for insert to authenticated with check (auth.uid() = user_id) $p$;
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_policies where tablename='post_likes' and policyname='auth_can_unlike') then
    execute $p$ create policy "auth_can_unlike" on public.post_likes for delete to authenticated using (auth.uid() = user_id) $p$;
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_policies where tablename='post_likes' and policyname='anyone_reads') then
    execute $p$ create policy "anyone_reads" on public.post_likes for select using (true) $p$;
  end if;
end $$;

-- 2. comments
create table if not exists public.comments (
  id         uuid        primary key default gen_random_uuid(),
  post_id    uuid        not null references public.community_posts(id) on delete cascade,
  user_id    uuid        not null references auth.users(id),
  body       text        not null,
  created_at timestamptz default now()
);

alter table public.comments enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where tablename='comments' and policyname='auth_can_comment') then
    execute $p$ create policy "auth_can_comment" on public.comments for insert to authenticated with check (auth.uid() = user_id) $p$;
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_policies where tablename='comments' and policyname='anyone_reads') then
    execute $p$ create policy "anyone_reads" on public.comments for select using (true) $p$;
  end if;
end $$;

-- 3. Safely add to realtime — skip if already a member
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and tablename='post_likes'
  ) then
    alter publication supabase_realtime add table public.post_likes;
  end if;
end $$;

do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and tablename='comments'
  ) then
    alter publication supabase_realtime add table public.comments;
  end if;
end $$;
