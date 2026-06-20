-- 20260622_channel_message_reactions.sql
--
-- Emoji reactions on community channel messages. Mirrors the structure of
-- 20260618_channel_message_likes.sql — same composite-PK + per-user RLS
-- pattern, just with the additional `emoji` column so a single user can
-- attach more than one reaction to the same message (e.g. ❤️ AND 🔥).
--
-- Composite PK (message_id, user_id, emoji) makes duplicate inserts a
-- structural no-op: the DB rejects a second copy of the same emoji from
-- the same user with a unique-violation, which the client treats as
-- "already reacted" and turns into an unreact on the toggle path.
--
-- Allowed emoji set is locked at the DB layer via a CHECK constraint so
-- arbitrary text can never be persisted through this column even if the
-- client is bypassed.

create table if not exists public.channel_message_reactions (
  message_id uuid not null
    references public.channel_messages(id) on delete cascade,
  user_id    uuid not null
    references auth.users(id)              on delete cascade,
  emoji      text not null,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji),
  constraint channel_message_reactions_emoji_allowed
    check (emoji in ('❤️', '👍', '😂', '🔥', '😮', '😢', '🙏'))
);

create index if not exists channel_message_reactions_message_id_idx
  on public.channel_message_reactions(message_id);

alter table public.channel_message_reactions enable row level security;

-- Read: any authenticated user can see the aggregate (the bubble UI
-- counts rows + checks "is mine"). Anonymous reads are blocked — the
-- chat is sign-in-gated anyway.
drop policy if exists channel_message_reactions_read on public.channel_message_reactions;
create policy channel_message_reactions_read
  on public.channel_message_reactions
  for select
  to authenticated
  using (true);

-- Insert: only the user's own reaction. The composite PK above already
-- prevents duplicates, but RLS guarantees a caller can't impersonate
-- another user's row.
drop policy if exists channel_message_reactions_insert on public.channel_message_reactions;
create policy channel_message_reactions_insert
  on public.channel_message_reactions
  for insert
  to authenticated
  with check (user_id = auth.uid());

-- Delete: only the user's own reaction. Unreacting on a row you don't
-- own is impossible — the WHERE clause filters it out, so the DELETE
-- silently matches zero rows.
drop policy if exists channel_message_reactions_delete on public.channel_message_reactions;
create policy channel_message_reactions_delete
  on public.channel_message_reactions
  for delete
  to authenticated
  using (user_id = auth.uid());

-- Surface INSERT / DELETE through the realtime publication so the
-- per-bubble `.stream()` subscription in ChannelChatScreen receives
-- live counts the moment another user taps a reaction.
alter publication supabase_realtime
  add table public.channel_message_reactions;
