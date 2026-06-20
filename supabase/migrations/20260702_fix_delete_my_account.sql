-- 20260702_fix_delete_my_account.sql
--
-- Rewrite delete_my_account with the correct column names — several were
-- stale (community_posts.author_id, channel_messages.sender_id,
-- friendships.addressee_id, braai_events.host_id, shopping_list_shares
-- owner_id/shared_with) and would have raised undefined_column inside
-- the original exception block, aborting the whole transaction. Also adds
-- the tables introduced after the original RPC: subscriptions, notifications,
-- channel_message_likes/reactions, channel_views, user_feedback,
-- post_likes/comments/reports.
--
-- Each delete is wrapped in begin/exception/when others so future schema
-- drift can't break the POPIA-critical auth.users delete at the end.

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  begin delete from public.subscriptions             where user_id      = uid; exception when others then null; end;
  begin delete from public.notifications             where recipient_id = uid or sender_id = uid; exception when others then null; end;
  begin delete from public.shopping_lists            where user_id      = uid; exception when others then null; end;
  begin delete from public.shopping_list_shares      where sender_id    = uid or receiver_id = uid; exception when others then null; end;
  begin delete from public.recipes                   where user_id      = uid; exception when others then null; end;
  begin delete from public.community_posts           where user_id      = uid; exception when others then null; end;
  begin delete from public.post_likes                where user_id      = uid; exception when others then null; end;
  begin delete from public.post_comments             where user_id      = uid; exception when others then null; end;
  begin delete from public.post_reports              where reporter_id  = uid; exception when others then null; end;
  begin delete from public.channel_messages          where user_id      = uid; exception when others then null; end;
  begin delete from public.channel_message_likes     where user_id      = uid; exception when others then null; end;
  begin delete from public.channel_message_reactions where user_id      = uid; exception when others then null; end;
  begin delete from public.channel_views             where user_id      = uid; exception when others then null; end;
  begin delete from public.inbox_messages            where sender_id    = uid or receiver_id = uid; exception when others then null; end;
  begin delete from public.friendships               where requester_id = uid or receiver_id = uid; exception when others then null; end;
  begin delete from public.braai_events              where creator_id   = uid; exception when others then null; end;
  begin delete from public.shared_assets             where sender_id    = uid or receiver_id = uid; exception when others then null; end;
  begin delete from public.user_feedback             where user_id      = uid; exception when others then null; end;
  begin delete from public.profiles                  where id           = uid; exception when others then null; end;

  delete from auth.users where id = uid;
end;
$$;
