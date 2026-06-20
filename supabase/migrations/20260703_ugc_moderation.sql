-- 20260703_ugc_moderation.sql
--
-- UGC moderation primitives required by Google Play's User-Generated
-- Content policy:
--   • Block another user           (user_blocks)
--   • Report a community post      (post_reports — already exists)
--   • Report a channel message     (channel_message_reports — new)
--
-- Posts + channel messages + comments from a blocked user are hidden from
-- the blocker via RLS USING clauses, so the UI doesn't have to filter twice.

create table if not exists public.user_blocks (
  blocker_id uuid not null references auth.users(id) on delete cascade,
  blocked_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
alter table public.user_blocks enable row level security;

drop policy if exists user_blocks_self_read  on public.user_blocks;
drop policy if exists user_blocks_self_write on public.user_blocks;
drop policy if exists user_blocks_self_del   on public.user_blocks;

create policy user_blocks_self_read  on public.user_blocks
  for select to authenticated using (auth.uid() = blocker_id);
create policy user_blocks_self_write on public.user_blocks
  for insert to authenticated with check (auth.uid() = blocker_id);
create policy user_blocks_self_del   on public.user_blocks
  for delete to authenticated using (auth.uid() = blocker_id);

create table if not exists public.channel_message_reports (
  id          uuid        primary key default gen_random_uuid(),
  message_id  uuid        not null references public.channel_messages(id) on delete cascade,
  reporter_id uuid        not null references auth.users(id) on delete cascade,
  reason      text        not null default 'Community report',
  reported_at timestamptz not null default now(),
  unique (message_id, reporter_id)
);
alter table public.channel_message_reports enable row level security;

drop policy if exists cmr_self_insert on public.channel_message_reports;
drop policy if exists cmr_self_read   on public.channel_message_reports;

create policy cmr_self_insert on public.channel_message_reports
  for insert to authenticated with check (auth.uid() = reporter_id);
create policy cmr_self_read   on public.channel_message_reports
  for select to authenticated using (auth.uid() = reporter_id);

-- Hide blocked users' content via RLS append.
drop policy if exists posts_select_not_blocked on public.community_posts;
create policy posts_select_not_blocked on public.community_posts
  for select to authenticated using (
    user_id not in (select blocked_id from public.user_blocks where blocker_id = auth.uid())
  );

drop policy if exists chmsg_select_not_blocked on public.channel_messages;
create policy chmsg_select_not_blocked on public.channel_messages
  for select to authenticated using (
    user_id not in (select blocked_id from public.user_blocks where blocker_id = auth.uid())
  );

drop policy if exists pc_select_not_blocked on public.post_comments;
create policy pc_select_not_blocked on public.post_comments
  for select to authenticated using (
    user_id not in (select blocked_id from public.user_blocks where blocker_id = auth.uid())
  );
