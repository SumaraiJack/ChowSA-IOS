-- 20260618_channel_message_likes.sql
--
-- Likes engine for channel-chat messages (TableView Western Cape, What's
-- Cooking, etc.). Composite PK (message_id, user_id) — a user can like a
-- message at most once, so double-counting is structurally impossible.
--
-- Mirrors the existing public.post_likes table; we keep them separate
-- because post_likes FKs to community_posts and the FK is what enforces
-- cascade-on-delete cleanly.

create table if not exists public.channel_message_likes (
  message_id uuid not null
    references public.channel_messages(id) on delete cascade,
  user_id    uuid not null
    references auth.users(id)              on delete cascade,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

create index if not exists channel_message_likes_message_id_idx
  on public.channel_message_likes(message_id);

alter table public.channel_message_likes enable row level security;

-- Anyone signed in can read counts; only the user themselves can insert
-- or delete their own like. The composite PK above already prevents
-- duplicate inserts, but RLS guarantees a malicious caller can't
-- impersonate someone else's like.
drop policy if exists channel_message_likes_read on public.channel_message_likes;
create policy channel_message_likes_read
  on public.channel_message_likes for select
  to authenticated using (true);

drop policy if exists channel_message_likes_write on public.channel_message_likes;
create policy channel_message_likes_write
  on public.channel_message_likes for insert
  to authenticated with check (user_id = auth.uid());

drop policy if exists channel_message_likes_delete on public.channel_message_likes;
create policy channel_message_likes_delete
  on public.channel_message_likes for delete
  to authenticated using (user_id = auth.uid());
