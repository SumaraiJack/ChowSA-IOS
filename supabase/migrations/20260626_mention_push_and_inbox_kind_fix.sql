-- 20260626_mention_push_and_inbox_kind_fix.sql
--
-- Brings the repo in sync with the live backend for two push fixes that were
-- applied directly on the database and never captured in a migration:
--
--   1. @mention push notifications (community_posts + channel_messages).
--   2. The FCM "Invalid data payload key: message_type" 400 — `message_type`
--      is a reserved FCM data key, so the inbox push trigger now forwards it
--      as `inbox_kind` instead.
--
-- Everything here is idempotent (create or replace / drop trigger if exists)
-- and matches what is already live, so applying it against the current DB is
-- a no-op — it exists so a fresh environment reproduces production.
--
-- In-app notification rows (the `notifications` table feeding the bell badge)
-- are untouched: these triggers only fan out FCM pushes via fire_push.

-- ───────────────────────────────────────────────────────────────────────────
-- Helper: pull distinct @handles out of free text. 2–30 chars, alnum +
-- underscore, case-folded so it matches profiles.handle / username lookups.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function public.extract_mention_handles(body text)
returns setof text
language sql
immutable parallel safe
as $$
  select distinct lower(m[1])
    from regexp_matches(coalesce(body, ''), '@([A-Za-z0-9_]{2,30})', 'g') m;
$$;

-- ───────────────────────────────────────────────────────────────────────────
-- @mention in a per-suburb channel message → 'mention' push, deep-linked to
-- the exact bubble via /community/channel.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function public.notify_mention_in_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  sender_handle    text;
  mentioned_id     uuid;
  mentioned_handle text;
  channel_label    text;
  preview_text     text;
begin
  if new.message_text is null or new.message_text = '' then
    return new;
  end if;

  select coalesce(handle, username, 'Someone')
    into sender_handle
    from public.profiles
   where id = new.user_id;

  select '#' || replace(suburb, ' ', '') || '-' || initcap(category)
    into channel_label
    from public.community_channels
   where id = new.channel_id;

  preview_text := substr(new.message_text, 1, 50);
  if length(new.message_text) > 50 then
    preview_text := preview_text || '…';
  end if;

  for mentioned_handle in
    select h from public.extract_mention_handles(new.message_text) as h
  loop
    select id into mentioned_id
      from public.profiles
     where lower(coalesce(handle, username)) = mentioned_handle
     limit 1;

    if mentioned_id is null then
      continue;
    end if;
    if mentioned_id = new.user_id then
      continue;
    end if;

    perform public.fire_push(jsonb_build_object(
      'type',        'mention',
      'to_user_id',  mentioned_id::text,
      'from_handle', coalesce(sender_handle, 'Someone'),
      'route',       '/community/channel',
      'data',        jsonb_build_object(
        'channel_id',    new.channel_id::text,
        'channel_label', coalesce(channel_label, ''),
        'message_id',    new.id::text,
        'preview',       preview_text,
        'surface',       'channel_message'
      )
    ));
  end loop;

  return new;
end$$;

drop trigger if exists trg_notify_mention_in_message on public.channel_messages;
create trigger trg_notify_mention_in_message
  after insert on public.channel_messages
  for each row execute function public.notify_mention_in_message();

-- ───────────────────────────────────────────────────────────────────────────
-- @mention in a community post caption → 'mention' push, deep-linked to the
-- post via /community/post.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function public.notify_mention_in_post()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  poster_handle    text;
  mentioned_id     uuid;
  mentioned_handle text;
  preview_text     text;
begin
  if new.caption is null or new.caption = '' then
    return new;
  end if;

  select coalesce(handle, username, 'Someone')
    into poster_handle
    from public.profiles
   where id = new.user_id;

  preview_text := substr(new.caption, 1, 50);
  if length(new.caption) > 50 then
    preview_text := preview_text || '…';
  end if;

  for mentioned_handle in
    select h from public.extract_mention_handles(new.caption) as h
  loop
    select id into mentioned_id
      from public.profiles
     where lower(coalesce(handle, username)) = mentioned_handle
     limit 1;

    if mentioned_id is null then
      continue;
    end if;
    if mentioned_id = new.user_id then
      continue;
    end if;

    perform public.fire_push(jsonb_build_object(
      'type',        'mention',
      'to_user_id',  mentioned_id::text,
      'from_handle', coalesce(poster_handle, 'Someone'),
      'route',       '/community/post',
      'data',        jsonb_build_object(
        'post_id', new.id::text,
        'preview', preview_text,
        'surface', 'community_post'
      )
    ));
  end loop;

  return new;
end$$;

drop trigger if exists trg_notify_mention_in_post on public.community_posts;
create trigger trg_notify_mention_in_post
  after insert on public.community_posts
  for each row execute function public.notify_mention_in_post();

-- ───────────────────────────────────────────────────────────────────────────
-- Inbox push — shared list / shared recipe / meal plan. `message_type` is a
-- RESERVED FCM data key, so it is forwarded as `inbox_kind` to avoid the
-- "Invalid data payload key: message_type" 400 from FCM.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function public.notify_inbox_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  push_type   text;
  from_handle text;
begin
  push_type := case new.message_type
    when 'shared_recipe' then 'recipe_shared'
    when 'shared_list'   then 'list_shared'
    when 'meal_plan'     then 'meal_plan'
    else null
  end;
  if push_type is null then
    return new;
  end if;
  if new.receiver_id is null then
    return new;
  end if;

  select coalesce(handle, username, 'Someone')
    into from_handle
    from public.profiles
   where id = new.sender_id;

  perform public.fire_push(jsonb_build_object(
    'type',        push_type,
    'to_user_id',  new.receiver_id::text,
    'from_handle', coalesce(from_handle, 'Someone'),
    'route',       '/inbox',
    'data',        jsonb_build_object(
      'inbox_id',   new.id::text,
      'inbox_kind', new.message_type    -- renamed from message_type (reserved by FCM)
    )
  ));

  return new;
end$$;

drop trigger if exists trg_notify_inbox_message on public.inbox_messages;
create trigger trg_notify_inbox_message
  after insert on public.inbox_messages
  for each row execute function public.notify_inbox_message();

-- Retire the older meal-plan-only inbox trigger from 20260619 so it doesn't
-- double-fire meal_plan pushes next to the unified handler above. Matches live
-- (this trigger is not present in production).
drop trigger if exists trg_notify_inbox_meal_plan on public.inbox_messages;
