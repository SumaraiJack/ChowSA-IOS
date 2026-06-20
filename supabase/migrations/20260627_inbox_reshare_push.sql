-- 20260627_inbox_reshare_push.sql
--
-- Recipe (and any inbox) re-shares hit the dedupe UPDATE path in
-- InboxShareService, but notify_inbox_message (from 20260626) was AFTER INSERT
-- only — so re-sharing the same recipe refreshed the inbox row but fired no
-- push. This makes the handler fire on a genuine re-share UPDATE too, gated so
-- it NEVER fires on mark-read or import (neither bumps created_at).

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
  -- On UPDATE, only a re-share (created_at bumped) with is_read=false is
  -- push-worthy. Skips mark-read (is_read=true) and import (status flip,
  -- created_at unchanged).
  if tg_op = 'UPDATE' then
    if not (new.created_at is distinct from old.created_at
            and new.is_read = false) then
      return new;
    end if;
  end if;

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
      'inbox_kind', new.message_type
    )
  ));

  return new;
end$$;

drop trigger if exists trg_notify_inbox_message      on public.inbox_messages;
drop trigger if exists trg_notify_inbox_message_upd  on public.inbox_messages;

create trigger trg_notify_inbox_message
  after insert on public.inbox_messages
  for each row execute function public.notify_inbox_message();

create trigger trg_notify_inbox_message_upd
  after update on public.inbox_messages
  for each row execute function public.notify_inbox_message();
