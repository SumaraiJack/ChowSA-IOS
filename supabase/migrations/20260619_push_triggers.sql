-- 20260619_push_triggers.sql
--
-- Wires three insert triggers to the `send_push` Edge Function via pg_net.
--
-- Why pg_net + a helper RPC, not direct net.http_post in each trigger:
--   • pg_net's http_post is fire-and-forget — the trigger returns immediately
--     even if FCM is slow, so insert latency is unaffected.
--   • The shared helper centralises the URL + auth header so a project ref
--     change only needs editing in ONE place.
--
-- Configuration:
--   Supabase's hosted Postgres blocks `alter database … set …` from the
--   dashboard role, so we can't stash secrets in GUCs. Instead, values live
--   in a tiny `public.app_settings` table the operator owns:
--
--     create table public.app_settings (
--       key   text primary key,
--       value text not null
--     );
--     alter table public.app_settings enable row level security;
--     -- RLS denies all client access; SECURITY DEFINER functions still read.
--     insert into public.app_settings (key, value) values
--       ('edge_url',    'https://<ref>.functions.supabase.co/send_push'),
--       ('edge_secret', '<random 32-byte hex>');
--
--   The same `<random 32-byte hex>` must also be set as the EDGE_SECRET
--   secret on the function so it can reject unauthenticated callers.

create extension if not exists pg_net;

-- ───────────────────────────────────────────────────────────────────────────
-- Helper: fire_push(payload) — wraps pg_net.http_post.
--
-- Reads the edge URL + shared bearer secret from public.app_settings. Marked
-- SECURITY DEFINER so it bypasses the table's RLS — only this function (and
-- the triggers below) ever touch the secret value; RLS still keeps every
-- normal client/authenticated query out.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function public.fire_push(payload jsonb)
returns void
language plpgsql
security definer
set search_path = public, net
as $$
declare
  url    text;
  secret text;
begin
  select value into url    from public.app_settings where key = 'edge_url';
  select value into secret from public.app_settings where key = 'edge_secret';

  if url is null or url = '' then
    -- Edge URL not configured yet — silently no-op rather than blocking
    -- inserts. Operator notices once they test the first trigger.
    return;
  end if;

  perform net.http_post(
    url     := url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || coalesce(secret, '')
    ),
    body    := payload
  );
end$$;

revoke all on function public.fire_push(jsonb) from public;

-- ───────────────────────────────────────────────────────────────────────────
-- 1) Kitchen Circle invite — fires when a friendship row is inserted in the
--    `pending` state. Sends to the receiver, includes the requester's handle
--    so the body can read "@Melrose wants to cook with you".
-- ───────────────────────────────────────────────────────────────────────────
create or replace function public.notify_friendship_invite()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  from_handle text;
begin
  if new.status is distinct from 'pending' then
    return new;
  end if;

  select handle into from_handle
    from public.profiles
   where id = new.requester_id;

  perform public.fire_push(jsonb_build_object(
    'type',        'kitchen_invite',
    'to_user_id',  new.receiver_id,
    'from_handle', coalesce('@' || from_handle, 'Someone'),
    'route',       '/profile/circle'
  ));
  return new;
end$$;

drop trigger if exists trg_notify_friendship_invite on public.friendships;
create trigger trg_notify_friendship_invite
  after insert on public.friendships
  for each row execute function public.notify_friendship_invite();

-- ───────────────────────────────────────────────────────────────────────────
-- 2) Shopping list shared — fires on every shopping_list_shares insert.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function public.notify_list_shared()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  from_handle text;
  recipient   uuid;
begin
  -- Column name differs between projects; try the two common shapes and
  -- fall back to a no-op if neither matches.
  recipient := coalesce(
    (to_jsonb(new) ->> 'shared_with')::uuid,
    (to_jsonb(new) ->> 'receiver_id')::uuid
  );
  if recipient is null then return new; end if;

  select handle into from_handle
    from public.profiles
   where id = coalesce(
     (to_jsonb(new) ->> 'owner_id')::uuid,
     (to_jsonb(new) ->> 'sender_id')::uuid
   );

  perform public.fire_push(jsonb_build_object(
    'type',        'list_shared',
    'to_user_id',  recipient,
    'from_handle', coalesce('@' || from_handle, 'Someone'),
    'route',       '/shopping'
  ));
  return new;
end$$;

drop trigger if exists trg_notify_list_shared on public.shopping_list_shares;
create trigger trg_notify_list_shared
  after insert on public.shopping_list_shares
  for each row execute function public.notify_list_shared();

-- ───────────────────────────────────────────────────────────────────────────
-- 3) Meal-plan inbox message — fires only when type = 'meal_plan' so we
--    don't double up with the existing inbox UI badge for other types.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function public.notify_inbox_meal_plan()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  from_handle text;
begin
  -- inbox_messages.type is project-specific; switch the literal below if
  -- your schema names the column differently (e.g. 'message_type').
  if (to_jsonb(new) ->> 'type') is distinct from 'meal_plan' then
    return new;
  end if;

  select handle into from_handle
    from public.profiles
   where id = new.sender_id;

  perform public.fire_push(jsonb_build_object(
    'type',        'meal_plan',
    'to_user_id',  new.receiver_id,
    'from_handle', coalesce('@' || from_handle, 'Someone'),
    'route',       '/inbox'
  ));
  return new;
end$$;

drop trigger if exists trg_notify_inbox_meal_plan on public.inbox_messages;
create trigger trg_notify_inbox_meal_plan
  after insert on public.inbox_messages
  for each row execute function public.notify_inbox_meal_plan();
