-- 20260628_mention_push_in_comment.sql
--
-- @mention inside a post comment → 'mention' push, deep-linked to the post.
-- Mirrors notify_mention_in_post (20260626); routes via /community/post so the
-- tap lands on the post that contains the comment. Pairs with the @mention
-- autocomplete now wired into the comment composer.

create or replace function public.notify_mention_in_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  commenter_handle text;
  mentioned_id     uuid;
  mentioned_handle text;
  preview_text     text;
begin
  if new.body is null or new.body = '' then
    return new;
  end if;

  select coalesce(handle, username, 'Someone')
    into commenter_handle
    from public.profiles
   where id = new.user_id;

  preview_text := substr(new.body, 1, 50);
  if length(new.body) > 50 then
    preview_text := preview_text || '…';
  end if;

  for mentioned_handle in
    select h from public.extract_mention_handles(new.body) as h
  loop
    select id into mentioned_id
      from public.profiles
     where lower(coalesce(handle, username)) = mentioned_handle
     limit 1;

    if mentioned_id is null then continue; end if;
    if mentioned_id = new.user_id then continue; end if;

    perform public.fire_push(jsonb_build_object(
      'type',        'mention',
      'to_user_id',  mentioned_id::text,
      'from_handle', coalesce(commenter_handle, 'Someone'),
      'route',       '/community/post',
      'data',        jsonb_build_object(
        'post_id', new.post_id::text,
        'preview', preview_text,
        'surface', 'post_comment'
      )
    ));
  end loop;

  return new;
end$$;

drop trigger if exists trg_notify_mention_in_comment on public.post_comments;
create trigger trg_notify_mention_in_comment
  after insert on public.post_comments
  for each row execute function public.notify_mention_in_comment();
